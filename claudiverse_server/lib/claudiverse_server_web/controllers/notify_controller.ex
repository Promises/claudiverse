defmodule ClaudiverseServerWeb.NotifyController do
  @moduledoc """
  Orchestrator notification registry. A listener (by title) subscribes to watch
  other sessions; the Notifications.Router then delivers compact pings by
  injecting a turn into the listener when it goes idle. See Router.
  """
  use ClaudiverseServerWeb, :controller

  alias ClaudiverseServer.Accounts

  alias ClaudiverseServer.Sessions
  alias ClaudiverseServer.Sessions.Room
  alias ClaudiverseServer.Notifications.Router

  # POST /api/notify/subscribe  %{"self" => title, "watch" => [titles], "mode" => replace|add|remove}
  # Replace (the default) sets the list to `watch`; add and remove change it by
  # `watch`. The reply names the previous list and what was dropped, so a
  # replace cannot silently lose a watch (lorem-admin lost its two task channels
  # to one on 2026-10-07).
  def subscribe(conn, params) do
    user = conn.assigns.current_user
    self_title = Map.get(params, "self")
    given = Map.get(params, "watch", [])

    case resolve(user.id, self_title) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "no running session titled #{self_title}"})

      session ->
        previous = Router.watching(self_title)

        watch =
          case Map.get(params, "mode", "replace") do
            "add" -> Enum.uniq(previous ++ given)
            "remove" -> previous -- given
            _ -> given
          end

        {:ok, _} = Router.subscribe(self_title, session.id, watch)

        json(conn, %{ok: true, listener: self_title, listener_session_id: session.id, watch: watch,
                     previous: previous, dropped: previous -- watch})
    end
  end

  # POST /api/notify/ack  %{"self" => title, "target" => title | "all"}
  def ack(conn, params) do
    self_title = Map.get(params, "self")
    target = case Map.get(params, "target", "all") do
      "all" -> :all
      t -> t
    end

    Router.ack(self_title, target)
    json(conn, %{ok: true})
  end

  # GET /api/notify/pending?self=title
  def pending(conn, params) do
    self_title = Map.get(params, "self")
    json(conn, %{queue: Router.peek(self_title)})
  end

  # POST /api/notify/send  %{"session_id" => id, "content" => text}
  # Reject-busy: delivers only if the target agent is idle; else returns busy+hint
  # so the caller holds it and re-decides on the target's next idle.
  # POST /api/notify/send  %{"session_id" => id, "content" => text, "force" => bool}
  #
  # `force: true` delivers to a busy seat. 🔴 APP-ONLY: every seat carries the
  # shared "api" token, so honouring force for it would let any seat push into
  # any other mid-turn. Refused with 403 before the session is even looked up —
  # a refusal must never be readable as "busy".
  def send(conn, params) do
    force = params["force"] in [true, "true"]

    if force and not Accounts.app_powers?(conn.assigns[:token_context]) do
      conn |> put_status(:forbidden) |> json(%{error: "force is app-only"})
    else
      deliver_send(conn, params, if(force, do: &Room.force_message/2, else: &Room.send_message/2))
    end
  end

  # 🔴 A STOPPED ROW IS NOT A DELIVERY. A seat that restarts lands on a NEW row,
  # and a sender holding the old id was told "delivered" while the message went
  # nowhere: the stopped row's Room still answered, with no seat behind it.
  # MEASURED 2026-10-05: lorem-admin's YES for a server swap, sent to Failover's
  # pre-restart row 203677, came back "delivered" and never arrived. Say
  # "stopped" instead, and where the seat went (its title's live row), so the
  # sender can tell this from a real delivery and re-address it.
  defp stopped(user_id, session) do
    live =
      Sessions.list_sessions_by_title(user_id, session.title, status: :running, limit: 1)
      |> Enum.find(&(&1.type != :proxy))

    %{status: "stopped", error: "session #{session.id} (#{session.title}) is #{session.status}; nothing was delivered",
      live_session_id: live && live.id}
  end

  # A mod seat submits an inbox text as a prompt, and a "/" text would run a
  # command as its user, which the engine refuses; only /compact is run (as a
  # command, claudiverse-seat 0.8.8). Refused here so the sender hears it:
  # the seat only logged it, and read busy for 35 min (lorem-orchestrator,
  # 2026-10-08). A patched seat types the text into its pane, so it is left alone.
  @inbox_commands ~w(compact)

  defp slash_refusal(%{client_version: v}, content) when is_binary(v) and is_binary(content) do
    with true <- String.contains?(v, "[claudiverse-mod"),
         [_, command] <- Regex.run(~r{\A\s*/([A-Za-z][\w-]*)}, content),
         false <- command in @inbox_commands do
      "a slash command cannot be sent to a seat; only #{Enum.map_join(@inbox_commands, ", ", &("/" <> &1))} is run (claudiverse-seat 0.8.8+). /#{command} was not delivered"
    else
      _ -> nil
    end
  end

  defp slash_refusal(_session, _content), do: nil

  defp deliver_send(conn, params, deliver) do
    user = conn.assigns.current_user
    content = Map.get(params, "content", "")

    with id when not is_nil(id) <- Map.get(params, "session_id"),
         %{} = session <- Sessions.get_user_session(user.id, id) do
      refusal = slash_refusal(session, content)

      result =
        cond do
          session.status != :running ->
            stopped(user.id, session)

          refusal ->
            %{status: "refused", error: refusal}

          true ->
            case deliver.(session.id, content) do
              :delivered -> %{status: "delivered"}
              {:busy, hint} -> %{status: "busy", hint: hint}
              {:error, _} -> %{status: "error", error: "not connected"}
            end
        end

      json(conn, result)
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: "session not found"})
    end
  end

  # POST /api/notify/report  %{"self" => worker_title, "text" => text}
  # A worker pushes a discrete report UP to whoever watches it (the orchestrator).
  def report(conn, params) do
    self_title = Map.get(params, "self")
    text = Map.get(params, "text", "")

    if is_binary(self_title) and self_title != "" do
      Router.report(self_title, text)
      json(conn, %{ok: true})
    else
      conn |> put_status(:bad_request) |> json(%{error: "missing self"})
    end
  end

  # GET /api/notify/status?session_id=<id>  → %{idle, status, sidecar_connected}
  def status(conn, params) do
    user = conn.assigns.current_user
    id = Map.get(params, "session_id")

    case id && Sessions.get_user_session(user.id, id) do
      %{} = session ->
        case Registry.lookup(ClaudiverseServer.Sessions.Registry, session.id) do
          [{_pid, _}] -> json(conn, Room.get_status(session.id))
          [] -> json(conn, %{idle: false, sidecar_connected: false, status: "not_connected"})
        end

      _ ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})
    end
  end

  defp resolve(_user_id, nil), do: nil

  defp resolve(user_id, title) do
    sessions = Sessions.list_sessions_by_title(user_id, title)
    Enum.find(sessions, &(&1.status == :running)) || List.first(sessions)
  end
end
