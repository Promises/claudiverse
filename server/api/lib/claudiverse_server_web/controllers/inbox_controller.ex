defmodule ClaudiverseServerWeb.InboxController do
  @moduledoc """
  `GET /api/seats/:seat/inbox?wait=<seconds>` — the long poll a seat's
  `asyncRewake` hook makes for its next prompt (see SeatInbox).

    200 text/plain   the prompt(s), oldest first, separated by a blank line
    204              nothing arrived within `wait`; poll again
    205              interrupt: press Escape in the seat's pane, then poll again
    409              a newer poll for this seat replaced this one; stop

  `wait` defaults to 50 s and is capped at a minute (see @default_max_wait_s).
  """
  use ClaudiverseServerWeb, :controller

  alias ClaudiverseServer.{SeatInbox, SeatLinks}

  @default_wait_s 50
  # 🔴 CAPPED SHORT, WHATEVER THE CLIENT ASKS. A held poll cannot see its
  # client go away (it is waiting in `receive`), so its link stays "live" for
  # the whole wait. The poll is a seat's heartbeat (Room liveness), and an
  # hour-long wait meant a killed seat read as running for up to an hour.
  # Measured: a stock seat killed at 23:03Z, still "running idle" at 23:13Z,
  # its last poll having asked for wait=3600.
  @default_max_wait_s 60

  defp max_wait_s, do: Application.get_env(:claudiverse_server, :inbox_max_wait_s, @default_max_wait_s)

  def poll(conn, %{"seat" => seat} = params) do
    user = conn.assigns.current_user
    wait_ms = wait_seconds(params["wait"]) * 1000

    flush_stale()
    # Register BEFORE taking the queue: a prompt delivered in between is then
    # sent to this process instead of being queued behind the take.
    :ok = SeatLinks.register(:inbox, user.id, seat)
    note_poll(user, seat, params["event"], placement(params))

    result =
      case SeatInbox.checkin(user.id, seat, params["event"]) do
        [] -> await(wait_ms)
        queued -> {:prompts, queued}
      end

    SeatLinks.unregister(:inbox, user.id, seat)

    case result do
      # Unregistered now, so later prompts queue; any already sent here go out
      # with this reply rather than dying in this process's mailbox.
      {:prompts, prompts} -> send_prompts(conn, prompts ++ drain())
      :replaced -> send_resp(conn, 409, "")
      :interrupt -> send_resp(conn, 205, "")
      :timeout -> respond_after_timeout(conn)
    end
  end

  # The seat's latest transition, for a Room that lost its readiness in a
  # restart (Room.inbox_hint/2 ignores it otherwise). A Room created after
  # this poll asks SeatInbox for the same event when its sidecar joins.
  #
  # The poll also (re)starts the seat's Room. A seat with no runtime has no
  # sidecar to recreate it after a server restart, and the API proxy only does
  # on the seat's next model request — until then cv_send would answer "not
  # connected" for a seat that is sitting right there, polling.
  #
  # Every poll is also the seat's heartbeat to its Room (Room.inbox_poll/2),
  # with or without an event.
  defp note_poll(user, seat, event, placement) do
    case polling_session(user, seat) do
      nil ->
        :ok

      session ->
        # A seat with no sidecar reports its host/fleet/origin here instead
        # (what the sidecar sends when it registers). Written only on change.
        # A poll is proof the seat is alive: a row the liveness check stopped
        # during a gap reads running again (a send to a stopped row is refused).
        changed = for {k, v} <- Map.put(placement, :status, :running), Map.get(session, k) != v, into: %{}, do: {k, v}
        if changed != %{}, do: ClaudiverseServer.Sessions.update_session(session, changed)

        {:ok, _} = ClaudiverseServer.Sessions.Supervisor.start_room(session.id, owner_id: user.id)
        ClaudiverseServer.Sessions.Room.inbox_poll(session.id, event)
        # Pings queued for the seat while its listener was unbound (a server
        # restart) are bound and delivered now, not at its next finished turn.
        ClaudiverseServer.Notifications.Router.seat_seen(seat, session.id)
    end
  end

  # The seat's most recently active non-proxy row, whatever its status: a seat
  # the liveness check stopped during a gap is polling again, so that row is
  # the one to revive (status :running, below).
  #
  # ⛔ NOT "the first running row". A stale row of the same title can still
  # read running, and while the live row was stopped it won: MEASURED
  # 2026-10-09, every M5 seat's poll dropped at 13:14Z, the next polls went to
  # running ghosts of ipsum-orchestrator (idle since 2026-07-27), ipsum-admin, lorem-admin and
  # Failover, and each ghost's Room went live as a second running seat.
  defp polling_session(user, seat) do
    user.id
    |> ClaudiverseServer.Sessions.list_sessions_by_title(seat)
    |> Enum.filter(&(&1.type != :proxy))
    |> Enum.max_by(&{&1.last_activity_at, &1.id}, &newer_or_equal?/2, fn -> nil end)
  end

  defp newer_or_equal?({a, ida}, {b, idb}) do
    case NaiveDateTime.compare(a, b) do
      :gt -> true
      :lt -> false
      :eq -> ida >= idb
    end
  end

  defp placement(params) do
    base =
      for key <- [:host, :fleet, :origin, :working_directory],
          v = params[Atom.to_string(key)],
          is_binary(v) and v != "",
          into: %{},
          do: {key, v}

    case params["notify"] do
      "1" -> Map.put(base, :can_notify, true)
      "0" -> Map.put(base, :can_notify, false)
      _ -> base
    end
  end

  defp await(wait_ms) do
    receive do
      {:inbox_message, content} -> {:prompts, [content]}
      :inbox_interrupt -> :interrupt
      :seat_link_replaced -> :replaced
    after
      wait_ms -> :timeout
    end
  end

  # A prompt can land between the timeout and the unregister.
  defp respond_after_timeout(conn) do
    case drain() do
      [] -> send_resp(conn, 204, "")
      prompts -> send_prompts(conn, prompts)
    end
  end

  defp send_prompts(conn, prompts) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, Enum.join(prompts, "\n\n"))
  end

  defp drain do
    receive do
      {:inbox_message, content} -> [content | drain()]
    after
      0 -> []
    end
  end

  # This process may have served an earlier poll on the same keep-alive
  # connection; a replacement notice meant for that one is stale here.
  defp flush_stale do
    receive do
      :seat_link_replaced -> flush_stale()
      :inbox_interrupt -> flush_stale()
    after
      0 -> :ok
    end
  end

  defp wait_seconds(nil), do: min(@default_wait_s, max_wait_s())

  defp wait_seconds(raw) do
    case Integer.parse(to_string(raw)) do
      {n, ""} when n > 0 -> min(n, max_wait_s())
      _ -> @default_wait_s
    end
  end
end
