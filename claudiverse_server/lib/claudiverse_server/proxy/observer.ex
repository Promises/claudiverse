defmodule ClaudiverseServer.Proxy.Observer do
  @moduledoc """
  One process per Claude session seen through the API proxy. It turns the raw
  request/response stream into the same messages the sidecar sends, and feeds
  them into a Room of its own, so storage, the web panel, idle tracking and
  watcher pings work unchanged.

  ## Running beside the sidecar

  The proxy is the second of two systems under comparison. A seat may feed
  both at once, so this writes to its OWN row, titled `proxy:<seat>` and keyed
  by `claude_session_id = "proxy:<uuid>"`:
  - title lookups are exact, so `cv_send lorem-w1` still finds the real seat;
  - `Sessions.create_session/1` reuses rows by `claude_session_id`, so the
    namespaced id keeps this row from landing on the sidecar's.

  ## Shadow or primary

  By default a seat's traffic is mirrored into the shadow row above, for
  comparison with the sidecar. A seat that has RETIRED a patch says so with
  `X-Claudiverse-Provides` (e.g. `mirror`, `mirror,idle,compact`): the proxy
  then writes into the seat's OWN row — reused by Claude session id exactly as
  the sidecar's registration is — so cv_tail, cv_questions and watcher pings
  keep reading the row they always read. Only the provided categories are
  emitted there; the rest still come from the seat's remaining patches, and
  two sources of the same signal would duplicate it.

      mirror   prompts, tool results, replies, turn_complete, api errors
      idle     readiness edges (idle, and busy as a cvstate frame)
      compact  the compact signal

  ## Readiness

  Read off the MAIN thread's request lifecycle:

      request in flight                         busy
      response stop_reason tool_use             tool (client runs it), or
                                                question for AskUserQuestion
      end_turn, no main request within idle_ms  idle

  The debounce exists because a queued message is sent the instant a turn
  ends; a false idle that short would let a delivery race into a busy seat.

  Busy edges go to the Room as a `cvstate` frame (reconciled, never stored);
  idle edges as an `idle` message, exactly as patch 008 sends them, so
  `Router.went_idle` fires the same way.

  Blind spots, by construction: a permission prompt looks like a slow tool, a
  dead process looks idle, local-only commands are invisible. Hooks close
  those; this does not pretend to.
  """
  use GenServer

  require Logger

  alias ClaudiverseServer.Proxy.Request
  alias ClaudiverseServer.Sessions
  alias ClaudiverseServer.Sessions.{Room, Supervisor}

  @registry ClaudiverseServer.Proxy.Registry
  @dyn_sup ClaudiverseServer.Proxy.Supervisor
  # An observer with no traffic for this long exits; the next request starts a
  # fresh one, which reuses the same row.
  @inactivity_ms :timer.hours(12)

  defstruct [
    :claude_session_id,
    :seat,
    :user_id,
    :session_id,
    :account,
    :model,
    :idle_ref,
    :ratelimit,
    provides: MapSet.new(),
    idle_ms: 1500,
    state: "unknown",
    state_since: nil,
    inflight_main: 0,
    threads: %{},
    subagent_last_at: nil,
    counts: %{}
  ]

  # --- Client API ---

  @doc "Record a request. Starts the observer on first sight of a session."
  def request(claude_session_id, user_id, seat, info) do
    case ensure_started(claude_session_id, user_id, seat, Map.get(info, :provides, [])) do
      {:ok, pid} -> GenServer.cast(pid, {:request, info})
      _ -> :error
    end
  end

  @doc "Record the response to a request recorded with `request/4`."
  def response(claude_session_id, info) do
    case Registry.lookup(@registry, claude_session_id) do
      [{pid, _}] -> GenServer.cast(pid, {:response, info})
      [] -> :error
    end
  end

  @doc "Snapshot of every live observer, for `GET /proxy/_status`."
  def status do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(@dyn_sup), is_pid(pid) do
      try do
        GenServer.call(pid, :status, 2_000)
      catch
        :exit, _ -> nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  def start_link(opts) do
    sid = Keyword.fetch!(opts, :claude_session_id)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, sid}})
  end

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}

  defp ensure_started(sid, user_id, seat, provides) do
    case Registry.lookup(@registry, sid) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        opts = [
          claude_session_id: sid,
          user_id: user_id,
          seat: seat,
          provides: provides,
          idle_ms: Application.get_env(:claudiverse_server, :proxy_idle_ms, 1500)
        ]

        case DynamicSupervisor.start_child(@dyn_sup, {__MODULE__, opts}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  # --- Server ---

  @impl true
  def init(opts) do
    state = %__MODULE__{
      claude_session_id: Keyword.fetch!(opts, :claude_session_id),
      user_id: Keyword.fetch!(opts, :user_id),
      seat: Keyword.get(opts, :seat),
      provides: MapSet.new(Keyword.get(opts, :provides, [])),
      idle_ms: Keyword.get(opts, :idle_ms, 1500),
      state_since: now()
    }

    # The row and Room are created after init returns: start_child runs in the
    # proxied request's process, and a DB write there would put SQLite on the
    # path of a model call.
    {:ok, state, {:continue, :register}}
  end

  @impl true
  def handle_continue(:register, state) do
    attrs =
      if primary?(state) and is_binary(state.seat) do
        # The seat's own row: same title and Claude session id the sidecar
        # registers with, so whichever arrives first creates it and the other
        # reuses it.
        %{title: state.seat, type: :sidecar, mode: :json, status: :running,
          claude_session_id: state.claude_session_id, user_id: state.user_id}
      else
        %{title: "proxy:" <> (state.seat || String.slice(state.claude_session_id, 0, 8)),
          type: :proxy, mode: :json, status: :running,
          claude_session_id: "proxy:" <> state.claude_session_id, user_id: state.user_id}
      end

    title = attrs.title

    with {:ok, session} <- Sessions.create_session(attrs),
         {:ok, _} <- Supervisor.start_room(session.id, owner_id: state.user_id) do
      {:noreply, %{state | session_id: session.id}, @inactivity_ms}
    else
      error ->
        Logger.warning("[proxy] could not register #{title}: #{inspect(error)}")
        {:noreply, state, @inactivity_ms}
    end
  end

  @impl true
  def handle_cast({:request, info}, state) do
    state =
      state
      |> count(info.class)
      |> note_account(info.account)
      |> on_request(info)

    {:noreply, state, @inactivity_ms}
  end

  def handle_cast({:response, info}, state) do
    state =
      case Request.ratelimit(info.headers) do
        rl when map_size(rl) > 0 ->
          %{state | ratelimit: Map.merge(rl, %{"at" => iso(now()), "account" => state.account})}

        _ ->
          state
      end

    {:noreply, on_response(state, info), @inactivity_ms}
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      claude_session_id: state.claude_session_id,
      session_id: state.session_id,
      seat: state.seat,
      mode: if(primary?(state), do: "primary", else: "shadow"),
      provides: MapSet.to_list(state.provides),
      account: state.account,
      model: state.model,
      state: state.state,
      since: iso(state.state_since),
      subagent_active: is_integer(state.subagent_last_at) and now() - state.subagent_last_at < 30_000,
      counts: state.counts,
      ratelimit: state.ratelimit
    }

    {:reply, reply, state, @inactivity_ms}
  end

  @impl true
  def handle_info({:idle_check, ref, reason}, %{idle_ref: ref, inflight_main: 0} = state) do
    {:noreply, set_state(%{state | idle_ref: nil}, "idle", reason), @inactivity_ms}
  end

  def handle_info(:timeout, state), do: {:stop, :normal, state}
  def handle_info(_msg, state), do: {:noreply, state, @inactivity_ms}

  # --- Requests ---

  defp on_request(state, %{class: "compaction"}) do
    mirror(state, [%{"type" => "compact"}])
    state
  end

  defp on_request(state, %{class: class} = info) when class in ["main", "subagent"] do
    thread = thread_key(class, info.agent_id)
    {items, reset, first?, threads} = new_items(state.threads, thread, info.messages)
    state = %{state | threads: threads}

    state =
      if class == "main" do
        %{state | inflight_main: state.inflight_main + 1, model: info.model || state.model}
        |> set_state("busy", "request")
      else
        %{state | subagent_last_at: now()}
      end

    if reset and class == "main", do: mirror(state, [%{"type" => "proxy_context_reset"}])

    mirror(
      state,
      for m <- items do
        base = %{"type" => "user", "message" => m, "proxy_thread" => thread}
        if first?, do: Map.put(base, "proxy_first", true), else: base
      end
    )

    state
  end

  defp on_request(state, _info), do: state

  # New conversation items since this thread's previous request. On first sight
  # (fresh start or a resumed session) only the message that prompted this
  # request is new; the rest is history. The assistant reply to the previous
  # request was mirrored from its response, so only user-side items — prompts,
  # tool results, channel messages — are taken from the request.
  defp new_items(threads, key, messages) do
    len = length(messages)

    {items, reset, first?} =
      case threads do
        %{^key => prev} when len < prev -> {last_user(messages), true, false}
        %{^key => prev} -> {messages |> Enum.drop(prev) |> Enum.filter(&(&1["role"] == "user")), false, false}
        _ -> {last_user(messages), false, true}
      end

    {Enum.flat_map(items, &operator_view/1), reset, first?, Map.put(threads, key, len)}
  end

  # The newest user-role message. Not simply the last message: measured on
  # 2.1.286, a turn's first request ENDS with a `role: "system"` environment
  # block after the user's prompt.
  defp last_user(messages) do
    case messages |> Enum.reverse() |> Enum.find(&(&1["role"] == "user")) do
      nil -> []
      m -> [m]
    end
  end

  # What the operator (or a tool, or a channel) actually said, as a list of
  # messages to mirror. Claude Code wraps the typed prompt in
  # `<system-reminder>` text blocks — CLAUDE.md, environment, skills — which
  # are context for the model, not conversation. They are dropped and counted;
  # a message that was nothing but reminders is dropped whole.
  #
  # A prompt delivered by the seat's inbox hook (asyncRewake, SeatInbox) is
  # the exception: Claude Code queues it as a task notification whose body is
  # a system reminder, so it would be dropped with the rest. It is pulled out
  # wherever it sits — a string, a text block, or inside a tool result when it
  # lands mid-turn — and mirrored as a user prompt of its own, the way a
  # prompt typed by 003 always was.
  defp operator_view(m) do
    {m, prompts} = take_inbox_prompts(m)
    inbox = for p <- prompts, do: %{"role" => "user", "content" => [%{"type" => "text", "text" => p}], "proxy_source" => "inbox"}
    Enum.reject([strip_reminders(m) | inbox], &is_nil/1)
  end

  defp strip_reminders(%{"content" => content} = m) when is_list(content) do
    {reminders, kept} =
      Enum.split_with(content, fn b ->
        b["type"] == "text" and String.starts_with?(String.trim_leading(b["text"] || ""), "<system-reminder>")
      end)

    cond do
      kept == [] -> nil
      reminders == [] -> m
      true -> m |> Map.put("content", kept) |> Map.put("proxy_reminders_dropped", length(reminders))
    end
  end

  defp strip_reminders(%{"content" => ""}), do: nil
  defp strip_reminders(m), do: m

  # The prefix cv-inbox's hook config gives every inbox prompt
  # (rewakeMessage in semi-claudiversed launch.sh). Claude Code renders it as
  # "<rewakeMessage> <prompt>" inside a system reminder.
  @inbox_marker "Message from the claudiverse orchestrator: "
  # MEASURED (8a7e72c, semi-inbox-1): in the request the notification sits
  # inside an outer reminder, and the inner one is HTML-ESCAPED, so the prompt
  # ends at "&lt;/system-reminder&gt;" and its own text is escaped too. The
  # transcript on disk carries the unescaped form. Both are matched; the
  # escaped one is unescaped.
  @inbox_prompt_escaped ~r/Message from the claudiverse orchestrator: (.*?)\n&lt;\/system-reminder&gt;/s
  @inbox_prompt ~r/Message from the claudiverse orchestrator: (.*?)(?:\n<\/system-reminder>|\z)/s

  # {message without the inbox notifications, [prompt]} — a string or text
  # block carrying the marker is removed whole (it is the notification), and
  # its prompt returned.
  defp take_inbox_prompts(%{"content" => content} = m) do
    {content, prompts} = take_from(content)
    {Map.put(m, "content", content), prompts}
  end

  defp take_inbox_prompts(m), do: {m, []}

  defp take_from(text) when is_binary(text) do
    if String.contains?(text, @inbox_marker), do: {"", inbox_prompts(text)}, else: {text, []}
  end

  defp take_from(blocks) when is_list(blocks) do
    {kept, prompts} =
      Enum.reduce(blocks, {[], []}, fn block, {kept, prompts} ->
        case block do
          %{"type" => "text", "text" => t} when is_binary(t) ->
            if String.contains?(t, @inbox_marker), do: {kept, prompts ++ inbox_prompts(t)}, else: {[block | kept], prompts}

          %{"type" => "tool_result", "content" => inner} ->
            {inner, found} = take_from(inner)
            {[Map.put(block, "content", inner) | kept], prompts ++ found}

          _ ->
            {[block | kept], prompts}
        end
      end)

    {Enum.reverse(kept), prompts}
  end

  defp take_from(other), do: {other, []}

  defp inbox_prompts(text) do
    found =
      case Regex.scan(@inbox_prompt_escaped, text) do
        [] -> for [_, p] <- Regex.scan(@inbox_prompt, text), do: p
        escaped -> for [_, p] <- escaped, do: unescape_html(p)
      end

    found |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  # &amp; last, so an escaped "&amp;lt;" becomes "&lt;", not "<".
  defp unescape_html(s) do
    s
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end

  # --- Responses ---

  defp on_response(state, %{class: class} = info) when class in ["main", "subagent", "compaction"] do
    thread = if class == "compaction", do: "compaction", else: thread_key(class, info.agent_id)

    cond do
      info.aborted ->
        mirror(state, [%{"type" => "proxy_interrupted", "proxy_thread" => thread}])
        settle(state, class, "interrupted")

      info.status >= 400 ->
        error =
          case Jason.decode(info.raw) do
            {:ok, %{"error" => e}} -> e
            _ -> nil
          end

        mirror(state, [%{"type" => "proxy_api_error", "status" => info.status, "error" => error, "proxy_thread" => thread}])
        state = %{state | counts: Map.update(state.counts, "errors", 1, &(&1 + 1))}
        settle(state, class, "error #{info.status}")

      true ->
        msg = Request.assistant(info.content_type, info.raw)
        if msg, do: mirror(state, [%{"type" => "assistant", "message" => msg, "proxy_thread" => thread}])
        state = after_reply(state, class, msg)
        reassert_idle(state, class)
    end
  end

  # A fresh seat makes no main request until someone prompts it, so no turn
  # ever ends and nothing would mark it idle — every delivery to it would
  # bounce as busy. But every start does send side requests through here (the
  # quota probe, session titling): one completing while the seat is still
  # unknown, with no main request in flight, means it is at its prompt. The
  # sidecar's 008 sent this first idle at startup; this replaces it.
  defp on_response(%{state: "unknown", inflight_main: 0} = state, %{class: class})
       when class in ["probe", "auxiliary"] do
    ref = make_ref()
    Process.send_after(self(), {:idle_check, ref, "startup"}, state.idle_ms)
    %{state | idle_ref: ref}
  end

  defp on_response(state, _info), do: state

  # Room marks a seat busy on every message that is not `idle`, so mirroring a
  # compaction that ran at the prompt (`/compact`) would leave an idle seat
  # reading busy — and cv_send bouncing — until its next turn. Same failure the
  # sidecar's patch 009 has. Re-assert by heartbeat, which Room reconciles but
  # does not store.
  defp reassert_idle(%{state: "idle"} = state, class) when class in ["compaction", "subagent"] do
    mirror(state, [%{"type" => "cvstate", "idle" => true, "tasks" => []}])
    state
  end

  defp reassert_idle(state, _class), do: state

  defp after_reply(state, "main", %{"stop_reason" => "tool_use", "content" => content}) do
    asks? = Enum.any?(content, &(&1["type"] == "tool_use" and &1["name"] == "AskUserQuestion"))
    state = %{state | inflight_main: max(state.inflight_main - 1, 0)}
    set_state(state, if(asks?, do: "question", else: "tool"), "tool_use")
  end

  defp after_reply(state, "main", _msg) do
    mirror(state, [%{"type" => "turn_complete"}])
    settle(state, "main", "end_turn")
  end

  defp after_reply(state, _class, _msg), do: state

  # A main-thread exchange ended without a tool to run: idle once nothing else
  # is in flight for idle_ms.
  defp settle(state, "main", reason) do
    state = %{state | inflight_main: max(state.inflight_main - 1, 0)}

    if state.inflight_main == 0 do
      ref = make_ref()
      Process.send_after(self(), {:idle_check, ref, reason}, state.idle_ms)
      %{state | idle_ref: ref}
    else
      state
    end
  end

  defp settle(state, _class, _reason), do: state

  # --- Helpers ---

  defp set_state(%{state: same} = state, same, _reason), do: %{state | idle_ref: nil}

  defp set_state(state, new, reason) do
    state = %{state | state: new, state_since: now(), idle_ref: nil}

    case new do
      "idle" -> mirror(state, [%{"type" => "idle"}])
      _ -> mirror(state, [%{"type" => "cvstate", "idle" => false, "tasks" => []}])
    end

    Logger.debug("[proxy] #{state.claude_session_id} -> #{new} (#{reason})")
    state
  end

  defp note_account(state, nil), do: state
  defp note_account(%{account: same} = state, same), do: state
  defp note_account(%{account: nil} = state, acct), do: %{state | account: acct}

  defp note_account(state, acct) do
    mirror(state, [%{"type" => "proxy_account_changed", "from" => state.account, "to" => acct}])
    %{state | account: acct}
  end

  defp count(state, class), do: %{state | counts: Map.update(state.counts, class, 1, &(&1 + 1))}

  defp thread_key("main", _), do: "main"
  defp thread_key(_, agent_id), do: "agent:" <> (agent_id || "?")

  defp mirror(_state, []), do: :ok
  defp mirror(%{session_id: nil}, _), do: :ok

  defp mirror(%{session_id: id} = state, msgs) do
    case Enum.filter(msgs, &provided?(state, category(&1))) do
      [] -> :ok
      kept -> Room.mirror_messages(id, kept)
    end
  end

  defp primary?(state), do: MapSet.size(state.provides) > 0

  # A shadow row gets everything; a seat's own row only what was handed over.
  defp provided?(state, category), do: not primary?(state) or MapSet.member?(state.provides, category)

  defp category(%{"type" => t}) when t in ["idle", "cvstate"], do: "idle"
  defp category(%{"type" => "compact"}), do: "compact"
  defp category(_), do: "mirror"

  defp now, do: System.system_time(:millisecond)
  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
