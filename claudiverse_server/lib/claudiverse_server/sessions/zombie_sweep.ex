defmodule ClaudiverseServer.Sessions.ZombieSweep do
  @moduledoc """
  Stops session rows that read "running" with nothing behind them.

  A row is stopped by whatever was keeping it alive saying goodbye: the
  sidecar's socket closing, the mod's session_ended, or the Room's liveness
  check missing the inbox poll. A row that never had any of those, because it
  predates the liveness check or its Room died with a server restart before
  the poll started, has nothing left that can ever stop it. MEASURED
  2026-10-09: four such rows (ipsum-orchestrator 194445, idle since 2026-08-03; ipsum-admin
  195121; claudiverse-account-failover 202957; lorem-admin 203456) showed in the
  apps as a second running seat beside the live one of the same title.

  ## The predicate

  A zombie is a row that is `:running`, has produced nothing for `idle_ms`,
  and either

    * has NO Room, or
    * has a Room with no sidecar socket of its own, while a more recently
      active row of the same title exists (it has been SUPERSEDED).

  No Room alone is not enough: right after a server restart no seat has a Room
  until its next poll or reconnect, which is why the first sweep waits
  `first_run_ms`. Idle alone is not enough: a live seat can sit idle for hours.

  A Room alone does not prove life. Its inbox liveness counts any poll under
  the seat's TITLE, so a stale row sharing a live seat's title keeps its Room
  forever once anything starts it. MEASURED 2026-10-09: after every M5 poll
  dropped at 13:14Z, ghosts of ipsum-orchestrator (idle since 2026-07-27), ipsum-admin,
  lorem-admin and Failover were polled, got Rooms and read as second running
  seats that the first version of this sweep skipped. A seat is its most
  recently active row (InboxController.polling_session/2), so an older row
  with no socket is not one.

  A wrong stop heals itself: a live seat's next inbox poll flips its row back
  to running (InboxController.note_poll), and a sidecar's reconnect does the
  same (Sessions.create_session). The cost of a false positive is a seat
  reading stopped until its next poll.

  ## Configuration

      config :claudiverse_server, ClaudiverseServer.Sessions.ZombieSweep,
        enabled: true,
        first_run_ms: :timer.minutes(10),
        every_ms: :timer.minutes(10),
        idle_ms: :timer.minutes(30)

  Enabled unless `enabled: false` (set in test, where a timer touching the
  database would race the sandbox).
  """
  use GenServer

  require Logger

  import Ecto.Query

  alias ClaudiverseServer.Repo
  alias ClaudiverseServer.Sessions.{Room, Session}

  @defaults [enabled: true, first_run_ms: :timer.minutes(10), every_ms: :timer.minutes(10), idle_ms: :timer.minutes(30)]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  defmacrop last_activity(s) do
    quote do
      fragment(
        "COALESCE((SELECT max(m0.inserted_at) FROM messages AS m0 WHERE m0.session_id = ?), ?)",
        unquote(s).id,
        unquote(s).inserted_at
      )
    end
  end

  @doc """
  Stops every zombie row older than `idle_ms` as of `now`. Returns the stopped
  rows as `{id, title}`, so a caller (and the log) names members, not a count.
  """
  def sweep(idle_ms, now \\ NaiveDateTime.utc_now()) do
    cutoff = NaiveDateTime.add(now, -idle_ms, :millisecond)

    candidates =
      from(s in Session,
        where: s.status == :running and s.type != :proxy,
        where: last_activity(s) < ^cutoff,
        select: {s.id, s.title, s.user_id, type(last_activity(s), :naive_datetime)}
      )
      |> Repo.all()

    zombies =
      for {id, title, user_id, active_at} <- candidates, zombie?(id, title, user_id, active_at) do
        :ok = Room.ended_by_machine(id)
        {id, title}
      end

    zombies
  end

  defp zombie?(id, title, user_id, active_at) do
    case Registry.lookup(ClaudiverseServer.Sessions.Registry, id) do
      [] -> true
      [_] -> not has_sidecar?(id) and superseded?(id, title, user_id, active_at)
    end
  end

  defp has_sidecar?(id) do
    match?(%{has_sidecar: true}, Room.get_status(id))
  catch
    # A Room that will not answer is no evidence of a socket.
    :exit, _ -> false
  end

  defp superseded?(id, title, user_id, active_at) do
    from(s in Session,
      where: s.user_id == ^user_id and s.title == ^title and s.id != ^id and s.type != :proxy,
      where: last_activity(s) > ^active_at
    )
    |> Repo.exists?()
  end

  @impl true
  def init(opts) do
    config = Keyword.merge(@defaults, Keyword.merge(Application.get_env(:claudiverse_server, __MODULE__, []), opts))

    if config[:enabled] do
      Process.send_after(self(), :sweep, config[:first_run_ms])
      {:ok, config}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:sweep, config) do
    Process.send_after(self(), :sweep, config[:every_ms])

    case sweep(config[:idle_ms]) do
      [] -> :ok
      stopped -> Logger.info("ZombieSweep stopped #{length(stopped)} running row(s) with no Room: #{inspect(stopped)}")
    end

    {:noreply, config}
  rescue
    e ->
      Logger.error("ZombieSweep failed: #{Exception.message(e)}")
      {:noreply, config}
  end
end
