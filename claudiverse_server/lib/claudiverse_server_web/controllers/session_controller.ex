defmodule ClaudiverseServerWeb.SessionController do
  use ClaudiverseServerWeb, :controller

  alias ClaudiverseServer.Accounts

  alias ClaudiverseServer.{Hosts, Sessions}
  alias ClaudiverseServer.Sessions.Supervisor, as: SessionSupervisor
  alias ClaudiverseServer.Sessions.Room

  def index(conn, params) do
    user = conn.assigns.current_user

    # Bounded + running-first by default (see Sessions.list_sessions/2).
    # `?status=all|stopped|crashed` and `?limit=N` opt into history — the web
    # UI can still show everything; the default protects MCP clients, whose
    # token budget an unbounded list blows up.
    opts = list_opts(params)

    sessions =
      case Map.get(params, "title") do
        nil -> Sessions.list_sessions(user.id, opts)
        title -> Sessions.list_sessions_by_title(user.id, title, opts)
      end

    json(conn, %{
      sessions: Enum.map(sessions, &serialize_session/1)
    })
  end

  # Parse ?status= and ?limit= into opts for Sessions.list_*; unknown/garbage
  # values fall through to the safe defaults rather than erroring.
  defp list_opts(params) do
    opts =
      case Map.get(params, "status") do
        s when s in ["all", "running", "stopped", "crashed"] ->
          [status: String.to_existing_atom(s)]

        _ ->
          []
      end

    case Integer.parse(Map.get(params, "limit", "")) do
      {n, _} when n > 0 and n <= 5000 -> Keyword.put(opts, :limit, n)
      _ -> opts
    end
  end

  def create(conn, params) do
    user = conn.assigns.current_user

    attrs = %{
      title: Map.get(params, "title", "Untitled"),
      type: :sidecar,
      mode: :json,
      status: :running,
      # Claude's own session UUID. When present, create_session/1 REUSES the
      # matching row instead of inserting a new one on every reconnect.
      claude_session_id: Map.get(params, "claude_session_id"),
      user_id: user.id
    }

    # ⛔ SAME RULE FOR model, AND IT WAS MISSING. The attrs above used to carry
    # `model: Map.get(params, "model", "sonnet")`, so every re-POST — including
    # the title pushes the client makes whenever a session is renamed — quietly
    # RESET the model to the default. MEASURED: a session reporting
    # "claude-opus-5" reverted to "sonnet" the moment it was renamed, undoing
    # the value Room had extracted from its own assistant messages.
    # The client never sends model, so absence must mean "no news" here too.
    attrs =
      case Map.get(params, "model") do
        m when is_binary(m) and m != "" -> Map.put(attrs, :model, m)
        _ -> attrs
      end

    # ⛔ ONLY WHEN PRESENT. A re-POST that carries no display_title — the seat has
    # not been ai-titled yet, or the transcript was mid-write — must not WIPE one
    # already stored. Merging conditionally keeps absence meaning "no news"
    # rather than "clear it", which is what a plain Map.get would have meant.
    attrs =
      case Map.get(params, "display_title") do
        t when is_binary(t) and t != "" -> Map.put(attrs, :display_title, t)
        _ -> attrs
      end

    # Same "absence is no news" rule: a re-POST without placement (an older
    # runtime) must not wipe what a newer one reported.
    attrs =
      # working_directory too: it used to be written unconditionally, so any
      # re-POST without it (the rename path) wiped it to null.
      Enum.reduce(~w(host fleet origin working_directory client_version tmux_session), attrs, fn key, acc ->
        case Map.get(params, key) do
          v when is_binary(v) and v != "" -> Map.put(acc, String.to_existing_atom(key), v)
          _ -> acc
        end
      end)

    # A seat started from a profile says so (CLAUDIVERSE_PROFILE / _REVISION
    # in its launch environment). Absent is no news, as above.
    attrs =
      Enum.reduce(~w(profile_id profile_revision), attrs, fn key, acc ->
        case Integer.parse(to_string(Map.get(params, key, ""))) do
          {n, ""} -> Map.put(acc, String.to_existing_atom(key), n)
          _ -> acc
        end
      end)

    # Reported explicitly by current runtimes (true or false), so a seat
    # relaunched WITHOUT the opt-in loses it on its row. Absent (an older
    # runtime) is no news.
    attrs =
      case Map.get(params, "notify") do
        v when v in [true, "1", "true"] -> Map.put(attrs, :can_notify, true)
        v when v in [false, "0", "false"] -> Map.put(attrs, :can_notify, false)
        _ -> attrs
      end

    # A profile's seat is what its profile says (fleet, notify, origin).
    attrs = ClaudiverseServer.Profiles.registration_attrs(user.id, attrs)

    case Sessions.create_session(attrs) do
      {:ok, session} ->
        session = Hosts.place(user.id, session, Hosts.peer_ip(conn.remote_ip))
        {:ok, _pid} = SessionSupervisor.start_room(session.id, owner_id: user.id)

        # Keep the seat's account assignment labelled with the name it is
        # actually using. A seat re-POSTs here whenever its title changes, and
        # this request carries the instance_id that identifies it, so the
        # assignment follows a rename instead of staying frozen at whatever the
        # title happened to be during its first second of life.
        ClaudiverseServer.AnthropicAuths.note_seat_title(
          conn.assigns[:client_identity] || %{},
          session.title
        )

        conn
        |> put_status(:created)
        |> json(%{session: serialize_session(session)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Sessions.get_user_session(user.id, id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Not found"})

      session ->
        # Include live status from Room if running
        live_status =
          case Registry.lookup(ClaudiverseServer.Sessions.Registry, session.id) do
            [{_pid, _}] -> ClaudiverseServer.Sessions.Room.get_status(session.id)
            [] -> nil
          end

        json(conn, %{
          session: serialize_session(session),
          live: live_status
        })
    end
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Sessions.get_user_session(user.id, id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Not found"})

      session ->
        case Registry.lookup(ClaudiverseServer.Sessions.Registry, session.id) do
          [{pid, _}] -> SessionSupervisor.stop_room(pid)
          [] -> :ok
        end

        Sessions.delete_session(session)
        json(conn, %{ok: true})
    end
  end

  defp serialize_session(s) do
    live = live_status(s)

    %{
      id: s.id,
      title: s.title,
      display_title: s.display_title,
      type: s.type,
      mode: s.mode,
      status: s.status,
      model: s.model,
      working_directory: s.working_directory,
      host: s.host,
      fleet: s.fleet,
      origin: s.origin,
      can_notify: ClaudiverseServer.Sessions.Access.can_notify?(s),
      # The seat's access level (Sessions.Access): explicit, or derived.
      access: ClaudiverseServer.Sessions.Access.level(s),
      access_explicit: s.access != nil,
      # The operator's paging switch in force now (nil = derived), and when it lapses.
      notify_grant: ClaudiverseServer.Sessions.Access.grant(s),
      notify_until: if(ClaudiverseServer.Sessions.Access.grant(s) != nil, do: s.notify_until),
      claude_session_id: s.claude_session_id,
      conversation_id: s.conversation_id,
      # The profile it was started from, if any (the apps link the two).
      profile_id: s.profile_id,
      client_version: s.client_version,
      inserted_at: s.inserted_at,
      # When the session last DID something, from its newest message. The list
      # is ordered by this, and it is what a relative "3m ago" should show —
      # inserted_at only says when the seat was started.
      last_activity_at: Map.get(s, :last_activity_at) || s.inserted_at,
      # Live state, straight from the Room. `status` only distinguishes
      # running/stopped; this is the difference between a seat WORKING and a
      # seat sitting at a prompt, which is the thing an operator actually scans
      # a dashboard for.
      activity: activity_of(live),
      # Shells, monitors, subagents and workflows the seat has running, as its
      # mod last reported (0 when it reported none or is not connected).
      background_running: (if is_map(live), do: Map.get(live, :background_running, 0), else: 0)
    }
  end

  # "busy" | "idle" | "disconnected"
  #
  # ⚠️ A dead Room is NOT an error. Rooms are per-session processes and a
  # stopped session has none, so the call must be allowed to fail and mean
  # "disconnected" rather than propagate. Also guards against a Room that is
  # alive but wedged: a status call that times out reports disconnected instead
  # of hanging the whole list.
  # ⏱ 200ms, deliberately. This runs once PER ROW, so the budget is the whole
  # list: a Room busy with mirror traffic must cost the dashboard a missing dot,
  # never a hung request. The default 5s timeout took /api/sessions down
  # completely while every other endpoint stayed healthy.
  @activity_timeout_ms 200

  # The Room's status once per row: the activity dot and the background count
  # both read it, and a second call would double the list's worst case.
  defp live_status(%{status: :running} = s) do
    Room.get_status(s.id, @activity_timeout_ms)
  catch
    # A timeout means the Room did not answer in time — NOT that the seat is
    # gone. Reporting "disconnected" there would be a confident wrong answer
    # about a seat that is most likely busy; "unknown" is honest and the UI
    # renders no dot for it.
    :exit, {:timeout, _} -> :timeout
    :exit, _ -> :gone
  end

  defp live_status(_s), do: :gone

  defp activity_of(:timeout), do: "unknown"
  defp activity_of(:gone), do: "disconnected"
  defp activity_of(%{sidecar_connected: false}), do: "disconnected"
  defp activity_of(%{idle: true}), do: "idle"
  defp activity_of(%{idle: false}), do: "busy"
  defp activity_of(_), do: "unknown"

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @doc """
  POST /api/sessions/:id/title — ask a seat to rename itself.

  ⚠️ ASKS, DOES NOT SET. The seat applies the name and re-POSTs, and THAT is
  what updates the session row. Writing the title here directly would put the
  server's idea of the name out of step with the seat's own, and the seat would
  overwrite it on its next push anyway. A seat pinned by CLAUDIVERSE_TITLE
  refuses outright — accepted here, refused there, and visible in its log.
  """
  def set_title(conn, %{"id" => id, "title" => title}) when is_binary(title) do
    case String.trim(title) do
      "" ->
        conn |> put_status(:bad_request) |> json(%{error: "title cannot be blank"})

      trimmed ->
        Sessions.Room.set_title(String.to_integer(id), trimmed)
        json(conn, %{requested: trimmed})
    end
  rescue
    ArgumentError -> conn |> put_status(:bad_request) |> json(%{error: "bad session id"})
  end

  def set_title(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "title is required"})
  end

  @max_mirror_batch 200

  @doc """
  POST /api/sessions/:id/mirror  %{"messages" => [message, ...]}

  What a sidecar sends as "mirror_messages" on its channel, over plain HTTP,
  for a seat with no WebSocket: the claudiverse mod (Claude Code 2.1.287+
  mods get `$.http.fetch` and nothing longer-lived). Each message is
  processed exactly as a sidecar's (stored, broadcast to viewers, and the
  seat's readiness: any message reads busy, a `{"type": "idle"}` frame idle).
  The seat's own row only; at most #{@max_mirror_batch} messages per call.
  """
  def mirror(conn, %{"id" => id, "messages" => messages}) when is_list(messages) do
    user = conn.assigns.current_user

    with {n, ""} <- Integer.parse(id),
         %{} = session <- Sessions.get_user_session(user.id, n) do
      cond do
        length(messages) > @max_mirror_batch ->
          conn |> put_status(:bad_request) |> json(%{error: "at most #{@max_mirror_batch} messages per call"})

        not Enum.all?(messages, &(is_map(&1) and is_binary(&1["type"]))) ->
          conn |> put_status(:bad_request) |> json(%{error: "each message must be an object with a type"})

        true ->
          {:ok, _} = SessionSupervisor.start_room(session.id, owner_id: user.id)
          Room.mirror_messages(session.id, messages)
          conn |> put_status(:accepted) |> json(%{ok: true, count: length(messages)})
      end
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: "Not found"})
    end
  end

  def mirror(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "messages must be a list"})
  end

  @doc """
  `POST /api/sessions/:id/access` {level: basic|full|null} — APP TOKEN
  ONLY (every seat carries the shared api token). Sets the seat's TOOLS
  (Sessions.Access); null returns it to the derived default. Paging is the
  separate switch, `POST /api/sessions/:id/notify`. ("notify" is still
  accepted as a level: basic tools with paging on.)
  The seat's claudiverse MCP picks it up within a minute, no restart.
  """
  def access(conn, %{"id" => id} = params) do
    level = params["level"]

    cond do
      not Accounts.app_powers?(conn.assigns[:token_context]) ->
        conn |> put_status(:forbidden) |> json(%{error: "seat access is app-only"})

      not (is_nil(level) or level in ClaudiverseServer.Sessions.Access.levels()) ->
        conn |> put_status(:bad_request) |> json(%{error: "level must be basic, notify, full or null"})

      session = Sessions.get_user_session(conn.assigns.current_user.id, id) ->
        {:ok, s} = session |> Ecto.Changeset.change(access: level) |> ClaudiverseServer.Repo.update()
        json(conn, %{session: serialize_session(s)})

      true ->
        conn |> put_status(:not_found) |> json(%{error: "session not found"})
    end
  end

  @doc """
  `POST /api/sessions/:id/notify` {allow: true|false|null, minutes?} — APP
  TOKEN ONLY. The operator's paging switch for the seat (Sessions.Access):
  may it page the operator? `minutes` (1..10080) makes it lapse back to the
  seat's default then; null clears it at once. The seat's claudiverse MCP
  picks it up within a minute.
  """
  def notify(conn, %{"id" => id} = params) do
    allow = params["allow"]
    minutes = params["minutes"]

    cond do
      not Accounts.app_powers?(conn.assigns[:token_context]) ->
        conn |> put_status(:forbidden) |> json(%{error: "seat paging is app-only"})

      not (is_nil(allow) or is_boolean(allow)) ->
        conn |> put_status(:bad_request) |> json(%{error: "allow must be true, false or null"})

      not (is_nil(minutes) or (is_integer(minutes) and minutes >= 1 and minutes <= 10_080)) ->
        conn |> put_status(:bad_request) |> json(%{error: "minutes must be 1 to 10080"})

      session = Sessions.get_user_session(conn.assigns.current_user.id, id) ->
        until =
          if is_integer(minutes) and not is_nil(allow),
            do: DateTime.utc_now() |> DateTime.add(minutes * 60) |> DateTime.truncate(:second)

        {:ok, s} =
          session
          |> Ecto.Changeset.change(notify_grant: allow, notify_until: until)
          |> ClaudiverseServer.Repo.update()

        json(conn, %{session: serialize_session(s)})

      true ->
        conn |> put_status(:not_found) |> json(%{error: "session not found"})
    end
  end

  # Modes the app may set — what Shift+Tab reaches on a normally launched seat.
  # bypassPermissions and dontAsk are deliberately not settable remotely.
  @app_modes ~w(default acceptEdits plan auto)

  @doc """
  POST /api/sessions/:id/permission_mode  %{"mode" => mode}

  APP TOKEN ONLY: every seat carries the shared "api" token, so any other
  token gets 403 before anything reaches the seat. The seat applies the mode
  through its own setter (013 runtime hook) and the response is what the seat
  reports, never a bare "sent":

    200 {"status": "applied", "mode": m}
    409 {"status": "refused", "error": e, "code": c}  the seat declined it
    503 {"error": "seat not connected"}
    504 {"error": "seat did not answer"}  e.g. a seat without the 013 hook
  """
  def permission_mode(conn, %{"id" => id} = params) do
    mode = params["mode"]

    cond do
      not Accounts.app_powers?(conn.assigns[:token_context]) ->
        conn |> put_status(:forbidden) |> json(%{error: "permission mode is app-only"})

      mode not in @app_modes ->
        conn |> put_status(:bad_request) |> json(%{error: "mode must be one of #{Enum.join(@app_modes, ", ")}"})

      true ->
        apply_permission_mode(conn, Sessions.get_user_session(conn.assigns.current_user.id, id), mode)
    end
  end

  defp apply_permission_mode(conn, nil, _mode) do
    conn |> put_status(:not_found) |> json(%{error: "session not found"})
  end

  defp apply_permission_mode(conn, session, mode) do
    case Room.set_permission_mode(session.id, mode) do
      {:ok, applied} ->
        json(conn, %{status: "applied", mode: applied})

      {:refused, error, code} ->
        conn |> put_status(:conflict) |> json(%{status: "refused", error: error, code: code})

      {:error, :timeout} ->
        conn |> put_status(:gateway_timeout) |> json(%{error: "seat did not answer"})

      # No sidecar (a stock seat with the claudiverse-seat mod): its machine's
      # agent switches the mode in the seat's tmux pane with Shift+Tab, as at
      # its terminal. A plugin cannot set the live mode itself.
      {:error, :not_connected} when is_binary(session.host) ->
        set_mode_on_host(conn, session, mode)

      {:error, :not_connected} ->
        conn |> put_status(:service_unavailable) |> json(%{error: "seat not connected"})
    end
  end

  defp set_mode_on_host(conn, session, mode) do
    case Hosts.request(conn.assigns.current_user.id, session.host, "set_mode", %{"title" => session.title, "mode" => mode}, 15_000) do
      # Reported at once, not at the agent's next footer read (up to 10 s later).
      {:ok, %{"mode" => applied}} ->
        Room.report_permission_mode(session.id, applied)
        json(conn, %{status: "applied", mode: applied})

      {:error, code, message} -> conn |> put_status(:conflict) |> json(%{status: "refused", error: message, code: code})
      {:error, :offline} -> conn |> put_status(:service_unavailable) |> json(%{error: "the agent on #{session.host} is offline"})
      {:error, :timeout} -> conn |> put_status(:gateway_timeout) |> json(%{error: "the agent on #{session.host} did not answer"})
    end
  end
end
