defmodule ClaudiverseServer.SeatInbox do
  @moduledoc """
  Prompts for seats that receive them through a background hook instead of a
  binary patch (replaces 003's delivery on semi seats).

  The seat runs an `asyncRewake` command hook (semi-claudiversed
  hooks/cv-inbox.sh) on SessionStart, UserPromptSubmit and Stop. It long-polls
  `GET /api/seats/:seat/inbox`; when a prompt arrives it prints it and exits 2,
  which wakes the idle seat with the prompt — measured on stock 2.1.286.

  The poll is a SeatLinks `:inbox` link, so the newest poller replaces an
  older one. Between two polls (and between a delivery and the next turn's
  poller) there is no link; a prompt arriving then is QUEUED here and handed
  to the next poll, never sent to a sidecar that cannot deliver it.

  🔴 ONLY A SEAT THAT HAS POLLED IS AN INBOX SEAT. A seat that never polls —
  every patched fleet seat — is unknown here, so `deliver/3` returns
  `:not_inbox` and Room falls through to the sidecar exactly as before.

  In memory: a server restart forgets both the marks and the queue. A seat
  re-marks itself on its next poll; a queued prompt is lost, as a prompt in
  flight on any route is during a restart.

  Each poll also says which hook EVENT started its poller. The newest poller
  replaces older ones, so that event is the seat's latest transition —
  SessionStart/Stop: it went idle, UserPromptSubmit: it went busy (measured on
  2.1.286: an inbox wake fires UserPromptSubmit, its turn's end fires Stop).
  Room uses it to recover readiness that a restart wiped (`last_event/2`).
  """
  use GenServer

  alias ClaudiverseServer.SeatLinks

  # Notification is the idle_prompt notification (about a minute at the prompt):
  # idle. It covers the turns that end with NO Stop hook — measured: an
  # interrupt (Escape) fires none, which left the seat's newest poller saying
  # "busy" (UserPromptSubmit) at an idle prompt.
  @events ~w(SessionStart UserPromptSubmit Stop Notification)

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(_), do: {:ok, %{queues: %{}, events: %{}, polled: %{}}}

  @doc """
  Deliver `content` to an inbox seat: straight to its waiting poller, else
  queued for the next poll. `:not_inbox` for a seat that has never polled.
  """
  def deliver(user_id, seat, content) do
    GenServer.call(__MODULE__, {:deliver, {user_id, seat}, content})
  end

  @doc """
  Called by a poll: mark the seat as an inbox seat and take any queued
  prompts (oldest first). The caller registers as the seat's link first, so
  nothing can slip between the take and the wait.
  """
  def checkin(user_id, seat, event \\ nil), do: GenServer.call(__MODULE__, {:checkin, {user_id, seat}, event})

  def inbox_seat?(user_id, seat), do: GenServer.call(__MODULE__, {:inbox_seat?, {user_id, seat}})

  @doc """
  Interrupt an inbox seat through its live poller. Never queued: an
  interrupt that waited for the next poll would stop the wrong turn.
  """
  def interrupt(user_id, seat), do: SeatLinks.deliver(:inbox, user_id, seat, :inbox_interrupt)

  @doc "Milliseconds since the seat's last poll, or nil for a seat that never polled."
  def last_poll_age_ms(user_id, seat), do: GenServer.call(__MODULE__, {:last_poll_age_ms, {user_id, seat}})

  @doc """
  Stop treating the seat as an inbox seat; returns what was queued for it
  (oldest first), for the caller to deliver another way.
  """
  def forget(user_id, seat), do: GenServer.call(__MODULE__, {:forget, {user_id, seat}})

  @doc "The hook event that started the seat's newest poller, or nil."
  def last_event(user_id, seat), do: GenServer.call(__MODULE__, {:last_event, {user_id, seat}})

  @impl true
  def handle_call({:deliver, {user, seat} = key, content}, _from, state) do
    case Map.fetch(state.queues, key) do
      :error ->
        {:reply, :not_inbox, state}

      {:ok, queue} ->
        # Delivered under this process's serialisation, so a poll's checkin
        # cannot interleave between the lookup and the queueing.
        case SeatLinks.deliver(:inbox, user, seat, {:inbox_message, content}) do
          :ok -> {:reply, :ok, state}
          :no_link -> {:reply, :queued, put_in(state.queues[key], queue ++ [content])}
        end
    end
  end

  def handle_call({:checkin, key, event}, _from, state) do
    events = if event in @events, do: Map.put(state.events, key, event), else: state.events
    polled = Map.put(state.polled, key, System.monotonic_time(:millisecond))
    {:reply, Map.get(state.queues, key, []), %{state | queues: Map.put(state.queues, key, []), events: events, polled: polled}}
  end

  def handle_call({:last_poll_age_ms, key}, _from, state) do
    age = with at when is_integer(at) <- Map.get(state.polled, key), do: System.monotonic_time(:millisecond) - at
    {:reply, age, state}
  end

  def handle_call({:forget, key}, _from, state) do
    {:reply, Map.get(state.queues, key, []),
     %{state | queues: Map.delete(state.queues, key), events: Map.delete(state.events, key), polled: Map.delete(state.polled, key)}}
  end

  def handle_call({:inbox_seat?, key}, _from, state), do: {:reply, Map.has_key?(state.queues, key), state}
  def handle_call({:last_event, key}, _from, state), do: {:reply, Map.get(state.events, key), state}
end
