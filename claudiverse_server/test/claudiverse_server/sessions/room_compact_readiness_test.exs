defmodule ClaudiverseServer.Sessions.RoomCompactReadinessTest do
  @moduledoc """
  A compaction row leaves the seat's readiness as it was: an idle seat that
  compacts stays idle (cv_send reaches it), a working one stays busy.
  """
  use ClaudiverseServer.DataCase

  alias ClaudiverseServer.Sessions.Room
  import ClaudiverseServer.Fixtures

  setup do
    user = user_fixture()
    session = session_fixture(user)
    stop_room(session.id)
    {:ok, _} = ClaudiverseServer.Sessions.Supervisor.start_room(session.id, owner_id: user.id)
    on_exit(fn -> stop_room(session.id) end)
    %{session: session}
  end

  defp stop_room(id) do
    case Registry.lookup(ClaudiverseServer.Sessions.Registry, id) do
      [{pid, _}] -> ClaudiverseServer.Sessions.Supervisor.stop_room(pid)
      [] -> :ok
    end
  end

  defp mirror(session, rows) do
    Room.mirror_messages(session.id, rows)
    Room.get_status(session.id)
  end

  test "an idle seat that compacts stays idle", %{session: session} do
    assert mirror(session, [%{"type" => "idle"}]).idle
    assert mirror(session, [%{"type" => "compact"}]).idle
  end

  test "the /compact inbox command's idle frame landing before the compact row still ends idle", %{session: session} do
    status = mirror(session, [%{"type" => "user", "message" => %{"role" => "user", "content" => "/compact"}}, %{"type" => "idle"}, %{"type" => "compact"}])
    assert status.idle
  end

  test "a working seat that compacts stays busy", %{session: session} do
    refute mirror(session, [%{"type" => "assistant", "message" => %{"role" => "assistant", "content" => []}}]).idle
    refute mirror(session, [%{"type" => "compact"}]).idle
  end
end
