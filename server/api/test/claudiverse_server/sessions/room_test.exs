defmodule ClaudiverseServer.Sessions.RoomTest do
  use ClaudiverseServer.DataCase

  alias ClaudiverseServer.Sessions.Room
  import ClaudiverseServer.Fixtures

  setup do
    user = user_fixture()
    session = session_fixture(user)

    # Stop any leftover room from a previous test
    case Registry.lookup(ClaudiverseServer.Sessions.Registry, session.id) do
      [{pid, _}] -> ClaudiverseServer.Sessions.Supervisor.stop_room(pid)
      [] -> :ok
    end

    {:ok, pid} = ClaudiverseServer.Sessions.Supervisor.start_room(session.id, owner_id: user.id)

    on_exit(fn ->
      if Process.alive?(pid), do: ClaudiverseServer.Sessions.Supervisor.stop_room(pid)
    end)

    %{user: user, session: session}
  end

  test "room starts and reports status", %{session: session} do
    status = Room.get_status(session.id)
    assert status.status == :running
    assert status.sidecar_connected == false
  end

  test "a Room started after a restart restores the seat's last recorded readiness", %{user: user} do
    # Rooms outlive their test unless stopped, and session ids repeat across
    # sandboxed tests: a leaked Room replayed these rows into another test.
    started = fn session ->
      {:ok, pid} = ClaudiverseServer.Sessions.Supervisor.start_room(session.id, owner_id: user.id)
      on_exit(fn -> if Process.alive?(pid), do: ClaudiverseServer.Sessions.Supervisor.stop_room(pid) end)
    end

    restart = fn session ->
      [{pid, _}] = Registry.lookup(ClaudiverseServer.Sessions.Registry, session.id)
      ClaudiverseServer.Sessions.Supervisor.stop_room(pid)
      started.(session)
      Room.get_status(session.id).idle
    end

    idle = session_fixture(user)
    started.(idle)
    Room.mirror_messages(idle.id, [%{"type" => "assistant", "message" => %{"content" => []}}])
    Room.mirror_messages(idle.id, [%{"type" => "idle"}])
    assert Room.get_status(idle.id).idle
    assert restart.(idle), "an idle seat must not read busy after a restart"

    busy = session_fixture(user)
    started.(busy)
    Room.mirror_messages(busy.id, [%{"type" => "idle"}])
    Room.mirror_messages(busy.id, [%{"type" => "assistant", "message" => %{"content" => []}}])
    refute restart.(busy), "a seat last seen busy stays busy"
  end

  test "sidecar registration", %{session: session} do
    assert :ok = Room.register_sidecar(session.id, self())
    status = Room.get_status(session.id)
    assert status.sidecar_connected == true
  end

  test "mirror_messages stores and broadcasts", %{session: session} do
    # Subscribe to PubSub
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, "session:#{session.id}")

    messages = [
      %{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => "Hello"}]}, "uuid" => "abc", "session_id" => "s1"}
    ]

    Room.mirror_messages(session.id, messages)

    assert_receive {"message", %{"type" => "assistant"}}, 1000

    # Check replay buffer
    buffer = Room.get_replay_buffer(session.id)
    assert length(buffer) == 1
    assert hd(buffer)["type"] == "assistant"
  end

  test "permission request tracking", %{session: session} do
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, "session:#{session.id}")

    messages = [
      %{
        "type" => "control_request",
        "request_id" => "perm-1",
        "request" => %{
          "subtype" => "can_use_tool",
          "tool_name" => "BashTool",
          "input" => %{"command" => "ls"},
          "tool_use_id" => "tu-1"
        }
      }
    ]

    Room.mirror_messages(session.id, messages)

    assert_receive {"permission_request", %{"request_id" => "perm-1", "tool_name" => "BashTool"}}, 1000
  end

  test "permission response forwards to sidecar", %{session: session} do
    # Register self as sidecar
    Room.register_sidecar(session.id, self())

    # Mirror a permission request
    Room.mirror_messages(session.id, [
      %{
        "type" => "control_request",
        "request_id" => "perm-2",
        "request" => %{"subtype" => "can_use_tool", "tool_name" => "BashTool", "input" => %{}, "tool_use_id" => "tu-2"}
      }
    ])

    # Respond to permission
    Room.send_permission_response(session.id, "perm-2", "allow")

    assert_receive {:forward_to_sidecar, "remote_permission_response", %{"request_id" => "perm-2", "decision" => "allow"}}, 1000
  end

  test "send_message forwards to sidecar", %{session: session} do
    Room.register_sidecar(session.id, self())
    Room.send_message(session.id, "Hello from observer")

    assert_receive {:forward_to_sidecar, "remote_input", %{"content" => "Hello from observer"}}, 1000
  end

  test "interrupt forwards to sidecar", %{session: session} do
    Room.register_sidecar(session.id, self())
    Room.interrupt(session.id)

    assert_receive {:forward_to_sidecar, "remote_interrupt", %{}}, 1000
  end

  test "sidecar disconnect updates status", %{session: session} do
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, "session:#{session.id}")

    # Spawn a process to act as sidecar, then kill it
    pid = spawn(fn -> Process.sleep(:infinity) end)
    Room.register_sidecar(session.id, pid)

    assert Room.get_status(session.id).sidecar_connected == true

    Process.exit(pid, :kill)

    assert_receive {"session_ended", %{"exit_code" => 0}}, 1000

    status = Room.get_status(session.id)
    assert status.sidecar_connected == false
    assert status.status == :stopped
  end
end
