defmodule ClaudiverseServer.Sessions.ZombieSweepTest do
  @moduledoc """
  A "running" row with no Room and no recent activity is stopped; a row with a
  Room, or with recent activity, is left alone however old it is.
  """
  use ClaudiverseServer.DataCase

  import Ecto.Query
  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.Repo
  alias ClaudiverseServer.Sessions
  alias ClaudiverseServer.Sessions.{Room, Session, ZombieSweep}

  @idle_ms :timer.minutes(30)

  setup do
    %{user: user_fixture()}
  end

  defp stop_room(id) do
    case Registry.lookup(ClaudiverseServer.Sessions.Registry, id) do
      [{pid, _}] -> ClaudiverseServer.Sessions.Supervisor.stop_room(pid)
      [] -> :ok
    end
  end

  defp aged(session, hours) do
    at = NaiveDateTime.add(NaiveDateTime.utc_now(), -hours * 3600, :second) |> NaiveDateTime.truncate(:second)
    from(s in Session, where: s.id == ^session.id) |> Repo.update_all(set: [inserted_at: at])
    session
  end

  defp with_room(session, user) do
    stop_room(session.id)
    {:ok, _} = ClaudiverseServer.Sessions.Supervisor.start_room(session.id, owner_id: user.id)
    # Stopping a Room touches no database, so it is safe after the sandbox goes.
    on_exit(fn -> stop_room(session.id) end)
    session
  end

  defp status(session), do: Sessions.get_session!(session.id).status

  test "stops an old running row with no Room, and names it", %{user: user} do
    zombie = session_fixture(user, %{title: "ipsum-orchestrator"}) |> aged(24 * 60)
    # Ids are reused across tests: a Room another test left under this id is not this row's.
    stop_room(zombie.id)

    assert ZombieSweep.sweep(@idle_ms) == [{zombie.id, "ipsum-orchestrator"}]
    assert status(zombie) == :stopped
  end

  test "leaves an idle row that still has a Room (a live seat sitting idle)", %{user: user} do
    live = session_fixture(user, %{title: "lorem-admin"}) |> aged(48) |> with_room(user)

    assert ZombieSweep.sweep(@idle_ms) == []
    assert status(live) == :running
  end

  test "leaves a Room-less row that was active recently (a seat mid-restart)", %{user: user} do
    fresh = session_fixture(user, %{title: "ipsum-admin"}) |> aged(48)
    {:ok, _} = Sessions.create_message(%{type: "assistant", payload: %{"type" => "assistant"}, sequence: 0, session_id: fresh.id})

    assert ZombieSweep.sweep(@idle_ms) == []
    assert status(fresh) == :running
  end

  test "stops a superseded row whose Room has no socket of its own (a ghost a title-poll woke)", %{user: user} do
    ghost = session_fixture(user, %{title: "ipsum-orchestrator"}) |> aged(24 * 60) |> with_room(user)
    live = session_fixture(user, %{title: "ipsum-orchestrator"}) |> aged(2) |> with_room(user)

    assert ZombieSweep.sweep(@idle_ms) == [{ghost.id, "ipsum-orchestrator"}]
    assert status(ghost) == :stopped
    assert status(live) == :running
  end

  test "leaves a superseded row that has a sidecar socket (a real process)", %{user: user} do
    old = session_fixture(user, %{title: "twin"}) |> aged(24 * 60) |> with_room(user)
    Room.register_sidecar(old.id, self())
    _newer = session_fixture(user, %{title: "twin"}) |> aged(2) |> with_room(user)

    assert ZombieSweep.sweep(@idle_ms) == []
    assert status(old) == :running
  end

  test "never touches rows that are already stopped", %{user: user} do
    stopped = session_fixture(user, %{title: "old", status: :stopped}) |> aged(24 * 60)

    assert ZombieSweep.sweep(@idle_ms) == []
    assert status(stopped) == :stopped
  end
end
