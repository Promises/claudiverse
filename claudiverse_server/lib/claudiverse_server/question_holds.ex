defmodule ClaudiverseServer.QuestionHolds do
  @moduledoc """
  AskUserQuestion holds that are POLLED instead of held in one request.

  The claudiverse-seat mod asks through the engine's `$.http.fetch`, which
  gives up after 30 s whatever the server does (measured on 2.1.292: a keepalive
  space every 10 s did not extend it). So the mod polls
  `POST /api/hooks/seat/:seat/pretooluse` with `wait` (seconds), and each poll
  ends with the answer or with `{"pending": true}` before that cap.

  Between two polls the seat has no `:question` link. An answer arriving then
  is STASHED here for the question's next poll, never sent to a sidecar that
  cannot deliver it, the way SeatInbox queues prompts between inbox polls.

  🔴 ONLY A SEAT THAT IS POLLING A QUESTION IS KNOWN HERE. A seat whose hook
  holds one request (settings HTTP hooks, the semi seats) never checks in, so
  `deliver/3` answers `:no_link` and Room behaves exactly as before.

  A question whose polls stop for @stale_ms is forgotten: its seat gave up
  (answered at the terminal, ended, or lost the server) without withdrawing.

  In memory: a server restart forgets pending questions. The mod keeps
  polling through the outage (0.8.7), and its next poll opens the question
  again. An answer that arrives before that poll, for a question not known
  here, is kept by its tool_use_id for @orphan_ms and handed to the poll that
  names it. `deliver/3` still answers `:no_link` then, so a seat with a
  sidecar is answered there as before. MEASURED 2026-10-07: an app answer to
  claudiverse-android's question, sent after a server restart, was dropped;
  the seat's 0.8.5 mod had stopped polling at the restart.
  """
  use GenServer

  alias ClaudiverseServer.SeatLinks

  # Two missed polls at the mod's 25 s cadence.
  @stale_ms 60_000
  # An answer for a question no poll has named yet (the server restarted).
  @orphan_ms 600_000

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(_), do: {:ok, %{}}

  @doc """
  Called by a poll after it registered as the seat's `:question` link:
  marks `tool_use_id` pending and takes an answer stashed for it, if any.
  Returns `{:new | :again, stashed | nil, opened_at_ms}`; a different question
  replaces the seat's old one.
  """
  def checkin(user_id, seat, tool_use_id),
    do: GenServer.call(__MODULE__, {:checkin, {user_id, seat}, tool_use_id})

  @doc """
  Deliver an answer or decline: to the seat's waiting poll, else stashed for
  the next one when the seat is polling a question. `:ok`, `:queued`, or
  `:no_link` (no question here: the caller tries the sidecar).
  """
  def deliver(user_id, seat, message), do: GenServer.call(__MODULE__, {:deliver, {user_id, seat}, message})

  @doc "The question is settled (answered, declined, withdrawn or expired): forget it."
  def close(user_id, seat, tool_use_id), do: GenServer.call(__MODULE__, {:close, {user_id, seat}, tool_use_id})

  @impl true
  def handle_call({:checkin, key, id}, _from, state) do
    now = System.monotonic_time(:millisecond)

    case Map.get(state, key) do
      %{id: ^id, orphan: at, stash: stash} when now - at < @orphan_ms ->
        {:reply, {:new, stash, now}, Map.put(state, key, %{id: id, opened: now, polled: now, stash: nil})}

      %{id: ^id, polled: polled} = q when is_integer(polled) and now - polled < @stale_ms ->
        {:reply, {:again, q.stash, q.opened}, Map.put(state, key, %{q | stash: nil, polled: now})}

      _ ->
        {:reply, {:new, nil, now}, Map.put(state, key, %{id: id, opened: now, polled: now, stash: nil})}
    end
  end

  def handle_call({:deliver, {user, seat} = key, message}, _from, state) do
    # Under this process's serialisation, so a poll's checkin cannot interleave
    # between the link lookup and the stash.
    case SeatLinks.deliver(:question, user, seat, message) do
      :ok ->
        {:reply, :ok, state}

      :no_link ->
        now = System.monotonic_time(:millisecond)

        case Map.get(state, key) do
          %{polled: polled} = q when is_integer(polled) and now - polled < @stale_ms ->
            {:reply, :queued, Map.put(state, key, %{q | stash: message})}

          _ ->
            {:reply, :no_link, orphan(Map.delete(state, key), key, message, now)}
        end
    end
  end

  def handle_call({:close, key, id}, _from, state) do
    case Map.get(state, key) do
      %{id: ^id} -> {:reply, :ok, Map.delete(state, key)}
      _ -> {:reply, :ok, state}
    end
  end

  # Kept for a poll that names its tool_use_id; an answer without one is not.
  defp orphan(state, key, {_, %{"tool_use_id" => id}} = message, now) when is_binary(id) and id != "",
    do: Map.put(state, key, %{id: id, orphan: now, polled: nil, stash: message})

  defp orphan(state, _key, _message, _now), do: state
end
