defmodule ClaudiverseServerWeb.HookController do
  @moduledoc """
  The target of a seat's PreToolUse HTTP hook, so `cv_answer` can answer an
  AskUserQuestion with no patch in the seat's binary (replaces patch 007):

      {"hooks": {"PreToolUse": [{"matcher": "AskUserQuestion", "hooks": [{
        "type": "http", "url": "<server>/api/hooks/seat/<title>/pretooluse",
        "timeout": 3600, "headers": {"Authorization": "Bearer $CLAUDIVERSE_TOKEN"},
        "allowedEnvVars": ["CLAUDIVERSE_TOKEN"]}]}]}}

  The request is HELD until `cv_answer` or `cv_decline` reaches the seat's Room,
  then answered with `permissionDecision: "allow"` and `updatedInput.answers` —
  the shape measured on stock 2.1.286 to resolve the dialog. While it is held
  the seat waits in the hook and shows no dialog; if nobody answers before
  `hold_ms`, an empty reply lets the dialog open locally instead.
  """
  use ClaudiverseServerWeb, :controller

  require Logger

  alias ClaudiverseServer.QuestionHolds
  alias ClaudiverseServer.SeatLinks
  alias ClaudiverseServer.Sessions.Room

  # Just under the hook's own 3600 s timeout, so the server answers first.
  @default_hold_ms :timer.minutes(59)
  # A POLLED question waits for its answer as long as its seat keeps polling;
  # a seat that stops is forgotten by QuestionHolds' staleness. 59 min ended
  # it with no answer while the seat still sat at its dialog, so a later
  # cv_answer went nowhere (lorem-w6-t1884, 2026-10-08: asked 06:59, hold ended
  # 07:58, answered 09:21). The bound only stops a question living for ever.
  @default_poll_hold_ms :timer.hours(24)

  # The claudiverse-seat mod (0.8.5+) asks by POLLING, because its
  # $.http.fetch gives up after 30 s: each poll waits at most `wait` seconds
  # and ends with the answer or `{"pending": true}`; QuestionHolds keeps an
  # answer that arrives between polls. The seat shows its terminal dialog
  # meanwhile and withdraws the question when it is answered there.
  def pretooluse(conn, %{"seat" => seat, "tool_name" => "AskUserQuestion", "withdraw" => true} = input) do
    user = conn.assigns.current_user
    :ok = QuestionHolds.close(user.id, seat, input["tool_use_id"])
    SeatLinks.deliver(:question, user.id, seat, :question_withdrawn)
    Logger.info("[hook] #{seat} answered its question at the terminal")
    json(conn, %{})
  end

  def pretooluse(conn, %{"seat" => seat, "tool_name" => "AskUserQuestion", "wait" => wait} = input)
      when is_integer(wait) and wait > 0 do
    user = conn.assigns.current_user
    id = input["tool_use_id"]
    flush_stale()
    :ok = SeatLinks.register(:question, user.id, seat)
    {seen, stashed, opened} = QuestionHolds.checkin(user.id, seat, id)
    if seen == :new, do: Logger.info("[hook] #{seat} asks; polling for cv_answer")
    left = Application.get_env(:claudiverse_server, :question_poll_hold_ms, @default_poll_hold_ms) - (System.monotonic_time(:millisecond) - opened)

    outcome =
      cond do
        stashed != nil -> stashed
        left <= 0 -> :expired
        true -> await_question(min(wait * 1000, left))
      end

    SeatLinks.unregister(:question, user.id, seat)
    # An answer delivered just as the wait ran out sits in this mailbox now
    # that no link can receive another: take it instead of losing it.
    outcome = if outcome == :pending, do: await_question(0), else: outcome
    # The wait that reached the hold's end ends the question, not one more poll.
    outcome = if outcome == :pending and left <= wait * 1000, do: :expired, else: outcome

    reply =
      case outcome do
        {:question_answer, payload} -> allow(input["tool_input"] || %{}, payload)
        {:question_decline, _payload} -> deny()
        :pending -> %{"pending" => true}
        # Replaced by a newer poll, withdrawn, or past the hold: no opinion.
        _ -> %{}
      end

    if outcome != :pending, do: QuestionHolds.close(user.id, seat, id)
    json(conn, reply)
  end

  def pretooluse(conn, %{"seat" => seat, "tool_name" => "AskUserQuestion"} = input) do
    user = conn.assigns.current_user
    flush_stale()
    :ok = SeatLinks.register(:question, user.id, seat)
    Logger.info("[hook] #{seat} asks; holding for cv_answer")
    hold = Application.get_env(:claudiverse_server, :question_hold_ms, @default_hold_ms)

    reply =
      receive do
        {:question_answer, payload} -> allow(input["tool_input"] || %{}, payload)
        {:question_decline, _payload} -> deny()
        :seat_link_replaced -> %{}
      after
        hold -> %{}
      end

    SeatLinks.unregister(:question, user.id, seat)
    json(conn, reply)
  end

  # Any other tool: no opinion, the seat proceeds as it would without the hook.
  def pretooluse(conn, _input), do: json(conn, %{})

  @default_permission_hold_ms :timer.minutes(59)
  @default_keepalive_ms 10_000

  @doc """
  `POST /api/hooks/seat/:seat/permissionrequest` — a seat's PermissionRequest
  HTTP hook, so a permission prompt can be answered from the panel or the app
  with no patch (where 002 used to relay it, and the channel is unavailable).

  Measured on 2.1.286: the terminal dialog is shown WHILE this is held — the
  hook races it — so holding never locks the operator out. The prompt is
  entered into the seat's Room as a `can_use_tool` control request (`"hook":
  true`), the shape the panel already answers; `Room.send_permission_response/3`
  answers it here with `{"decision": {"behavior": "allow" | "deny"}}`.

  🔴 A PROMPT ANSWERED AT THE TERMINAL does NOT end this request: measured,
  Claude Code keeps the hook's connection open and ignores its eventual
  answer. The Room settles it instead, from the mirror — the tool's result in
  the seat's next request, or the seat going idle (Room.settle_hook_permissions)
  — and tells this process to stop.

  The response is also chunked, a space every few seconds (JSON allows
  leading whitespace) until the decision, so a seat that goes AWAY is noticed
  by a failed write and its prompt withdrawn.

  No running session for the seat: `{}`, and the dialog stays local.
  """
  # The claudiverse-seat mod (0.8.6+) asks by POLLING, as with questions: its
  # $.http.fetch gives up after 30 s. The first poll enters the prompt into the
  # seat's Room (the apps show it) and answers `{"pending": true, "request_id"}`
  # unless decided within `wait` s; later polls name the request_id. An answer
  # between polls is kept by the Room. The terminal dialog shows meanwhile (the
  # mod's hook races it, measured on 2.1.292); answered there, the mod sends
  # `withdraw`, and the mirror settles it as for a held hook.
  def permission_request(conn, %{"seat" => seat, "withdraw" => true, "request_id" => rid}) do
    case ClaudiverseServerWeb.McpController.seat_session(conn.assigns.current_user, seat) do
      nil -> :ok
      session -> Room.permission_withdrawn(session.id, rid)
    end

    SeatLinks.deliver_request(rid, :permission_settled)
    json(conn, %{})
  end

  def permission_request(conn, %{"seat" => seat, "wait" => wait} = input) when is_integer(wait) and wait > 0 do
    case ClaudiverseServerWeb.McpController.seat_session(conn.assigns.current_user, seat) do
      nil -> json(conn, %{})
      session -> poll_permission(conn, session, input, min(wait, 25) * 1000)
    end
  end

  def permission_request(conn, %{"seat" => seat} = input) do
    user = conn.assigns.current_user

    case ClaudiverseServerWeb.McpController.seat_session(user, seat) do
      nil -> json(conn, %{})
      session -> hold_permission(conn, session, input)
    end
  end

  defp poll_permission(conn, session, input, wait_ms) do
    {rid, kept} =
      case input["request_id"] do
        rid when is_binary(rid) ->
          kept = Room.take_permission_decision(session.id, rid)
          if kept == :pending, do: :ok = SeatLinks.register_request(rid)
          {rid, kept}

        # Registered before the apps can see it, so an instant answer cannot
        # fall between the two.
        _ ->
          rid = new_request_id()
          :ok = SeatLinks.register_request(rid)
          enter_permission(session, input, rid, %{"polled" => true})
          {rid, :pending}
      end

    outcome =
      case kept do
        {:decided, behavior} -> {:decision, behavior}
        :gone -> :settled
        :pending -> await_polled(rid, wait_ms)
      end

    case outcome do
      {:decision, behavior} -> json(conn, permission_decision(behavior))
      :settled -> json(conn, %{})
      :pending -> json(conn, %{"pending" => true, "request_id" => rid})
    end
  end

  # The caller registered `rid` as this process's link.
  defp await_polled(rid, wait_ms) do
    outcome =
      receive do
        {:permission_decision, behavior} -> {:decision, behavior}
        :permission_settled -> :settled
      after
        wait_ms -> :pending
      end

    SeatLinks.unregister_request(rid)
    # A decision sent just as the wait ran out is in this mailbox: take it.
    if outcome == :pending do
      receive do
        {:permission_decision, behavior} -> {:decision, behavior}
        :permission_settled -> :settled
      after
        0 -> :pending
      end
    else
      outcome
    end
  end

  defp new_request_id, do: "hook-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  # Enter the prompt into the seat's Room as a `can_use_tool` control request
  # (`"hook": true`), the shape the panel and the apps already answer.
  defp enter_permission(session, input, request_id, extra) do
    tool_input = if is_map(input["tool_input"]), do: input["tool_input"], else: %{}

    Room.mirror_messages(session.id, [
      Map.merge(
        %{
          "type" => "control_request",
          "request_id" => request_id,
          "hook" => true,
          # The agent that asks (claudiverse-seat 0.9.0 sends the hook's
          # agent_id); absent for main.
          "agent_id" => input["agent_id"],
          "request" => %{
            "subtype" => "can_use_tool",
            "tool_name" => input["tool_name"],
            "input" => tool_input,
            "description" => tool_input["description"],
            "permission_suggestions" => input["permission_suggestions"]
          }
        },
        extra
      )
    ])

    Logger.info("[hook] #{session.title} permission #{input["tool_name"]} held as #{request_id}")
  end

  defp permission_decision(behavior) do
    decision =
      if behavior == "allow",
        do: %{"behavior" => "allow"},
        else: %{"behavior" => "deny", "message" => "Denied from claudiverse"}

    %{"hookSpecificOutput" => %{"hookEventName" => "PermissionRequest", "decision" => decision}}
  end

  defp hold_permission(conn, session, input) do
    request_id = new_request_id()
    :ok = SeatLinks.register_request(request_id)
    enter_permission(session, input, request_id, %{})
    deadline = System.monotonic_time(:millisecond) + config(:permission_hold_ms, @default_permission_hold_ms)
    conn = conn |> put_resp_content_type("application/json") |> send_chunked(200)
    {conn, outcome} = await_decision(conn, deadline)
    SeatLinks.unregister_request(request_id)

    case outcome do
      {:decision, behavior} ->
        case chunk(conn, Jason.encode!(permission_decision(behavior))) do
          {:ok, conn} -> conn
          {:error, _} -> conn
        end

      # Settled elsewhere: the Room already took it off the panel.
      :settled ->
        chunk(conn, "{}")
        conn

      # Timed out: no opinion, the terminal dialog decides. Dropped: the seat
      # is gone.
      ending when ending in [:timeout, :closed] ->
        Room.permission_withdrawn(session.id, request_id)
        if ending == :timeout, do: chunk(conn, "{}")
        conn
    end
  end

  defp await_decision(conn, deadline) do
    wait = min(config(:permission_keepalive_ms, @default_keepalive_ms), deadline - System.monotonic_time(:millisecond))

    receive do
      {:permission_decision, behavior} -> {conn, {:decision, behavior}}
      # Settled at the terminal (Room saw the tool's result, or the seat idle).
      :permission_settled -> {conn, :settled}
    after
      max(wait, 0) ->
        cond do
          System.monotonic_time(:millisecond) >= deadline -> {conn, :timeout}
          true ->
            case chunk(conn, " ") do
              {:ok, conn} -> await_decision(conn, deadline)
              {:error, _} -> {conn, :closed}
            end
        end
    end
  end

  defp config(key, default), do: Application.get_env(:claudiverse_server, key, default)

  defp await_question(ms) do
    receive do
      {:question_answer, _} = answer -> answer
      {:question_decline, _} = decline -> decline
      :seat_link_replaced -> :replaced
      :question_withdrawn -> :withdrawn
    after
      ms -> :pending
    end
  end

  # This process may have served an earlier question on the same keep-alive
  # connection; an answer that arrived after that one returned must not be
  # taken as the answer to this one.
  defp flush_stale do
    receive do
      {:question_answer, _} -> flush_stale()
      {:question_decline, _} -> flush_stale()
      :seat_link_replaced -> flush_stale()
      :question_withdrawn -> flush_stale()
    after
      0 -> :ok
    end
  end

  @doc """
  `{"answers": {question => label}}` is passed through. A `{"response": text}`
  (cv_answer, and the apps) is split per question when it is the apps'
  "<header>: <choice>" lines, one per question answered, and a question
  without a line is answered "(no answer given)". Otherwise, as free text,
  it answers every question. MEASURED 2026-10-07: "Color: Red" came back as
  the answer to both Color and Size, and one choice made in the app answered
  a two-question ask twice over.
  """
  def answers(tool_input, payload) do
    questions = tool_input["questions"] || []

    case payload do
      %{"answers" => a} when is_map(a) ->
        a

      %{"response" => text} when is_binary(text) ->
        case by_header(questions, text) do
          nil -> whole(questions, text)
          split -> split
        end

      _ ->
        %{}
    end
  end

  @unanswered "(no answer given)"

  # One free-text reply to the whole set: the first question carries it once,
  # the rest point to it. Copying it into every question read as the person
  # giving the same answer three times (MEASURED 2026-10-09: the operator's one
  # reply to Failover's three questions came back as three identical answers).
  defp whole([%{"question" => first} = q1 | rest], text) do
    label = q1["header"] || first
    Map.new([{first, text} | for(%{"question" => q} <- rest, do: {q, ~s|(one reply for all questions: see "#{label}")|})])
  end

  defp whole(_questions, _text), do: %{}

  # Every line "<header>: <choice>" for a header of these questions (unique),
  # with more than one question asked; nil when the text is anything else.
  defp by_header(questions, text) do
    headers = for %{"header" => h, "question" => q} <- questions, is_binary(h), into: %{}, do: {h, q}
    lines = text |> String.split("\n", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    parsed =
      Enum.map(lines, fn line ->
        with [h, choice] <- String.split(line, ": ", parts: 2),
             q when is_binary(q) <- headers[h],
             do: {q, choice},
             else: (_ -> nil)
      end)

    if length(questions) > 1 and map_size(headers) == length(questions) and lines != [] and
         Enum.all?(parsed) and length(Enum.uniq_by(parsed, &elem(&1, 0))) == length(parsed) do
      given = Map.new(parsed)
      for %{"question" => q} <- questions, into: %{}, do: {q, Map.get(given, q, @unanswered)}
    end
  end

  defp allow(tool_input, payload) do
    %{"hookSpecificOutput" => %{
        "hookEventName" => "PreToolUse",
        "permissionDecision" => "allow",
        "permissionDecisionReason" => "answered via claudiverse",
        "updatedInput" => Map.put(tool_input, "answers", answers(tool_input, payload))}}
  end

  defp deny do
    %{"hookSpecificOutput" => %{
        "hookEventName" => "PreToolUse",
        "permissionDecision" => "deny",
        "permissionDecisionReason" => "declined via claudiverse"}}
  end
end
