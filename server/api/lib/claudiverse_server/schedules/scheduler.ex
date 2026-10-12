defmodule ClaudiverseServer.Schedules.Scheduler do
  @moduledoc """
  Fires the due schedules every 30 s (Schedules.fire_due/1) and retries the
  pending runs (Schedules.retry_pending/1). The first tick runs at boot, which
  is the recovery path: a schedule due while the server was down fires there,
  once, late.

  Between ticks a pending run goes out as soon as its seat is ready: the
  Notifications.Router passes on every seat seen alive (`seat_seen/2`) and
  every seat gone idle (`seat_idle/1`). Those come several times a minute per
  seat, so they are checked against the targets of pending runs held in
  memory, and only a hit reads the database.

  Every call runs in this one process, so a tick and a seat's idle cannot
  deliver the same run twice.
  """
  use GenServer
  require Logger

  alias ClaudiverseServer.Schedules

  @tick_ms 30_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Fire and retry now (tests, and an operator in a remote shell)."
  def tick(now \\ DateTime.utc_now()), do: GenServer.call(__MODULE__, {:tick, now})

  @doc "The seat `title` is alive as `session_id` (Router.seat_seen/2)."
  def seat_seen(title, session_id), do: GenServer.cast(__MODULE__, {:seat_seen, title, session_id})

  @doc "The session `session_id` finished a turn (Router.went_idle/1)."
  def seat_idle(session_id), do: GenServer.cast(__MODULE__, {:seat_idle, session_id})

  @impl true
  def init(nil) do
    # Disabled in tests, which tick by hand inside their sandbox.
    if enabled?(), do: send(self(), :tick)
    {:ok, %{titles: MapSet.new(), sessions: MapSet.new()}}
  end

  @impl true
  def handle_call({:tick, now}, _from, state) do
    {runs, state} = run_tick(state, now)
    {:reply, runs, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {_runs, state} = run_tick(state, DateTime.utc_now())
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:seat_seen, title, session_id}, state) do
    if MapSet.member?(state.titles, title),
      do: {:noreply, guarded(state, fn -> Schedules.deliver_pending(title, session_id) end)},
      else: {:noreply, state}
  end

  def handle_cast({:seat_idle, session_id}, state) do
    with true <- MapSet.member?(state.sessions, session_id),
         %{title: title} <- ClaudiverseServer.Sessions.get_session(session_id) do
      {:noreply, guarded(state, fn -> Schedules.deliver_pending(title, session_id) end)}
    else
      _ -> {:noreply, state}
    end
  end

  defp run_tick(state, now) do
    try do
      fired = Schedules.fire_due(now)
      Schedules.retry_pending(now)
      {fired, refresh(state)}
    rescue
      e ->
        Logger.error("[schedules] tick failed: " <> Exception.message(e))
        {[], state}
    end
  end

  # Never let one bad delivery take the Scheduler (and every schedule's
  # timer) down with it; the next tick tries again.
  defp guarded(state, fun) do
    try do
      fun.()
      refresh(state)
    rescue
      e ->
        Logger.error("[schedules] delivery failed: " <> Exception.message(e))
        state
    end
  end

  defp refresh(state) do
    {titles, sessions} = Schedules.pending_targets()
    %{state | titles: titles, sessions: sessions}
  end

  defp enabled?, do: Application.get_env(:claudiverse_server, __MODULE__, [])[:enabled] != false
end
