defmodule ClaudiverseServer.Sessions.RoomAgentsTest do
  @moduledoc """
  A seat's agents (a fork, a background subagent, a teammate), mirrored as
  agent_* rows by claudiverse-seat 0.9.0: kept apart from main's replay and
  busy/idle, with the latest agent list and a busy count.
  """
  use ClaudiverseServer.DataCase

  alias ClaudiverseServer.Sessions
  alias ClaudiverseServer.Sessions.Room
  import ClaudiverseServer.Fixtures

  setup do
    user = user_fixture()
    session = session_fixture(user)
    stop_room(session.id)
    {:ok, pid} = ClaudiverseServer.Sessions.Supervisor.start_room(session.id, owner_id: user.id)
    # Ids are reused across tests: whatever Room this one leaves must go.
    on_exit(fn -> stop_room(session.id) end)

    %{user: user, session: session, pid: pid}
  end

  defp stop_room(id) do
    case Registry.lookup(ClaudiverseServer.Sessions.Registry, id) do
      [{pid, _}] -> ClaudiverseServer.Sessions.Supervisor.stop_room(pid)
      [] -> :ok
    end
  end

  defp main_row(text), do: %{"type" => "assistant", "uuid" => "m-" <> text, "message" => %{"role" => "assistant", "content" => [%{"type" => "text", "text" => text}]}}

  defp fork_rows do
    [
      %{"type" => "agent_started", "agent_id" => "a1", "agent_type" => "fork", "description" => "Screenshotting the viewer", "fork" => true, "background" => true},
      %{"type" => "agent_message", "agent_id" => "a1", "message" => main_row("fork says hi")},
      %{"type" => "agents", "agents" => [%{"agent_id" => "a1", "agent_type" => "fork", "status" => "running"},
                                         %{"agent_id" => "a2", "agent_type" => "Explore", "status" => "completed"}]}
    ]
  end

  defp settle(session), do: Room.get_status(session.id)

  test "agent rows go to their own buffer and never into main's replay", %{session: session} do
    Room.mirror_messages(session.id, [main_row("main says hi")])
    Room.mirror_messages(session.id, fork_rows())
    settle(session)

    assert [%{"uuid" => "m-main says hi"}] = Room.get_replay_buffer(session.id)
    agent = Room.get_agent_replay(session.id)
    assert Enum.map(agent.messages, & &1["type"]) == ["agent_started", "agent_message", "agents"]
    assert [%{"agent_id" => "a1", "status" => "running"}, %{"agent_id" => "a2"}] = agent.agents
    assert agent.busy_agents == 1
  end

  test "an agent's rows leave main's busy/idle alone", %{session: session} do
    Room.mirror_messages(session.id, [%{"type" => "idle"}])
    assert %{idle: true} = settle(session)

    Room.mirror_messages(session.id, fork_rows() ++ [%{"type" => "agent_turn_complete", "agent_id" => "a1"}])
    assert %{idle: true, busy_agents: 1} = settle(session)

    # Control: a main row does make the seat busy.
    Room.mirror_messages(session.id, [main_row("main works")])
    assert %{idle: false} = settle(session)
  end

  test "a Room started anew rebuilds the agent buffer and list from the stored rows", %{user: user, session: session, pid: pid} do
    Room.mirror_messages(session.id, [main_row("main")] ++ fork_rows())
    settle(session)
    ClaudiverseServer.Sessions.Supervisor.stop_room(pid)
    {:ok, _} = ClaudiverseServer.Sessions.Supervisor.start_room(session.id, owner_id: user.id)

    assert length(Room.get_replay_buffer(session.id)) == 1
    agent = Room.get_agent_replay(session.id)
    assert length(agent.messages) == 3
    assert agent.busy_agents == 1
    assert Sessions.latest_agents(session.id) |> length() == 2
  end

  test "a permission request names the agent that asks", %{session: session} do
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, "session:#{session.id}")
    Room.mirror_messages(session.id, [%{"type" => "control_request", "request_id" => "r1", "agent_id" => "a1",
                                        "request" => %{"subtype" => "can_use_tool", "tool_name" => "Bash", "input" => %{}}}])
    assert_receive {"permission_request", %{"request_id" => "r1", "agent_id" => "a1"}}, 1_000
  end
end
