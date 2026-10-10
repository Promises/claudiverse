defmodule ClaudiverseServer.Runners do
  @moduledoc """
  Runner slots, as their cv-runner processes report them. Before this the
  server had no runner registry at all: a runner only polled (halt check,
  claim), so whether a slot was idle or busy, and with which seat and task,
  lived only inside its process — and ipsum-fleet's forum-sourced slots left no trace
  on the server whatsoever (measured 2026-10-05).

  A runner POSTs a heartbeat (`heartbeat/2`) on every change of its state and
  every ~30 s. The registry is in memory and derived, never stored: a slot
  whose last heartbeat is older than `missing_after_ms` reads "missing", and a
  restart of the server forgets slots until they next beat (≤30 s).

  Every change a viewer would see — state, seat, task, or going missing — is
  broadcast as "runner" on the user's `Hosts.events_topic/1`.
  """
  use GenServer

  alias ClaudiverseServer.Hosts

  @states ~w(idle busy halted stopped)

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    Process.send_after(self(), :sweep, sweep_ms())
    {:ok, state}
  end

  def states, do: @states

  @doc """
  Record a runner's report. `report` is already validated (see
  RunnerController): slot, fleet, state, and optional host, lane, channel,
  task_source, model, seat, task, since. "stopped" removes the slot: a runner
  closing cleanly says so rather than going missing.
  """
  def heartbeat(user_id, report), do: GenServer.call(__MODULE__, {:heartbeat, user_id, report})

  @doc "The user's runner slots, each with its derived status (its state, or \"missing\")."
  def list(user_id), do: GenServer.call(__MODULE__, {:list, user_id})

  @impl true
  def handle_call({:heartbeat, user_id, report}, _from, state) do
    key = {user_id, report.slot}
    previous = Map.get(state, key)

    if report.state == "stopped" do
      if previous, do: announce(user_id, Map.put(view(previous), :status, "stopped"))
      {:reply, :ok, Map.delete(state, key)}
    else
      entry = Map.put(report, :last_seen, DateTime.utc_now())
      if previous == nil or changed?(previous, entry), do: announce(user_id, view(entry))
      {:reply, :ok, Map.put(state, key, entry)}
    end
  end

  def handle_call({:list, user_id}, _from, state) do
    runners = for {{^user_id, _slot}, entry} <- state, do: view(entry)
    {:reply, Enum.sort_by(runners, &{&1.fleet, &1.slot}), state}
  end

  # A slot that stopped beating goes "missing" ONCE: announced on the sweep
  # that first finds it stale, then kept (so the board still shows the hole)
  # until it beats again or reports "stopped".
  @impl true
  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, sweep_ms())

    state =
      Map.new(state, fn {{user_id, _} = key, entry} ->
        if missing?(entry) and not Map.get(entry, :announced_missing, false) do
          announce(user_id, view(entry))
          {key, Map.put(entry, :announced_missing, true)}
        else
          {key, entry}
        end
      end)

    {:noreply, state}
  end

  defp changed?(a, b), do: Map.take(a, [:state, :seat, :task, :fleet, :lane, :host]) != Map.take(b, [:state, :seat, :task, :fleet, :lane, :host]) or Map.get(a, :announced_missing, false)

  defp missing?(entry), do: DateTime.diff(DateTime.utc_now(), entry.last_seen, :millisecond) > missing_after_ms()

  defp view(entry) do
    entry
    |> Map.drop([:announced_missing])
    |> Map.put(:status, if(missing?(entry), do: "missing", else: entry.state))
  end

  defp announce(user_id, runner),
    do: Phoenix.PubSub.broadcast(ClaudiverseServer.PubSub, Hosts.events_topic(user_id), {"runner", runner})

  defp missing_after_ms, do: Application.get_env(:claudiverse_server, :runner_missing_after_ms, 75_000)
  defp sweep_ms, do: Application.get_env(:claudiverse_server, :runner_sweep_ms, 15_000)
end
