defmodule ClaudiverseServer.Sessions.Room do
  @moduledoc """
  GenServer managing a single Claude Code session room.

  Currently sidecar-only: Claude runs on the user's host machine and connects
  via WebSocket to mirror its session. Observers (web/mobile clients) join the
  same room to view output and send input back through the sidecar.

  Spawned mode (server starts Claude as a child process) will be added later.
  """
  use GenServer

  require Logger

  alias ClaudiverseServer.Sessions
  alias ClaudiverseServer.Notifications.Router
  alias ClaudiverseServer.QuestionHolds
  alias ClaudiverseServer.SeatLinks

  @max_buffer_size 500
  # An agent's rows (a fork, a background subagent, a teammate) and the agent
  # list: the mod mirrors them as agent_* types (claudiverse-seat 0.9.0). They
  # have a replay buffer of their own, so a busy fork cannot push main's
  # history out of main's, and they never touch main's busy/idle.
  @agent_types ~w(agent_started agent_message agent_turn_complete agent_ended agents)
  @max_agent_buffer 300
  @default_mode_reply_ms 8_000
  # The inbox poll re-arms about once a minute (cv-inbox.sh waits 55 s), so
  # three missed checks is a seat that is gone, not one between polls.
  @default_liveness_ms 60_000
  @inbox_miss_limit 3

  # Frames viewers need only while they happen: broadcast, never stored. Each
  # has a final form that IS stored (the assistant message a stream builds,
  # the tool result a progress frame precedes). MEASURED 2026-10-05 on a full
  # dump: of 11.3 GB of stored messages, stream_event was 5.66 GB (22.5M
  # rows) and the four tool-status types 1.28 GB (3.6M rows); nothing read
  # any of them back (the replay already skipped stream_event).
  @live_only ~w(stream_event progress set_in_progress_tool_use_ids interruptible_tool_in_progress stream_request_start)

  # Rows that say nothing about whether the seat is working: they leave its
  # readiness as it was. A compaction is reported as its own row (the mod's
  # session.compact) and can land with no turn after it: compacted while idle,
  # or the mod's /compact inbox command, whose idle frame can arrive first.
  # Counted as work, it read busy until the next turn. MEASURED 2026-10-11:
  # lorem-orchestrator went idle->busy trigger=compact at 10:23:57Z and
  # stayed busy ~20 min; every cv_send to it was refused as busy meanwhile.
  @readiness_neutral ~w(compact)

  defstruct [
    :session_id,
    :sidecar_channel_pid,
    :sidecar_monitor_ref,
    # Set while a lost sidecar's grace period runs (see the :DOWN handler).
    :sidecar_gone,
    :owner_id,
    status: :running,
    idle: false,
    message_buffer: [],
    # agent_* rows, newest first (see @agent_types), and the seat's latest
    # agent list as the mod last reported it.
    agent_buffer: [],
    agents: [],
    # The seat's background work (shells, monitors, subagents, workflows) as
    # the mod last reported it: a {type: "background_tasks"} row's tasks.
    background_tasks: [],
    pending_permissions: %{},
    sequence: 1,
    last_task_sig: nil,
    # The seat's permission mode as it last reported it (nil = never reported:
    # a seat without the 013 runtime hook).
    permission_mode: nil,
    # request_id => caller awaiting a set_permission_mode result
    pending_modes: %{},
    # False until anything has told this Room whether the seat is idle (a
    # mirrored message, a heartbeat, a delivery). A Room created by a server
    # restart starts here; only then may the inbox hint set readiness.
    readiness_known: false,
    # A seat with no sidecar is alive while its inbox poll is: true from its
    # first poll, cleared (and the session stopped) once the poll has been
    # missing for @inbox_miss_limit liveness checks.
    inbox_live: false,
    inbox_misses: 0
  ]

  # --- Client API ---

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  @doc """
  Deliver `content` to the agent — but ONLY if it is idle. If the agent is busy
  the send is REJECTED, not queued: returns `{:busy, hint}` so the caller holds
  it and re-decides on the agent's next idle, rather than landing a possibly
  stale message on a working agent. Idle agents get it immediately (`:delivered`).
  """
  def send_message(session_id, content) do
    GenServer.call(via(session_id), {:send_message, content})
  catch
    :exit, _ -> {:error, :not_connected}
  end

  @doc """
  Deliver `content` even if the seat is busy — the app's force send. Takes the
  same path as `send_message/2` (channel, else sidecar) without the idle check;
  a busy seat queues it like a prompt typed mid-turn. Only NotifyController
  calls this, and only for an "app" token.
  """
  def force_message(session_id, content) do
    GenServer.call(via(session_id), {:force_message, content})
  catch
    :exit, _ -> {:error, :not_connected}
  end

  @doc "Inject content unconditionally (Router ping delivery — bypasses reject-busy)."
  def inject(session_id, content) do
    GenServer.cast(via(session_id), {:inject, content})
  end

  def send_raw(session_id, data) do
    GenServer.cast(via(session_id), {:send_raw, data})
  end

  def send_permission_response(session_id, request_id, decision) do
    GenServer.cast(via(session_id), {:permission_response, request_id, decision})
  end

  @doc """
  A polled permission prompt's answer, for its next poll: `{:decided,
  behavior}` (taken, so it is handed over once), `:pending`, or `:gone` (settled
  or withdrawn).
  """
  def take_permission_decision(session_id, request_id) do
    GenServer.call(via(session_id), {:take_permission_decision, request_id})
  end

  @doc "A pending permission prompt was settled elsewhere; drop it from the panel."
  def permission_withdrawn(session_id, request_id) do
    GenServer.cast(via(session_id), {:permission_withdrawn, request_id})
  end

  @doc """
  Tell this session a preferred Anthropic account is available again.

  Push, not poll: the server knows the instant a cooldown lapses, and N seats
  polling to discover it would be N times the work to learn something one party
  already knows.
  """
  def notify_auth_upgrade(session_id) do
    GenServer.cast(via(session_id), :anthropic_auth_upgrade)
  end

  @doc """
  Rename a seat from the server — the remote counterpart of CLAUDIVERSE_TITLE.

  The seat applies it and re-POSTs, which is what actually updates the session
  row and its account assignment; this only asks. A seat pinned by
  CLAUDIVERSE_TITLE REFUSES and logs why, because a launcher re-applies that var
  on every restart, so an override there would revert on the next bounce.
  """
  def set_title(session_id, title) do
    GenServer.cast(via(session_id), {:set_title, title})
  end

  def interrupt(session_id) do
    GenServer.cast(via(session_id), :interrupt)
  end

  def answer(session_id, payload) do
    GenServer.cast(via(session_id), {:answer, payload})
  end

  def decline(session_id, payload) do
    GenServer.cast(via(session_id), {:decline, payload})
  end

  @doc """
  `answer/2` or `decline/2` (`kind` :answer | :decline), saying where it went:
  `:delivered` (a waiting question poll took it), `:queued` (kept for the
  seat's next poll), `:sidecar` (sent to the seat's sidecar), or
  `:not_waiting`: no poll, no hold and no sidecar, so nothing will see it.
  MEASURED 2026-10-08: cv_answer said "answered" to an XPS seat whose hold had
  expired; the answer went nowhere and the seat sat at its dialog 16 min.
  """
  def answer_sync(session_id, kind, payload) when kind in [:answer, :decline] do
    GenServer.call(via(session_id), {:answer_sync, kind, payload})
  end

  def mirror_messages(session_id, messages) do
    GenServer.cast(via(session_id), {:mirror_messages, messages})
  end

  @doc """
  Set the seat's permission mode through its own setter (013 runtime hook), as
  Shift+Tab would. Waits for the seat's answer: `{:ok, mode}`,
  `{:refused, error, code}` when the seat declined (e.g. auto not available
  there), or `{:error, :not_connected | :timeout}`. Only the app may call this
  (SessionController.permission_mode).
  """
  def set_permission_mode(session_id, mode) do
    GenServer.call(via(session_id), {:set_permission_mode, mode}, mode_reply_ms() + 2_000)
  catch
    :exit, _ -> {:error, :not_connected}
  end

  @doc "The seat's answer to a set_permission_mode request."
  def permission_mode_result(session_id, payload) do
    GenServer.cast(via(session_id), {:permission_mode_result, payload})
  end

  @doc """
  A seat's inbox poll names the hook event that started its poller — its
  latest transition (SeatInbox). Used ONLY while this Room has no readiness of
  its own, i.e. right after a server restart, when a seat whose readiness
  comes from the API proxy would otherwise read busy until its next request.
  """
  def inbox_hint(session_id, event) do
    GenServer.cast(via(session_id), {:inbox_hint, event})
  end

  @doc """
  The seat's inbox poll arrived. For a seat with no sidecar this is its
  heartbeat: it makes the seat read as connected, and its absence
  eventually stops the session (see the :liveness tick).
  """
  def inbox_poll(session_id, event) do
    GenServer.cast(via(session_id), {:inbox_poll, event})
  end

  @doc "The seat reports its current mode (on change, and on joining)."
  def report_permission_mode(session_id, mode) do
    GenServer.cast(via(session_id), {:report_permission_mode, mode})
  end

  def register_sidecar(session_id, channel_pid) do
    GenServer.call(via(session_id), {:register_sidecar, channel_pid})
  end

  @doc """
  The messages a joining viewer is replayed. `[]` for a session with no Room:
  a stopped session gets no Room back after a server restart, and a viewer
  left open on it rejoined every 2 s, crashing its channel each time (19 crash
  logs in the first minute after the 2026-10-02 20:37Z swap).
  """
  def get_replay_buffer(session_id) do
    GenServer.call(via(session_id), :get_replay_buffer)
  catch
    :exit, _ -> []
  end

  @doc """
  The agent side of a replay: the agent_* rows (oldest first), the latest
  agent list, how many of its agents are working, and the seat's background
  work (shells, monitors, ...) as last reported. Empty without a Room.
  """
  def get_agent_replay(session_id) do
    GenServer.call(via(session_id), :get_agent_replay)
  catch
    :exit, _ -> %{messages: [], agents: [], busy_agents: 0, background_tasks: []}
  end

  @doc """
  The permission prompts still waiting for an answer, as `permission_request`
  broadcasts them: a viewer that opens the seat after a prompt was asked
  gets them in its replay, rather than a prompt it cannot see or answer.
  A prompt already decided, waiting only for the seat to collect the
  decision, is not among them.
  """
  def get_pending_permissions(session_id) do
    GenServer.call(via(session_id), :get_pending_permissions)
  catch
    :exit, _ -> []
  end

  @doc """
  Live state for one session. Optionally with a short timeout.

  🔴 A LIST MUST NOT WAIT 5s PER ROW. The default GenServer timeout made
  /api/sessions hang: a Room busy processing mirror traffic queues this call
  behind its backlog, and the endpoint asks every running session in turn. With
  a handful of active seats the request never returned — the sessions list went
  down entirely while every other endpoint stayed healthy (anthropic_auths
  answered in 123ms).

  Callers rendering a list should pass a small timeout and treat a miss as
  "unknown". A caller that genuinely needs the answer can wait the default.
  """
  def get_status(session_id, timeout \\ 5000) do
    GenServer.call(via(session_id), :get_status, timeout)
  end

  @doc """
  The seat's machine closed it on request (a stop the host agent confirmed):
  end the session now. Without this a seat with no sidecar socket (the mod's
  inbox poll) reads "running" until the liveness check gives up on it, ~3
  min — MEASURED 2026-10-05: a profile restart was refused as "already
  running" by the row of the seat it had just stopped. A seat whose Room is
  gone (nothing live) only has its row stopped.
  """
  def ended_by_machine(session_id) do
    case Registry.lookup(ClaudiverseServer.Sessions.Registry, session_id) do
      [{_pid, _}] -> GenServer.call(via(session_id), :ended_by_machine)
      [] -> Sessions.update_session(Sessions.get_session!(session_id), %{status: :stopped}) && :ok
    end
  end

  defp liveness_ms, do: Application.get_env(:claudiverse_server, :room_liveness_ms, @default_liveness_ms)
  defp sidecar_grace_ms, do: Application.get_env(:claudiverse_server, :sidecar_grace_ms, 20_000)

  defp mode_reply_ms, do: Application.get_env(:claudiverse_server, :mode_reply_ms, @default_mode_reply_ms)

  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp via(session_id) do
    {:via, Registry, {ClaudiverseServer.Sessions.Registry, session_id}}
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    owner_id = Keyword.get(opts, :owner_id)

    state = %__MODULE__{
      session_id: session_id,
      owner_id: owner_id,
      sequence: Sessions.next_sequence(session_id),
      # The buffer is memory only: seed it from the stored messages, or a
      # Room that starts after a server restart replays an empty history.
      message_buffer: Sessions.recent_payloads(session_id, @max_buffer_size),
      agent_buffer: Sessions.recent_agent_payloads(session_id, @max_agent_buffer),
      agents: Sessions.latest_agents(session_id),
      background_tasks: Sessions.latest_background_tasks(session_id)
    }

    Process.send_after(self(), :liveness, liveness_ms())
    {:ok, restore_idle(state)}
  end

  # Readiness is memory only, and a mod seat reports idle only when a turn
  # ends, so a Room started by a server restart read an idle seat as busy until
  # its next turn, which for an idle seat never comes. MEASURED 2026-10-07:
  # lorem-orchestrator, idle since 09:24, bounced every cv_send after the
  # 11:13 deploy. The last transition this seat recorded is the best knowledge
  # there is; any row it mirrors corrects it, and readiness stays unknown, so a
  # seat's inbox hint still may.
  defp restore_idle(state) do
    case Sessions.list_events(state.session_id, kind: "idle_transition", limit: 1) do
      [%{to_state: "idle"}] -> %{state | idle: true}
      _ -> state
    end
  end

  @impl true
  def handle_call({:register_sidecar, channel_pid}, _from, state) do
    # If there's an existing sidecar, demonitor it
    if state.sidecar_monitor_ref, do: Process.demonitor(state.sidecar_monitor_ref, [:flush])

    ref = Process.monitor(channel_pid)

    # 🔴 PERSIST running, DO NOT ONLY SET IT IN MEMORY. The :DOWN handler WRITES
    # :stopped to the database, while this only updated GenServer state — so a
    # seat that lost its WebSocket was recorded as stopped and never recorded as
    # back. Nothing rewrote the row, because the sidecar reconnects its socket
    # without re-POSTing the session.
    #
    # MEASURED: nintendogs (pid 62186), tiny-wings (61820) and item-store
    # (58061) were all ALIVE while their sessions read "stopped", and the
    # default /api/sessions view filters to running — so three working seats had
    # vanished from the dashboard entirely. Every network change and every
    # server deploy today would have done this fleet-wide.
    #
    # A channel join is the moment we actually know the seat is back, so it is
    # the right place to say so.
    restore_running(state.session_id)
    state = %{state | sidecar_channel_pid: channel_pid, sidecar_monitor_ref: ref, status: :running, sidecar_gone: nil}

    # The seat's inbox poll may have arrived before this Room existed.
    {:reply, :ok, apply_inbox_hint(state, recorded_inbox_event(state))}
  end


  def handle_call({:take_permission_decision, request_id}, _from, state) do
    case Map.get(state.pending_permissions, request_id) do
      %{"decided" => behavior} -> {:reply, {:decided, behavior}, %{state | pending_permissions: Map.delete(state.pending_permissions, request_id)}}
      nil -> {:reply, :gone, state}
      _ -> {:reply, :pending, state}
    end
  end

  def handle_call(:get_replay_buffer, _from, state) do
    {:reply, Enum.reverse(state.message_buffer), state}
  end

  def handle_call({:answer_sync, kind, payload}, _from, state) do
    message = if kind == :answer, do: {:question_answer, payload}, else: {:question_decline, payload}
    event = if kind == :answer, do: "remote_answer", else: "remote_decline"

    where =
      case question_delivery(state, message) do
        :no_link when is_pid(state.sidecar_channel_pid) ->
          forward_to_sidecar(state, event, payload)
          :sidecar

        :no_link ->
          :not_waiting

        other ->
          other
      end

    {:reply, where, state}
  end

  def handle_call(:get_pending_permissions, _from, state) do
    pending = for {_rid, message} <- state.pending_permissions, not Map.has_key?(message, "decided"), do: permission_request(message)
    {:reply, pending, state}
  end

  def handle_call(:get_agent_replay, _from, state) do
    {:reply,
     %{messages: Enum.reverse(state.agent_buffer), agents: state.agents, busy_agents: busy_agents(state.agents),
       background_tasks: state.background_tasks}, state}
  end

  def handle_call(:ended_by_machine, _from, state) do
    Logger.info("Session #{state.session_id} closed by its machine")
    {:reply, :ok, end_now(state, 0)}
  end

  def handle_call(:get_status, _from, state) do
    {:reply,
     # "connected" for every consumer (dashboard, cv_status, the app): a
     # sidecar, or — for a seat with no runtime — a live inbox poll.
     %{status: state.status, sidecar_connected: state.sidecar_channel_pid != nil or state.inbox_live,
       # A socket of its own. inbox_live is not: it counts any poll under the
       # seat's TITLE, so a stale row sharing it reads live (ZombieSweep).
       has_sidecar: state.sidecar_channel_pid != nil,
       idle: state.idle,
       busy_agents: busy_agents(state.agents),
       background_running: background_running(state.background_tasks),
       # false: nothing has said yet whether the seat is idle, so idle false
       # is no news of a turn.
       readiness_known: state.readiness_known,
       permission_mode: state.permission_mode},
     state}
  end

  # Reject-busy: deliver only if the agent is idle; else bounce with a hint of
  # what it's doing so the caller can hold + re-decide on its next idle.
  # A seat with an MCP channel open gets the prompt down the channel (no patch
  # in its binary); any other seat through its sidecar, as before. Reject-busy
  # applies to both: channel text arriving mid-turn is treated as untrusted by
  # the model (measured), so idle-only delivery is required, not a courtesy.
  def handle_call({:send_message, content}, _from, state) do
    if state.idle do
      deliver_prompt(state, content)
      {:reply, :delivered, %{state | idle: false, readiness_known: true}}
    else
      {:reply, {:busy, busy_hint(state)}, state}
    end
  end

  def handle_call({:set_permission_mode, _mode}, _from, %{sidecar_channel_pid: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:set_permission_mode, mode}, from, state) do
    request_id = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    forward_to_sidecar(state, "remote_set_mode", %{"request_id" => request_id, "mode" => mode})
    Process.send_after(self(), {:mode_timeout, request_id}, mode_reply_ms())
    {:noreply, %{state | pending_modes: Map.put(state.pending_modes, request_id, from)}}
  end

  def handle_call({:force_message, content}, _from, state) do
    deliver_prompt(state, content)

    {:reply, :delivered, %{state | idle: false, readiness_known: true}}
  end


  # ⛔ THE SERVER DOES NOT RECORD THE OPERATOR'S TURN, deliberately.
  #
  # It briefly did, to repair remote input being echoed as an `assistant`
  # message. But that only ever covered input the server itself forwarded —
  # and MEASURED with a TUI probe, a prompt TYPED IN THE TERMINAL never reaches
  # the server at all: Claude Code's own Remote Control showed it while none of
  # the 180 mirrored messages contained it.
  #
  # The client now reports every prompt from PromptSubmitController.submit, the
  # one funnel both paths share (patch-ref 003 + SidecarClient.noteUserPrompt).
  # Recording here as well would write remote prompts TWICE — once from the
  # client, once from here — so the single client-side hook is the whole fix.

  # --- Observer actions → forwarded to sidecar ---

  @impl true
  def handle_cast({:send_raw, data}, state) do
    forward_to_sidecar(state, "remote_raw", %{"data" => data})
    {:noreply, state}
  end

  def handle_cast({:inject, content}, state) do
    forward_to_sidecar(state, "remote_input", %{"content" => content})
    {:noreply, %{state | idle: false}}
  end

  def handle_cast({:permission_mode_result, %{"request_id" => rid} = p}, state) do
    case Map.pop(state.pending_modes, rid) do
      {nil, _} ->
        {:noreply, state}

      {from, rest} ->
        state = %{state | pending_modes: rest}

        if p["ok"] == true and is_binary(p["mode"]) do
          GenServer.reply(from, {:ok, p["mode"]})
          {:noreply, %{state | permission_mode: p["mode"]}}
        else
          GenServer.reply(from, {:refused, p["error"] || "refused", p["code"]})
          {:noreply, state}
        end
    end
  end

  def handle_cast({:permission_mode_result, _}, state), do: {:noreply, state}

  def handle_cast({:report_permission_mode, mode}, state) when is_binary(mode) do
    {:noreply, %{state | permission_mode: mode}}
  end

  def handle_cast({:report_permission_mode, _}, state), do: {:noreply, state}

  def handle_cast({:inbox_hint, event}, state), do: {:noreply, apply_inbox_hint(state, event)}

  def handle_cast({:inbox_poll, event}, state) do
    {:noreply, apply_inbox_hint(%{state | inbox_live: true, inbox_misses: 0}, event)}
  end

  def handle_cast(:anthropic_auth_upgrade, state) do
    forward_to_sidecar(state, "anthropic_auth_upgrade", %{})
    {:noreply, state}
  end

  def handle_cast({:set_title, title}, state) do
    forward_to_sidecar(state, "set_title", %{"title" => title})
    {:noreply, state}
  end

  # An inbox seat is interrupted by its poller pressing Escape in its own
  # pane — and only while busy: Escape at an idle prompt would clear the
  # operator's draft. The sidecar is told as well, as before.
  def handle_cast(:interrupt, state) do
    if not state.idle and interrupt_inbox(state) == :no_link, do: interrupt_via_host(state)
    forward_to_sidecar(state, "remote_interrupt", %{})
    {:noreply, state}
  end

  # A seat whose AskUserQuestion is held by the PreToolUse hook gets the answer
  # through the hook (or, between a polling seat's polls, at its next poll);
  # otherwise the sidecar (patch 007) answers the dialog.
  def handle_cast({:answer, payload}, state) do
    if deliver_question(state, {:question_answer, payload}) == :no_link,
      do: forward_to_sidecar(state, "remote_answer", payload)

    {:noreply, state}
  end

  def handle_cast({:decline, payload}, state) do
    if deliver_question(state, {:question_decline, payload}) == :no_link,
      do: forward_to_sidecar(state, "remote_decline", payload)

    {:noreply, state}
  end

  def handle_cast({:permission_response, request_id, decision}, state) do
    case Map.pop(state.pending_permissions, request_id) do
      {nil, _} ->
        {:noreply, state}

      {request, remaining} ->
        # Relayed by the seat's MCP channel: answer down the channel. The relay
        # only knows allow and deny, so anything else is a deny.
        cond do
          Map.get(request, "channel") ->
            behavior = if decision == "allow", do: "allow", else: "deny"
            deliver_link(state, :channel, SeatLinks.permission(request_id, behavior))

          # Held PermissionRequest hook (HookController): answer it directly.
          # A POLLED one (the claudiverse-seat mod) between two polls has no
          # link: its answer is kept here for the next poll instead of lost.
          Map.get(request, "hook") ->
            behavior = if decision == "allow", do: "allow", else: "deny"

            if SeatLinks.deliver_request(request_id, {:permission_decision, behavior}) == :no_link and Map.get(request, "polled"),
              do: send(self(), {:keep_permission_decision, request_id, request, behavior})

          true ->
            forward_to_sidecar(state, "remote_permission_response", %{
              "request_id" => request_id,
              "decision" => decision
            })
        end

        broadcast(state.session_id, "permission_resolved", %{"request_id" => request_id})
        {:noreply, %{state | pending_permissions: remaining}}
    end
  end

  # A held permission hook ended without a remote answer: answered at the
  # terminal, timed out, or the seat went away. Take it off the panel.
  def handle_cast({:permission_withdrawn, request_id}, state) do
    case Map.pop(state.pending_permissions, request_id) do
      {nil, _} ->
        {:noreply, state}

      {_request, remaining} ->
        broadcast(state.session_id, "permission_resolved", %{"request_id" => request_id})
        {:noreply, %{state | pending_permissions: remaining}}
    end
  end

  # --- Sidecar mirroring ---

  def handle_cast({:mirror_messages, messages}, state) when is_list(messages) do
    state = Enum.reduce(messages, state, &process_mirrored_message/2)
    {:noreply, mirror_is_alive(state)}
  end

  # --- Process monitors ---

  @impl true
  # 🔴 A LOST SOCKET IS NOT AN ENDED SEAT. A sidecar drops its WebSocket on any
  # network change, VPN switch or server swap and reconnects within seconds
  # (MEASURED 2026-10-05: 192 disconnects in 4 h across the fleet; ipsum-admin 5 in
  # one hour, one a second after it raised a request). Stopping the row and
  # broadcasting "session_ended" at once told every viewer a live seat had
  # ended — the desktop app showed "Session ended" on a running ipsum-admin. Wait
  # out a grace period: a sidecar back within it is a blip, and nothing is
  # announced; only one that stays gone ends the session.
  def handle_info({:keep_permission_decision, request_id, request, behavior}, state) do
    kept = Map.put(request, "decided", behavior)
    {:noreply, %{state | pending_permissions: Map.put(state.pending_permissions, request_id, kept)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{sidecar_monitor_ref: ref} = state) do
    Logger.info("Sidecar disconnected for session #{state.session_id}")
    token = make_ref()
    Process.send_after(self(), {:sidecar_gone, token}, sidecar_grace_ms())
    {:noreply, %{state | sidecar_channel_pid: nil, sidecar_monitor_ref: nil, sidecar_gone: token}}
  end

  def handle_info({:sidecar_gone, token}, %{sidecar_gone: token, sidecar_channel_pid: nil} = state) do
    Logger.info("Sidecar gone for #{div(sidecar_grace_ms(), 1000)} s; session #{state.session_id} ended")
    Sessions.update_session(Sessions.get_session!(state.session_id), %{status: :stopped})
    broadcast(state.session_id, "session_ended", %{"exit_code" => 0})
    {:noreply, %{state | status: :stopped, sidecar_gone: nil}}
  end

  # The seat never answered: an old runtime without the 013 hook ignores the
  # event, so silence must end as an error, never as "applied".
  def handle_info({:mode_timeout, rid}, state) do
    case Map.pop(state.pending_modes, rid) do
      {nil, _} -> {:noreply, state}
      {from, rest} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending_modes: rest}}
    end
  end

  # A seat with no sidecar has no socket whose closing says it is gone. Its
  # inbox poll is the heartbeat instead: missing for @inbox_miss_limit checks,
  # the session is stopped exactly as a sidecar disconnect stops one — or the
  # row would read "running" forever (the zombie rows 001 was written for).
  # Rooms with a sidecar, and Rooms that never had an inbox poll, are left alone.
  def handle_info(:liveness, state) do
    Process.send_after(self(), :liveness, liveness_ms())

    cond do
      not state.inbox_live or state.sidecar_channel_pid != nil ->
        {:noreply, state}

      inbox_linked?(state) ->
        {:noreply, %{state | inbox_misses: 0}}

      state.inbox_misses + 1 >= @inbox_miss_limit ->
        Logger.info("Inbox poll gone for session #{state.session_id}; stopping it")
        Sessions.update_session(Sessions.get_session!(state.session_id), %{status: :stopped})
        broadcast(state.session_id, "session_ended", %{"exit_code" => 0})
        {:noreply, %{state | inbox_live: false, inbox_misses: 0, status: :stopped}}

      true ->
        {:noreply, %{state | inbox_misses: state.inbox_misses + 1}}
    end
  end

  # Also a stale {:sidecar_gone, _}: the sidecar came back within its grace.
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal ---

  # A seat that is mirroring is alive, whatever its inbox poll is doing. The
  # poll was the only heartbeat, and it can legitimately pause: a mod seat
  # (before claudiverse-seat 0.8.1) stopped polling for the rest of any turn
  # that had a prompt queued behind it, and was stopped 3 min in while it kept
  # mirroring (MEASURED 2026-10-06, unifi-basement-ap: 120 mirror frames after
  # "Inbox poll gone"). Only a live inbox seat is reset: a seat that ended has
  # inbox_live false, and its last frames must not keep it running.
  defp mirror_is_alive(%{inbox_live: true} = state), do: %{state | inbox_misses: 0}
  defp mirror_is_alive(state), do: state

  # Bookkeeping: a seat must be able to reconnect even if the row cannot be
  # updated, so this never raises and never fails the join.
  defp restore_running(session_id) do
    session = Sessions.get_session!(session_id)
    if session.status != :running, do: Sessions.update_session(session, %{status: :running})
    :ok
  rescue
    e ->
      Logger.warning("[room] could not restore running status: #{Exception.message(e)}")
      :ok
  end


  # The model the seat is ACTUALLY running, taken from the assistant messages it
  # already mirrors.
  #
  # 🔴 THE STORED MODEL WAS A LIE. The client never sends one, so every session
  # carried the create-time default "sonnet" — displayed in the panel for seats
  # demonstrably running Opus (confirmed side by side against a terminal reading
  # "Opus 5 (1M context)"). A wrong value dressed as a real one is worse than an
  # absent one, and it had been wrong on every row.
  #
  # No client change was needed: every assistant message carries message.model,
  # measured as "claude-opus-5" throughout a live session. Reading what is
  # already arriving beats adding a field the client has to remember to send.
  #
  # Written only on CHANGE — this runs on every mirrored message, and a write per
  # message would be thousands of pointless updates per session.
  defp note_model(state, message) do
    with model when is_binary(model) and model != "" <- get_in(message, ["message", "model"]),
         session = Sessions.get_session!(state.session_id),
         true <- session.model != model do
      Sessions.update_session(session, %{model: model})
    end

    :ok
  rescue
    # Bookkeeping hanging off the mirror path: it must never cost a message.
    _ -> :ok
  end

  # cvstate heartbeat (patch 010): a lightweight ~3s reachability + task
  # snapshot. NOT persisted as a conversation message (would flood the table /
  # replay buffer) — it only reconciles the idle flag (self-heals a missed idle
  # frame) and logs idle/task-set changes to cv_events with full task detail.
  # End the session now: row stopped (crashed for a non-zero code), viewers told.
  defp end_now(state, code) do
    Sessions.update_session(Sessions.get_session!(state.session_id), %{status: if(code == 0, do: :stopped, else: :crashed)})
    broadcast(state.session_id, "session_ended", %{"exit_code" => code})
    %{state | status: :stopped, sidecar_gone: nil, inbox_live: false, inbox_misses: 0}
  end

  defp process_mirrored_message(%{"type" => "cvstate"} = message, state) do
    reported_idle = Map.get(message, "idle", false) == true
    tasks = Map.get(message, "tasks", [])

    %{state | readiness_known: true}
    |> reconcile_idle(reported_idle, tasks)
    |> log_task_change(tasks)
  end

  # The seat says it is exiting (the mod's session.end: /exit, ctrl+c): the
  # mirror's counterpart of a sidecar's "session_ended". Without it a seat
  # with no socket reads "running" until the liveness check gives up on it
  # (~3 min) — MEASURED 2026-10-05: switching Failover from the mod back to
  # the patched runtime showed two running "claudiverse-account-failover"
  # seats for those minutes.
  defp process_mirrored_message(%{"type" => "session_ended"} = message, state) do
    code = if is_integer(message["exit_code"]), do: message["exit_code"], else: 0
    Logger.info("Session #{state.session_id} ended by its seat (#{message["reason"] || "exit"})")
    end_now(state, code)
  end

  # The seat's background work, replaced whole: stored (a restarted Room
  # starts from the newest), sent to viewers, and kept apart from main's
  # replay as agent rows are.
  defp process_mirrored_message(%{"type" => "background_tasks"} = message, state) do
    message = Sessions.stamp_time(message, now_iso())
    Sessions.create_message(%{type: "background_tasks", payload: message, sequence: state.sequence, session_id: state.session_id})
    broadcast(state.session_id, "message", message)
    tasks = if is_list(message["tasks"]), do: message["tasks"], else: []
    %{state | background_tasks: tasks, sequence: state.sequence + 1}
  end

  # An agent's row: stored and sent to viewers, kept in the agent buffer, and
  # nothing else. Main's busy/idle, its pings and its permissions are main's
  # own; a fork finishing a turn says nothing about main.
  defp process_mirrored_message(%{"type" => t} = message, state) when t in @agent_types do
    message = message |> Sessions.stamp_time(now_iso()) |> ClaudiverseServer.SeatFiles.externalize_images(state.session_id)

    Sessions.create_message(%{type: t, payload: message, sequence: state.sequence, session_id: state.session_id})
    broadcast(state.session_id, "message", message)

    agents = if t == "agents" and is_list(message["agents"]), do: message["agents"], else: state.agents
    %{state | agent_buffer: Enum.take([message | state.agent_buffer], @max_agent_buffer), agents: agents, sequence: state.sequence + 1}
  end

  defp process_mirrored_message(message, state) when is_map(message) do
    msg_type = Map.get(message, "type", "unknown")

    # Pictures go to the file store; the row, the replay and viewers get a
    # reference (SeatFiles.externalize_images/2). Stream fragments carry none.
    message = if msg_type == "stream_event", do: message, else: ClaudiverseServer.SeatFiles.externalize_images(message, state.session_id)

    # A stored row with no time of its own (the mod's) gets the time it
    # arrived (Sessions.stamp_time/2), or the apps show no message times.
    message = if msg_type in @live_only, do: message, else: Sessions.stamp_time(message, now_iso())

    note_model(state, message)

    # Persist to DB — except what is only meaningful live (@live_only).
    unless msg_type in @live_only do
      Sessions.create_message(%{
        type: msg_type,
        payload: message,
        sequence: state.sequence,
        session_id: state.session_id
      })
    end

    # Buffer for replay (newest first, reversed on read). Live-only frames are
    # not buffered either: stream fragments filled the 500-slot buffer, so a
    # viewer opening a seat saw only the last few minutes (noted by the
    # desktop app), and progress frames outnumber real messages 2 to 1.
    buffer =
      if msg_type in @live_only,
        do: state.message_buffer,
        else: [message | state.message_buffer] |> Enum.take(@max_buffer_size)

    # Track permission requests
    state =
      if msg_type == "control_request" do
        request = Map.get(message, "request", %{})

        if Map.get(request, "subtype") == "can_use_tool" do
          request_id = Map.get(message, "request_id")

          broadcast(state.session_id, "permission_request", permission_request(message))

          %{state | pending_permissions: Map.put(state.pending_permissions, request_id, message)}
        else
          state
        end
      else
        state
      end

    # Broadcast to all observers
    broadcast(state.session_id, "message", message)

    # Reactive notifications for orchestrator listeners
    notify_router(state.session_id, msg_type, message)

    # Track idle for reject-busy: idle is true only on the synthetic "idle" frame.
    # Observability: when the flag actually flips, log + persist the transition
    # (which msg_type drove it). ~2 rows per idle cycle; best-effort, off the path.
    new_idle = if msg_type in @readiness_neutral, do: state.idle, else: msg_type == "idle"

    if new_idle != state.idle do
      from = if state.idle, do: "idle", else: "busy"
      to = if new_idle, do: "idle", else: "busy"
      Logger.info("[cvidle] session=#{state.session_id} #{from}->#{to} trigger=#{msg_type}")

      Sessions.record_event(%{
        session_id: state.session_id,
        kind: "idle_transition",
        from_state: from,
        to_state: to,
        trigger: msg_type
      })
    end

    readiness_known = state.readiness_known or msg_type not in @readiness_neutral

    %{state | message_buffer: buffer, sequence: state.sequence + 1, idle: new_idle, readiness_known: readiness_known}
    |> settle_hook_permissions(msg_type, message)
  end

  # What a viewer is told of a permission prompt, live (permission_request)
  # and in a replay (get_pending_permissions/1).
  defp permission_request(message) do
    request = Map.get(message, "request", %{})

    %{
      "request_id" => Map.get(message, "request_id"),
      "tool_name" => Map.get(request, "tool_name"),
      "input" => Map.get(request, "input"),
      "display_name" => Map.get(request, "display_name"),
      "description" => Map.get(request, "description"),
      "title" => Map.get(request, "title"),
      # The agent that asks (a fork, a subagent); absent for main.
      "agent_id" => Map.get(message, "agent_id")
    }
  end

  # A permission prompt held by a hook (HookController) that was settled AT THE
  # TERMINAL. Claude Code keeps the hook's request open after a local answer
  # (measured on 2.1.286: still held four minutes later), so nothing on that
  # connection says the prompt is gone. The mirror does: the tool's result
  # appears in the seat's next request. A tool_result whose tool call matches
  # a held prompt — same tool and input — settles it; a seat going idle
  # settles whatever is left (e.g. Escape at the dialog).
  defp settle_hook_permissions(state, msg_type, message) do
    held = for {rid, %{"hook" => true} = req} <- state.pending_permissions, do: {rid, req}

    settled =
      cond do
        held == [] -> []
        msg_type == "idle" -> Enum.map(held, &elem(&1, 0))
        msg_type == "user" -> held_matching_results(held, message, state.message_buffer)
        true -> []
      end

    Enum.reduce(settled, state, fn rid, state ->
      SeatLinks.deliver_request(rid, :permission_settled)
      broadcast(state.session_id, "permission_resolved", %{"request_id" => rid})
      %{state | pending_permissions: Map.delete(state.pending_permissions, rid)}
    end)
  end

  defp held_matching_results(held, message, buffer) do
    result_ids =
      for %{"type" => "tool_result", "tool_use_id" => id} <- List.wrap(get_in(message, ["message", "content"])),
          do: id

    calls =
      for id <- result_ids,
          %{"type" => "assistant"} = m <- buffer,
          %{"type" => "tool_use", "id" => ^id} = call <- List.wrap(get_in(m, ["message", "content"])),
          do: call

    for {rid, %{"request" => req}} <- held,
        Enum.any?(calls, &(&1["name"] == req["tool_name"] and &1["input"] == req["input"])),
        do: rid
  end

  # Heartbeat carries the live, task-independent readiness. If it disagrees with
  # our (possibly stale) flag, trust the heartbeat: flip + log, and on going idle
  # let the Router flush queued pings. This is what self-heals a missed idle frame.
  defp reconcile_idle(state, reported_idle, tasks) do
    if reported_idle == state.idle do
      state
    else
      from = if state.idle, do: "idle", else: "busy"
      to = if reported_idle, do: "idle", else: "busy"
      Logger.info("[cvstate] session=#{state.session_id} reconcile #{from}->#{to} tasks=#{length(tasks)}")

      Sessions.record_event(%{
        session_id: state.session_id,
        kind: "idle_reconcile",
        from_state: from,
        to_state: to,
        trigger: "cvstate",
        detail: %{"tasks" => tasks}
      })

      if reported_idle, do: Router.went_idle(state.session_id)
      %{state | idle: reported_idle}
    end
  end

  # Log the full task set whenever it changes (a task appears / clears / changes
  # status), so a zombie is visible in cv_events with id/type/desc/age — vs a
  # live foreground auditor (seconds old). Skips the trivial empty baseline.
  defp log_task_change(state, tasks) do
    sig = tasks |> Enum.map(&{Map.get(&1, "id"), Map.get(&1, "status")}) |> Enum.sort()

    cond do
      sig == state.last_task_sig ->
        state

      tasks == [] and state.last_task_sig in [nil, []] ->
        %{state | last_task_sig: sig}

      true ->
        Sessions.record_event(%{
          session_id: state.session_id,
          kind: "tasks",
          trigger: "cvstate",
          detail: %{"tasks" => tasks}
        })

        %{state | last_task_sig: sig}
    end
  end

  defp forward_to_sidecar(%{sidecar_channel_pid: pid}, event, payload) when is_pid(pid) do
    send(pid, {:forward_to_sidecar, event, payload})
  end

  defp forward_to_sidecar(_, _, _), do: :ok

  # Links are keyed by the seat's title, read fresh: a seat can be renamed.
  defp deliver_link(%{owner_id: owner} = state, kind, message) when is_integer(owner) do
    case Sessions.get_session(state.session_id) do
      %{title: title} when is_binary(title) -> SeatLinks.deliver(kind, owner, title, message)
      _ -> :no_link
    end
  end

  defp deliver_link(_state, _kind, _message), do: :no_link

  defp deliver_question(state, message) do
    if question_delivery(state, message) == :no_link, do: :no_link, else: :ok
  end

  # :delivered | :queued | :no_link, as QuestionHolds.deliver/3 says (:ok is a
  # waiting poll taking it).
  # Agents still working: pending or running. "waiting" is a teammate idle
  # until a message, "idle" a finished turn.
  defp busy_agents(agents) when is_list(agents),
    do: Enum.count(agents, &(is_map(&1) and &1["status"] in ["pending", "running"]))

  defp busy_agents(_), do: 0

  defp background_running(tasks) when is_list(tasks),
    do: Enum.count(tasks, &(is_map(&1) and &1["status"] in ["pending", "running"]))

  defp background_running(_), do: 0

  defp question_delivery(%{owner_id: owner} = state, message) when is_integer(owner) do
    case Sessions.get_session(state.session_id) do
      %{title: title} when is_binary(title) ->
        case QuestionHolds.deliver(owner, title, message) do
          :ok -> :delivered
          other -> other
        end

      _ ->
        :no_link
    end
  end

  defp question_delivery(_state, _message), do: :no_link

  # A prompt goes to the seat's MCP channel, else its inbox hook, else its
  # sidecar (003). A seat that never opened a channel or polled an inbox —
  # every patched fleet seat — takes the sidecar path exactly as before.
  defp deliver_prompt(state, content) do
    with :no_link <- deliver_link(state, :channel, SeatLinks.prompt(content)),
         :not_inbox <- deliver_inbox(state, content) do
      forward_to_sidecar(state, "remote_input", %{"content" => content})
    end
  end

  # 🔴 AN INBOX MARK MUST NOT OUTLIVE ITS POLLER. One poll made a title an inbox
  # seat for good, so every later prompt was queued for that poller. MEASURED
  # 2026-10-05: a one-shot test run registered under Failover's title through the
  # claudiverse-seat mod and polled once; for the next 15 minutes, 8 messages to
  # Failover (two of them swap approvals) were queued for a poller that no longer
  # existed, while Failover's live sidecar got none. A seat with a live sidecar,
  # no waiting poller and no poll for @inbox_stale_ms is a sidecar seat again:
  # what was queued and this prompt go down the sidecar. A seat with no sidecar
  # keeps queueing, as before (its poller is the only way in).
  defp deliver_inbox(%{owner_id: owner} = state, content) when is_integer(owner) do
    case Sessions.get_session(state.session_id) do
      %{title: title} when is_binary(title) ->
        if stale_inbox?(state, owner, title) do
          Logger.info("[inbox] session=#{state.session_id} #{title}: no poll for #{inbox_stale_ms()} ms; back to the sidecar")
          for earlier <- ClaudiverseServer.SeatInbox.forget(owner, title),
              do: forward_to_sidecar(state, "remote_input", %{"content" => earlier})

          :not_inbox
        else
          ClaudiverseServer.SeatInbox.deliver(owner, title, content)
        end

      _ ->
        :not_inbox
    end
  end

  defp deliver_inbox(_state, _content), do: :not_inbox

  defp stale_inbox?(state, owner, title) do
    state.sidecar_channel_pid != nil and not SeatLinks.linked?(:inbox, owner, title) and
      case ClaudiverseServer.SeatInbox.last_poll_age_ms(owner, title) do
        nil -> false
        age -> age > inbox_stale_ms()
      end
  end

  defp inbox_stale_ms, do: Application.get_env(:claudiverse_server, :inbox_stale_ms, 120_000)

  defp interrupt_inbox(%{owner_id: owner} = state) when is_integer(owner) do
    case Sessions.get_session(state.session_id) do
      %{title: title} when is_binary(title) -> ClaudiverseServer.SeatInbox.interrupt(owner, title)
      _ -> :no_link
    end
  end

  defp interrupt_inbox(_state), do: :no_link

  # 🔴 NO SIDECAR HANDLES "remote_interrupt": the patched binary's SidecarClient
  # has no handler and no abort hook, so for every patched-binary seat the
  # forward above has always been a no-op (measured by the app on 204038: the
  # turn ran on; Esc in the pane stopped it at once). A seat without a live
  # inbox poller is therefore interrupted by its machine's host agent, which
  # presses Escape in the seat's tmux session — that also dismisses a pending
  # permission prompt. ONE Escape per interrupt, by one route: a second quick
  # Escape opens Claude Code's rewind menu. Async: the Room never waits on a
  # machine.
  defp interrupt_via_host(%{owner_id: owner} = state) when is_integer(owner) do
    case Sessions.get_session(state.session_id) do
      %{host: host, title: title} when is_binary(host) and is_binary(title) ->
        sid = state.session_id

        Task.start(fn ->
          result = ClaudiverseServer.Hosts.request(owner, host, "interrupt", %{"title" => title})
          Logger.info("[interrupt] session=#{sid} via host #{host}: #{inspect(result)}")
        end)

      _ ->
        :no_host
    end
  end

  defp interrupt_via_host(_state), do: :no_host

  defp inbox_linked?(%{owner_id: owner} = state) when is_integer(owner) do
    case Sessions.get_session(state.session_id) do
      %{title: title} when is_binary(title) -> SeatLinks.linked?(:inbox, owner, title)
      _ -> false
    end
  end

  defp inbox_linked?(_state), do: false

  defp recorded_inbox_event(%{owner_id: owner} = state) when is_integer(owner) do
    case Sessions.get_session(state.session_id) do
      %{title: title} when is_binary(title) -> ClaudiverseServer.SeatInbox.last_event(owner, title)
      _ -> nil
    end
  end

  defp recorded_inbox_event(_state), do: nil

  defp apply_inbox_hint(%{readiness_known: true} = state, _event), do: state

  defp apply_inbox_hint(state, event) when event in ["SessionStart", "Stop", "Notification", "UserPromptSubmit"] do
    idle = event != "UserPromptSubmit"
    Logger.info("[cvidle] session=#{state.session_id} readiness from inbox hint #{event} -> #{if idle, do: "idle", else: "busy"}")

    Sessions.record_event(%{
      session_id: state.session_id,
      kind: "idle_transition",
      from_state: "unknown",
      to_state: if(idle, do: "idle", else: "busy"),
      trigger: "inbox_hint:" <> event
    })

    if idle, do: Router.went_idle(state.session_id)
    %{state | idle: idle, readiness_known: true}
  end

  defp apply_inbox_hint(state, _event), do: state

  # Short hint of what the agent is doing, for a reject-busy reply.
  defp busy_hint(state) do
    Enum.find_value(state.message_buffer, "in progress", fn msg ->
      with "assistant" <- Map.get(msg, "type"),
           content when is_list(content) <- get_in(msg, ["message", "content"]),
           %{"text" => t} when is_binary(t) <-
             Enum.find(content, &(is_map(&1) and &1["type"] == "text")) do
        s = String.trim(t)
        if s == "", do: false, else: String.slice(s, 0, 120)
      else
        _ -> false
      end
    end)
  end

  defp broadcast(session_id, event, payload) do
    Phoenix.PubSub.broadcast(
      ClaudiverseServer.PubSub,
      "session:#{session_id}",
      {event, payload}
    )
  end

  # Tap detected events to the notification Router. "idle" (emitted by patch 008
  # when the agent is TRULY at rest — no query/background-agent/queued-message) is
  # both an event (for sessions watching this one) and the at-rest signal (if this
  # session is itself a listener). turn_complete is deliberately NOT used here: it
  # fires while background agents/queued work are still in flight, so driving
  # readiness off it sends events into busy workers. An assistant message may
  # carry an AskUserQuestion.
  defp notify_router(session_id, "idle", _message) do
    Router.event(session_id, "idle")
    Router.went_idle(session_id)
  end

  defp notify_router(session_id, "assistant", message) do
    case ask_user_question_id(message) do
      nil -> :ok
      tid -> Router.event(session_id, "ask_user_question", %{tool_use_id: tid})
    end
  end

  # Compaction dropped earlier context (its standing charter/current task) —
  # tell watchers so they can re-brief. Does NOT touch idle (compaction is
  # mid-turn; the worker is busy).
  defp notify_router(session_id, "compact", _message) do
    Router.event(session_id, "compact")
  end

  defp notify_router(_session_id, _type, _message), do: :ok

  defp ask_user_question_id(message) do
    content = get_in(message, ["message", "content"])

    if is_list(content) do
      Enum.find_value(content, fn block ->
        if is_map(block) and block["type"] == "tool_use" and block["name"] == "AskUserQuestion",
          do: block["id"],
          else: nil
      end)
    end
  end
end
