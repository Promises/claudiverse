defmodule ClaudiverseServer.Sessions.RowTimeTest do
  @moduledoc """
  Every stored and replayed row carries a "timestamp": the row's own when it
  has one, else its arrival time (mod rows carry none), else, for rows stored
  before arrival times were stamped, the time the row was stored.
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
    %{session: session}
  end

  defp stop_room(id) do
    case Registry.lookup(ClaudiverseServer.Sessions.Registry, id) do
      [{pid, _}] -> ClaudiverseServer.Sessions.Supervisor.stop_room(pid)
      [] -> :ok
    end
  end

  defp row(uuid, extra \\ %{}),
    do: Map.merge(%{"type" => "assistant", "uuid" => uuid, "message" => %{"role" => "assistant", "content" => []}}, extra)

  defp iso?(t), do: match?({:ok, _, 0}, DateTime.from_iso8601(t))

  test "a row with no time gets its arrival time; a row's own time wins", %{session: session} do
    Room.mirror_messages(session.id, [row("bare"), row("own", %{"timestamp" => "2026-10-09T07:30:24.437Z"})])
    Room.get_status(session.id)

    [own, bare] = Sessions.recent_payloads(session.id, 10)
    assert bare["uuid"] == "bare" and iso?(bare["timestamp"])
    assert own["timestamp"] == "2026-10-09T07:30:24.437Z"
  end

  test "an agent_message's inner row is stamped too", %{session: session} do
    Room.mirror_messages(session.id, [%{"type" => "agent_message", "agent_id" => "a1", "message" => row("inner")}])
    Room.get_status(session.id)

    [agent_row] = Sessions.recent_agent_payloads(session.id, 10)
    assert iso?(agent_row["timestamp"])
    assert agent_row["message"]["timestamp"] == agent_row["timestamp"]
  end

  test "a row stored with no time replays with the time it was stored", %{session: session} do
    {:ok, stored} = Sessions.create_message(%{type: "assistant", payload: row("old"), sequence: 0, session_id: session.id})

    [old] = Sessions.recent_payloads(session.id, 10)
    assert old["timestamp"] == NaiveDateTime.to_iso8601(stored.inserted_at) <> "Z"
  end
end
