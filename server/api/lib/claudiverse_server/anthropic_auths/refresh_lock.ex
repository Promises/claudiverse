defmodule ClaudiverseServer.AnthropicAuths.RefreshLock do
  @moduledoc """
  Serialises token refresh per auth id.

  ## Why this exists

  Two seats leasing at the same expiry both see a stale token and both refresh.
  Anthropic's refresh response MAY carry a replacement refresh token; when it
  does, the second refresh invalidates the first's result and one seat walks away
  holding a token that was already superseded.

  The failure is silent — both callers get an HTTP 200 — and it only shows up
  later as an unexplained 401. So the lock is not an optimisation to avoid a
  duplicate request; it is what keeps the stored refresh token single-valued.

  ## Why a GenServer rather than a database lock

  The backing store is SQLite (`DATABASE_PATH`), which has no row-level
  `SELECT … FOR UPDATE` to lean on. A single serialising process is the simplest
  thing that actually holds, and this is a single-node deployment.

  ⚠️ That is the bound: this serialises within ONE BEAM node. If claudiverse ever
  runs more than one node against a shared database, this must become a database
  lock or a global process — and nothing here would fail loudly at the moment
  that assumption breaks, which is exactly why it is written down.

  The critical section holds a `:httpc` call, so the timeout is generous. It is
  finite anyway: a wedged refresh must not block every lease forever.
  """

  use GenServer

  require Logger

  @call_timeout 45_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, Keyword.put(opts, :name, __MODULE__))

  @doc """
  Run `fun` with no other refresh in flight for `auth_id`.

  Serialised per id, so a slow refresh on one account never blocks a lease on
  another.
  """
  def with_lock(auth_id, fun) when is_function(fun, 0) do
    GenServer.call(__MODULE__, {:locked, auth_id, fun}, @call_timeout)
  catch
    :exit, {:timeout, _} ->
      Logger.error("[anthropic_auths] refresh lock timed out for auth #{auth_id}")
      {:error, :refresh_timeout}
  end

  @impl true
  def init(:ok), do: {:ok, %{queues: %{}}}

  @impl true
  def handle_call({:locked, auth_id, fun}, from, state) do
    # One worker per auth id at a time; later callers for the SAME id queue
    # behind it, callers for other ids are unaffected.
    case state.queues[auth_id] do
      nil ->
        {:noreply, start_work(state, auth_id, fun, from)}

      %{waiting: waiting} = q ->
        {:noreply, put_in(state.queues[auth_id], %{q | waiting: waiting ++ [{fun, from}]})}
    end
  end

  @impl true
  def handle_info({:work_done, pid, result}, state) do
    case pop_by_pid(state, pid) do
      nil ->
        {:noreply, state}

      {auth_id, %{ref: ref, from: from, waiting: waiting}} ->
        Process.demonitor(ref, [:flush])
        GenServer.reply(from, result)
        {:noreply, advance(state, auth_id, waiting)}
    end
  end

  # A refresh that dies must not leave the id locked forever. Reply to the
  # caller and drain the queue, rather than silently stranding every later
  # lease on this account.
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case pop_by_pid(state, pid) do
      # Normal exit after :work_done already handled it.
      nil ->
        {:noreply, state}

      {auth_id, %{from: from, waiting: waiting}} ->
        Logger.error("[anthropic_auths] refresh died for #{auth_id}: #{inspect(reason)}")
        GenServer.reply(from, {:error, {:refresh_crashed, reason}})
        {:noreply, advance(state, auth_id, waiting)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # 🔴 spawn_monitor, NOT Task.async — Task.async LINKS the worker to this
  # GenServer, so a raising refresh would kill the lock itself and take leasing
  # down for EVERY account, not just the one that failed. The :DOWN clause below
  # was written for that case and could never run, because the link killed us
  # first. MEASURED: a `raise` inside with_lock/2 terminated the GenServer and
  # the calling process, and the crash-recovery assertions never executed.
  # Monitoring without linking is what makes the failure local.
  defp start_work(state, auth_id, fun, from) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        result =
          try do
            fun.()
          rescue
            e -> {:error, {:refresh_raised, Exception.message(e)}}
          catch
            kind, reason -> {:error, {:refresh_threw, kind, reason}}
          end

        send(parent, {:work_done, self(), result})
      end)

    put_in(state.queues[auth_id], %{pid: pid, ref: ref, from: from, waiting: []})
  end

  defp advance(state, auth_id, []) do
    %{state | queues: Map.delete(state.queues, auth_id)}
  end

  defp advance(state, auth_id, [{fun, from} | rest]) do
    state = %{state | queues: Map.delete(state.queues, auth_id)}
    new_state = start_work(state, auth_id, fun, from)
    put_in(new_state.queues[auth_id].waiting, rest)
  end

  defp pop_by_pid(state, pid) do
    Enum.find_value(state.queues, fn {auth_id, q} ->
      if q.pid == pid, do: {auth_id, q}
    end)
  end
end
