defmodule ClaudiverseServer.LoginThrottle do
  @moduledoc """
  Failed sign-ins per client address: after `max_failures` within
  `window_ms`, further attempts are refused until the oldest failure ages
  out. A sign-in can hand out a "super" token, so the password must not be
  open to guessing. A success clears the address.

  Behind Docker's userland proxy every client may share one address; then
  this throttles all sign-ins together, which for a one-operator server is
  the safer failure.
  """
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  @doc ":ok, or {:error, retry_after_seconds}."
  def check(key), do: GenServer.call(__MODULE__, {:check, key})
  def failed(key), do: GenServer.cast(__MODULE__, {:failed, key, now()})
  def succeeded(key), do: GenServer.cast(__MODULE__, {:succeeded, key})

  @impl true
  def handle_call({:check, key}, _from, state) do
    recent = recent(state, key)

    reply =
      if length(recent) >= max_failures(),
        do: {:error, max(1, div(List.last(recent) + window_ms() - now(), 1000) + 1)},
        else: :ok

    {:reply, reply, Map.put(state, key, recent)}
  end

  @impl true
  def handle_cast({:failed, key, at}, state), do: {:noreply, Map.put(state, key, [at | recent(state, key)])}
  def handle_cast({:succeeded, key}, state), do: {:noreply, Map.delete(state, key)}

  # Newest first, only those inside the window.
  defp recent(state, key) do
    cutoff = now() - window_ms()
    state |> Map.get(key, []) |> Enum.filter(&(&1 > cutoff))
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp max_failures, do: Application.get_env(:claudiverse_server, :login_max_failures, 5)
  defp window_ms, do: Application.get_env(:claudiverse_server, :login_window_ms, 60_000)
end
