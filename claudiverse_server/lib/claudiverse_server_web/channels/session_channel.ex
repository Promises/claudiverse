defmodule ClaudiverseServerWeb.SessionChannel do
  use Phoenix.Channel

  alias ClaudiverseServer.Sessions
  alias ClaudiverseServer.Sessions.Room
  alias ClaudiverseServer.Sessions.Supervisor, as: SessionSupervisor

  @impl true
  def join("session:" <> session_id_str, params, socket) do
    if ClaudiverseServerWeb.UserSocket.host_token?(socket),
      do: {:error, %{reason: "host tokens cannot join seats"}},
      else: join_seat(session_id_str, params, socket)
  end

  defp join_seat(session_id_str, params, socket) do
    session_id = String.to_integer(session_id_str)
    user = socket.assigns.current_user
    role = Map.get(params, "role", "observer")

    case Sessions.get_user_session(user.id, session_id) do
      nil ->
        {:error, %{reason: "not_found"}}

      session ->
        socket =
          socket
          |> assign(:session_id, session.id)
          |> assign(:role, role)

        if role == "sidecar" do
          # A seat whose row never got its machine is placed by its address.
          ClaudiverseServer.Hosts.place(user.id, session, socket.assigns[:peer_ip])

          # Ensure the Room exists (it may not after a server restart, or if the
          # sidecar reconnects without re-creating the session) before registering.
          SessionSupervisor.start_room(session.id, owner_id: user.id)
          Room.register_sidecar(session.id, self())
          ClaudiverseServer.Notifications.Router.seat_seen(session.title, session.id)
        end

        # The Room broadcasts on "session:<id>". Phoenix already subscribes a
        # channel to its own topic, so subscribing again delivered EVERY
        # broadcast twice — streamed text arrived doubled ("**The**The Bre
        # Breathing…", measured by the app on 204038). Only a join under a
        # non-canonical id ("session:0204038") needs the Room's topic added.
        room_topic = "session:#{session.id}"
        if socket.topic != room_topic, do: Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, room_topic)

        # Send replay after join completes
        send(self(), :send_replay)

        {:ok, socket}
    end
  end

  # --- Sidecar events (from Claude CLI) ---

  @impl true
  def handle_in("mirror_messages", %{"messages" => messages}, %{assigns: %{role: "sidecar"}} = socket) do
    Room.mirror_messages(socket.assigns.session_id, messages)
    {:noreply, socket}
  end

  def handle_in("permission_mode_result", payload, %{assigns: %{role: "sidecar"}} = socket) do
    Room.permission_mode_result(socket.assigns.session_id, payload)
    {:noreply, socket}
  end

  def handle_in("permission_mode", %{"mode" => mode}, %{assigns: %{role: "sidecar"}} = socket) do
    Room.report_permission_mode(socket.assigns.session_id, mode)
    {:noreply, socket}
  end

  def handle_in("mirror_pty", %{"data" => data}, %{assigns: %{role: "sidecar"}} = socket) do
    Phoenix.PubSub.broadcast(
      ClaudiverseServer.PubSub,
      "session:#{socket.assigns.session_id}",
      {"pty_output", %{"data" => data}}
    )

    {:noreply, socket}
  end

  def handle_in("session_ended", %{"exit_code" => code}, %{assigns: %{role: "sidecar"}} = socket) do
    Sessions.update_session(
      Sessions.get_session!(socket.assigns.session_id),
      %{status: if(code == 0, do: :stopped, else: :crashed)}
    )

    Phoenix.PubSub.broadcast(
      ClaudiverseServer.PubSub,
      "session:#{socket.assigns.session_id}",
      {"session_ended", %{"exit_code" => code}}
    )

    {:noreply, socket}
  end

  # --- Observer events (from React/Expo clients) ---

  def handle_in("send_message", %{"content" => content}, %{assigns: %{role: "observer"}} = socket) do
    {:reply, {:ok, send_result(Room.send_message(socket.assigns.session_id, content))}, socket}
  end

  # Raw keystrokes into a patched seat's terminal can answer any dialog or run
  # a shell command there, so like an allow they are the operator's apps' alone.
  # No client sends them today (2026-10-07: the web panel and the apps don't).
  def handle_in("send_raw", %{"data" => data}, %{assigns: %{role: "observer"}} = socket) do
    if ClaudiverseServer.Accounts.app_powers?(socket.assigns[:token_context]) do
      Room.send_raw(socket.assigns.session_id, data)
      {:reply, :ok, socket}
    else
      {:reply, {:error, %{reason: "only the operator's app may send keystrokes to a seat"}}, socket}
    end
  end

  # An ALLOW runs a tool on the seat's machine: an execution grant, accepted
  # only from the operator's apps (an app or super token). A seat's or a
  # runner's token (api) may watch, and may deny, never allow (lorem-admin,
  # 2026-10-07, when the apps began answering mod seats' prompts). The answer
  # names its prompt's request id, a random id the Room takes once, so a
  # stale or replayed one finds nothing.
  def handle_in("permission_response", %{"request_id" => rid, "decision" => "allow"}, %{assigns: %{role: "observer"}} = socket) do
    if ClaudiverseServer.Accounts.app_powers?(socket.assigns[:token_context]) do
      Room.send_permission_response(socket.assigns.session_id, rid, "allow")
      {:reply, :ok, socket}
    else
      {:reply, {:error, %{reason: "only the operator's app may allow a permission prompt"}}, socket}
    end
  end

  def handle_in("permission_response", %{"request_id" => rid, "decision" => decision}, %{assigns: %{role: "observer"}} = socket) do
    Room.send_permission_response(socket.assigns.session_id, rid, decision)
    {:reply, :ok, socket}
  end

  def handle_in("interrupt", _params, %{assigns: %{role: "observer"}} = socket) do
    Room.interrupt(socket.assigns.session_id)
    {:noreply, socket}
  end

  # The reply says where the answer went, so a sender is never told
  # "answered" when nothing was waiting for it (Room.answer_sync/3).
  def handle_in(event, payload, %{assigns: %{role: "observer"}} = socket) when event in ["answer", "decline"] do
    case Room.answer_sync(socket.assigns.session_id, String.to_existing_atom(event), payload) do
      :not_waiting ->
        {:reply, {:error, %{status: "not_waiting",
                            reason: "the seat is not waiting for a remote answer (no question poll, no hold, no sidecar); answer it at its terminal"}}, socket}

      where ->
        {:reply, {:ok, %{status: to_string(where)}}, socket}
    end
  end

  # Catch-all for wrong role
  def handle_in(_event, _params, socket) do
    {:noreply, socket}
  end

  defp send_result(:delivered), do: %{status: "delivered"}
  defp send_result({:busy, hint}), do: %{status: "busy", hint: hint}
  defp send_result({:error, _}), do: %{status: "error", error: "not connected"}

  # --- Replay after join ---

  @impl true
  # A resumed seat's row starts with an empty buffer, so its earlier rows'
  # messages come first; `earlier_count` says how many, so a viewer can mark
  # where the resume began.
  def handle_info(:send_replay, socket) do
    earlier = ClaudiverseServer.Sessions.earlier_conversation(socket.assigns.session_id)
    replay = earlier ++ Room.get_replay_buffer(socket.assigns.session_id)
    # Agents (forks, background subagents, teammates) replay apart from main:
    # `messages` stays main's alone, as every older client reads it.
    agent = Room.get_agent_replay(socket.assigns.session_id)

    push(socket, "replay", %{
      "messages" => replay,
      "earlier_count" => length(earlier),
      "agent_messages" => agent.messages,
      "agents" => agent.agents,
      "busy_agents" => agent.busy_agents,
      # Shells, monitors, subagents and workflows in flight (claudiverse-seat 0.10.0).
      "background_tasks" => agent.background_tasks,
      # Prompts asked before this viewer joined, so it can still answer them.
      "pending_permissions" => Room.get_pending_permissions(socket.assigns.session_id)
    })
    {:noreply, socket}
  end

  # --- PubSub messages (broadcast from Room) ---

  def handle_info({event, payload}, socket) when is_binary(event) do
    # Don't echo mirrored messages back to the sidecar that sent them
    unless socket.assigns.role == "sidecar" and event == "message" do
      push(socket, event, payload)
    end

    {:noreply, socket}
  end

  # Forward events to sidecar (from Room GenServer)
  def handle_info({:forward_to_sidecar, event, payload}, %{assigns: %{role: "sidecar"}} = socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end
end
