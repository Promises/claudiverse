defmodule ClaudiverseServer.Sessions.RoomBackgroundTest do
  @moduledoc """
  A seat's background work (claudiverse-seat 0.10.0's background_tasks rows):
  the latest list replaces the last, stays out of main's replay, is counted in
  the Room's status, and survives a Room restart.
  """
  use ClaudiverseServer.DataCase

  alias ClaudiverseServer.Sessions
  alias ClaudiverseServer.Sessions.Room
  import ClaudiverseServer.Fixtures

  setup do
    user = user_fixture()
    session = session_fixture(user)
    stop_room(session.id)
    {:ok, _} = ClaudiverseServer.Sessions.Supervisor.start_room(session.id, owner_id: user.id)
    on_exit(fn -> stop_room(session.id) end)
    %{user: user, session: session}
  end

  defp stop_room(id) do
    case Registry.lookup(ClaudiverseServer.Sessions.Registry, id) do
      [{pid, _}] -> ClaudiverseServer.Sessions.Supervisor.stop_room(pid)
      [] -> :ok
    end
  end

  defp shell(id, status), do: %{"id" => id, "type" => "shell", "status" => status, "command" => "ssh m1 run-tests", "description" => "LAN tests"}

  defp report(session, tasks) do
    Room.mirror_messages(session.id, [%{"type" => "background_tasks", "tasks" => tasks}])
    Room.get_status(session.id)
  end

  test "the latest list replaces the last, is counted, and stays out of main's replay", %{session: session} do
    report(session, [shell("b1", "running"), shell("b2", "running")])
    assert Room.get_status(session.id).background_running == 2

    status = report(session, [shell("b2", "running"), %{"id" => "m1", "type" => "monitor", "status" => "completed"}])
    assert status.background_running == 1
    assert Enum.map(Room.get_agent_replay(session.id).background_tasks, & &1["id"]) == ["b2", "m1"]

    assert Room.get_replay_buffer(session.id) == []
    assert Sessions.recent_payloads(session.id, 10) == []
  end

  test "a Room that starts again reports the stored list", %{user: user, session: session} do
    report(session, [shell("b1", "running")])
    stop_room(session.id)
    {:ok, _} = ClaudiverseServer.Sessions.Supervisor.start_room(session.id, owner_id: user.id)

    assert [%{"id" => "b1"}] = Room.get_agent_replay(session.id).background_tasks
    assert Room.get_status(session.id).background_running == 1
  end

  test "a seat that never reported has none", %{session: session} do
    assert Room.get_agent_replay(session.id).background_tasks == []
    assert Room.get_status(session.id).background_running == 0
  end
end
