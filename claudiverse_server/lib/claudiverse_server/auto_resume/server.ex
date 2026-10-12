defmodule ClaudiverseServer.AutoResume.Server do
  @moduledoc """
  The one process auto-resume runs in (ClaudiverseServer.AutoResume).

  The proxy reports each main-loop model call to it by cast, never on the
  request's path: a response started streaming (`stream_started/1`), it ended
  (`stream_ended/1`), or the call was refused for want of a pool account
  (`refused/2`). How many responses stream to each seat is kept in memory; the
  database is written only when a seat goes from none to one, from one to
  none, or an incident opens or closes. That row is what survives a restart:
  a seat still in flight at boot had its stream cut (`boot/1`, once per VM).

  It nudges at every tick (30 s), at every pool event, and when a stalled seat
  goes idle or is seen alive (the Notifications.Router passes those on, as it
  does for scheduled prompts). The seat signals are checked against the
  stalled titles held in memory, so only a hit reads the database.

  `shutting_down/0` (Application.prep_stop/1) freezes the in-flight rows: a
  stream cut because the server is stopping must still read in flight at the
  next boot. A stream that finishes whole while the server drains is cleared
  as always.
  """
  use GenServer
  require Logger

  alias ClaudiverseServer.{AnthropicAuths, AutoResume, Sessions}

  @tick_ms 30_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "A response started streaming to `key` (`{user_id, title, claude_session_id}`)."
  def stream_started(key), do: GenServer.cast(__MODULE__, {:started, key})

  @doc "A response to `key` stopped streaming: `clean` when it reached the seat whole."
  def stream_ended(key, clean), do: GenServer.cast(__MODULE__, {:ended, key, clean})

  @doc "A model call of `key` was refused: no pool account (`detail` says what the pool said)."
  def refused(key, detail), do: GenServer.cast(__MODULE__, {:refused, key, detail})

  @doc "The seat `title` is alive as `session_id` (Router.seat_seen/2)."
  def seat_seen(title, session_id), do: GenServer.cast(__MODULE__, {:seat_seen, title, session_id})

  @doc "The session `session_id` finished a turn (Router.went_idle/1)."
  def seat_idle(session_id), do: GenServer.cast(__MODULE__, {:seat_idle, session_id})

  @doc "The server is stopping: in-flight rows stay as they are (Application.prep_stop/1)."
  def shutting_down do
    GenServer.call(__MODULE__, :shutting_down, 5_000)
  catch
    :exit, _ -> :ok
  end

  @doc "Turn the rows still in flight into restart incidents (at boot; tests call it)."
  def boot(now \\ DateTime.utc_now()), do: GenServer.call(__MODULE__, {:boot, now})

  @doc "Nudge what is due now (tests, and an operator in a remote shell)."
  def tick(now \\ DateTime.utc_now()), do: GenServer.call(__MODULE__, {:tick, now})

  @impl true
  def init(nil) do
    # Disabled in tests, which boot and tick by hand inside their sandbox.
    if enabled?() do
      Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, AnthropicAuths.pool_topic())
      send(self(), :boot)
    end

    {:ok, %{streams: %{}, stalled: MapSet.new(), open: %{}, stopping: false}}
  end

  @impl true
  def handle_call(:shutting_down, _from, state), do: {:reply, :ok, %{state | stopping: true}}

  def handle_call({:boot, now}, _from, state) do
    cut = guarded("boot", fn -> AutoResume.boot(now) end, [])
    {:reply, cut, refresh(state)}
  end

  def handle_call({:tick, now}, _from, state) do
    stalls = guarded("tick", fn -> AutoResume.nudge_due(now) end, [])
    {:reply, stalls, refresh(state)}
  end

  @impl true
  def handle_cast({:started, {user_id, title, _} = key}, state) do
    k = {user_id, title}
    n = Map.get(state.streams, k, 0)
    state = %{state | streams: Map.put(state.streams, k, n + 1)}

    # The row changes only when the seat goes from no stream to one, or an
    # incident closes: not on every response.
    if n == 0 or Map.has_key?(state.open, k) do
      result = guarded("stream_started", fn -> AutoResume.stream_started(key) end, :ok)
      {:noreply, if(result == :resumed, do: refresh(state), else: state)}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:ended, {user_id, title, _} = key, clean}, state) do
    k = {user_id, title}

    case Map.get(state.streams, k, 0) do
      n when n > 1 ->
        {:noreply, %{state | streams: Map.put(state.streams, k, n - 1)}}

      _ ->
        state = %{state | streams: Map.delete(state.streams, k)}
        # Stopping, and cut: the stream ends because the server does. Left in
        # flight, it is a restart incident at the next boot, which is what it
        # is. One that finished whole while the server drained is not.
        unless state.stopping and not clean, do: guarded("stream_ended", fn -> AutoResume.stream_ended(key) end, :ok)
        {:noreply, state}
    end
  end

  def handle_cast({:refused, {user_id, title, _} = key, detail}, state) do
    if Map.get(state.open, {user_id, title}) == "no_available_auth" do
      {:noreply, state}
    else
      guarded("refused", fn -> AutoResume.refused(key, detail, DateTime.utc_now()) end, :ok)
      {:noreply, refresh(state)}
    end
  end

  def handle_cast({:seat_seen, title, session_id}, state) do
    {:noreply, nudge_seat(state, title, session_id)}
  end

  def handle_cast({:seat_idle, session_id}, state) do
    # A read only while some seat is stalled at all.
    if MapSet.size(state.stalled) > 0 do
      case Sessions.get_session(session_id) do
        %{title: title} -> {:noreply, nudge_seat(state, title, session_id)}
        _ -> {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:boot, state) do
    cut = guarded("boot", fn -> AutoResume.boot(DateTime.utc_now()) end, [])
    # The cut seats are due as the grace ends, not at the tick after it.
    if cut != [], do: Process.send_after(self(), :nudge, AutoResume.grace_s() * 1000 + 1000)
    send(self(), :tick)
    {:noreply, refresh(state)}
  end

  def handle_info(:nudge, state) do
    guarded("nudge", fn -> AutoResume.nudge_due(DateTime.utc_now()) end, [])
    {:noreply, refresh(state)}
  end

  def handle_info(:tick, state) do
    guarded("tick", fn -> AutoResume.nudge_due(DateTime.utc_now()) end, [])
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, refresh(state)}
  end

  # A pool event: an account may be leasable again. A weekly reset is new
  # capacity, so a pool incident already nudged gets one more continue.
  def handle_info({"pool", %{"change" => change} = event}, state) do
    if change == "reset" and event["limit"] == "weekly", do: guarded("rearm", &AutoResume.rearm_pool/0, 0)
    guarded("pool event", fn -> AutoResume.nudge_due(DateTime.utc_now()) end, [])
    {:noreply, refresh(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp nudge_seat(state, title, session_id) do
    hits = for {user_id, ^title} <- state.stalled, do: user_id

    if hits == [] do
      state
    else
      user_id =
        case Sessions.get_session(session_id) do
          %{user_id: u} -> u
          _ -> nil
        end

      if user_id in hits, do: guarded("seat", fn -> AutoResume.nudge_seat(user_id, title, DateTime.utc_now()) end, nil)
      refresh(state)
    end
  end

  # Never let one bad write take the process (and every seat's counts) down;
  # the next tick tries again.
  defp guarded(what, fun, fallback) do
    fun.()
  rescue
    e ->
      Logger.error("[auto_resume] #{what} failed: " <> Exception.message(e))
      fallback
  end

  defp refresh(state) do
    open = guarded("refresh", fn -> AutoResume.open() end, nil)

    if open do
      %{state |
        open: Map.new(open, &{{&1.user_id, &1.seat_title}, &1.reason}),
        stalled: for(s <- open, s.state == "stalled", into: MapSet.new(), do: {s.user_id, s.seat_title})}
    else
      state
    end
  end

  defp enabled?, do: Application.get_env(:claudiverse_server, AutoResume, [])[:enabled] != false
end
