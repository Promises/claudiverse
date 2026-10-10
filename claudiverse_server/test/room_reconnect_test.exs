defmodule ClaudiverseServer.RoomReconnectTest do
  @moduledoc """
  A seat that loses its WebSocket and comes back must read as running again.

  🔴 The :DOWN handler WRITES :stopped to the database while register_sidecar
  only set :running in GenServer state, so a reconnected seat stayed recorded as
  stopped forever — and the default /api/sessions view filters to running, so it
  vanished from the dashboard while still working.
  """
  use ClaudiverseServer.DataCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.Sessions
  alias ClaudiverseServer.Sessions.Room
  alias ClaudiverseServer.Sessions.Supervisor, as: SessionSupervisor

  test "register_sidecar restores a session marked stopped" do
    {user, _token} = user_with_token()

    {:ok, session} =
      Sessions.create_session(%{
        title: "reconnect-seat",
        type: :sidecar,
        mode: :json,
        status: :running,
        claude_session_id: "recon-1",
        user_id: user.id
      })

    {:ok, _pid} = SessionSupervisor.start_room(session.id, owner_id: user.id)

    # what a dropped WebSocket leaves behind
    {:ok, _} = Sessions.update_session(session, %{status: :stopped})
    assert Sessions.get_session!(session.id).status == :stopped

    # the seat's socket comes back
    :ok = Room.register_sidecar(session.id, self())

    assert Sessions.get_session!(session.id).status == :running,
           "a reconnected sidecar must be recorded as running, not just in memory"
  end

  test "a sidecar that reconnects within the grace is a blip: nothing ends, nothing is announced" do
    Application.put_env(:claudiverse_server, :sidecar_grace_ms, 500)
    on_exit(fn -> Application.put_env(:claudiverse_server, :sidecar_grace_ms, 100) end)
    {user, _token} = user_with_token()
    {:ok, session} = Sessions.create_session(%{title: "blip-seat", type: :sidecar, user_id: user.id, claude_session_id: "blip-1"})
    {:ok, _pid} = SessionSupervisor.start_room(session.id, owner_id: user.id)
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, "session:#{session.id}")

    first = spawn(fn -> Process.sleep(:infinity) end)
    :ok = Room.register_sidecar(session.id, first)
    Process.exit(first, :kill)
    Process.sleep(50)
    :ok = Room.register_sidecar(session.id, self())

    refute_receive {"session_ended", _}, 800
    assert Sessions.get_session!(session.id).status == :running
  end
end
