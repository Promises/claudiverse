defmodule ClaudiverseServerWeb.SessionChannelTest do
  use ClaudiverseServer.DataCase

  import ClaudiverseServer.Fixtures
  import Phoenix.ChannelTest

  @endpoint ClaudiverseServerWeb.Endpoint

  alias ClaudiverseServerWeb.{UserSocket, SessionChannel}

  setup do
    {user, token} = user_with_token()
    session = session_fixture(user)

    # Stop any leftover room
    case Registry.lookup(ClaudiverseServer.Sessions.Registry, session.id) do
      [{pid, _}] -> ClaudiverseServer.Sessions.Supervisor.stop_room(pid)
      [] -> :ok
    end

    {:ok, pid} = ClaudiverseServer.Sessions.Supervisor.start_room(session.id, owner_id: user.id)
    {:ok, socket} = connect(UserSocket, %{"token" => token})

    on_exit(fn ->
      if Process.alive?(pid), do: ClaudiverseServer.Sessions.Supervisor.stop_room(pid)
    end)

    %{user: user, token: token, session: session, socket: socket}
  end

  test "observer can join session", %{socket: socket, session: session} do
    {:ok, _reply, _socket} = subscribe_and_join(socket, SessionChannel, "session:#{session.id}", %{"role" => "observer"})

    # Should receive replay
    assert_push "replay", %{"messages" => []}
  end

  test "a viewer joining a session with no Room gets an empty replay, not a crash", %{socket: socket, session: session} do
    [{pid, _}] = Registry.lookup(ClaudiverseServer.Sessions.Registry, session.id)
    ClaudiverseServer.Sessions.Supervisor.stop_room(pid)

    {:ok, _reply, channel} = subscribe_and_join(socket, SessionChannel, "session:#{session.id}", %{"role" => "observer"})
    assert_push "replay", %{"messages" => []}
    assert Process.alive?(channel.channel_pid)
  end

  test "sidecar can join session", %{socket: socket, session: session} do
    {:ok, _reply, _socket} = subscribe_and_join(socket, SessionChannel, "session:#{session.id}", %{"role" => "sidecar"})

    assert_push "replay", %{"messages" => []}
  end

  test "cannot join another user's session", %{session: session} do
    {_other, other_token} = user_with_token(%{email: "intruder@test.com"})
    {:ok, other_socket} = connect(UserSocket, %{"token" => other_token})

    assert {:error, %{reason: "not_found"}} =
             subscribe_and_join(other_socket, SessionChannel, "session:#{session.id}", %{"role" => "observer"})
  end

  test "sidecar mirrors messages to observers", %{socket: socket, session: session} do
    # Join as observer
    {:ok, _reply, _observer_socket} = subscribe_and_join(socket, SessionChannel, "session:#{session.id}", %{"role" => "observer"})

    # Sidecar sends mirrored messages via the Room
    ClaudiverseServer.Sessions.Room.mirror_messages(session.id, [
      %{"type" => "assistant", "message" => %{"content" => "hi"}, "uuid" => "u1", "session_id" => "s1"}
    ])

    assert_push "message", %{"type" => "assistant"}, 1000
  end

  test "observer send_message forwards to sidecar", %{socket: socket, session: session} do
    # Register self as sidecar so we receive forwarded messages
    ClaudiverseServer.Sessions.Room.register_sidecar(session.id, self())

    {:ok, _reply, observer_socket} = subscribe_and_join(socket, SessionChannel, "session:#{session.id}", %{"role" => "observer"})

    push(observer_socket, "send_message", %{"content" => "Hello from web"})

    assert_receive {:forward_to_sidecar, "remote_input", %{"content" => "Hello from web"}}, 1000
  end

  test "invalid token cannot connect" do
    assert :error = connect(UserSocket, %{"token" => "bogus"})
  end

  test "missing token cannot connect" do
    assert :error = connect(UserSocket, %{})
  end

  # --- a resumed seat's replay -----------------------------------------------------

  defp msg!(session, seq, text) do
    payload = %{"type" => "assistant", "text" => text, "timestamp" => "2026-10-09T07:30:24.437Z"}
    {:ok, _} = ClaudiverseServer.Sessions.create_message(%{type: "assistant", payload: payload, sequence: seq, session_id: session.id})
    payload
  end

  defp resumed_chain(user) do
    conv = "96db8e7a-6374-474d-89f1-61c46be8f84e"
    original = session_fixture(user, %{title: "r", claude_session_id: conv, status: :stopped})
    a1 = msg!(original, 1, "a1")
    a2 = msg!(original, 2, "a2")
    {:ok, middle} = ClaudiverseServer.Sessions.create_session(%{title: "r", user_id: user.id, type: :sidecar, status: :stopped,
                                                               claude_session_id: "11111111-0000-4000-8000-000000000001"})
    {:ok, middle} = middle |> Ecto.Changeset.change(conversation_id: conv) |> ClaudiverseServer.Repo.update()
    b1 = msg!(middle, 1, "b1")
    {:ok, current} = ClaudiverseServer.Sessions.create_session(%{title: "r", user_id: user.id, type: :sidecar,
                                                                claude_session_id: "22222222-0000-4000-8000-000000000002"})
    {:ok, current} = current |> Ecto.Changeset.change(conversation_id: conv) |> ClaudiverseServer.Repo.update()
    %{conv: conv, current: current, earlier: [a1, a2, b1]}
  end

  test "a resumed seat's replay starts with its conversation's earlier rows, oldest first", %{user: user, socket: socket} do
    # Not part of it: another user's EARLIER row of the same id, an unrelated
    # row, and a LATER row of the same conversation.
    {other, _} = user_with_token(%{email: "other@test.com"})
    msg!(session_fixture(other, %{title: "x", claude_session_id: "96db8e7a-6374-474d-89f1-61c46be8f84e"}), 1, "theirs")
    msg!(session_fixture(user, %{title: "unrelated"}), 1, "unrelated")
    chain = resumed_chain(user)
    {:ok, later} = ClaudiverseServer.Sessions.create_session(%{title: "r", user_id: user.id, type: :sidecar,
                                                              claude_session_id: "33333333-0000-4000-8000-000000000003"})
    {:ok, later} = later |> Ecto.Changeset.change(conversation_id: chain.conv) |> ClaudiverseServer.Repo.update()
    msg!(later, 1, "later")

    {:ok, _pid} = ClaudiverseServer.Sessions.Supervisor.start_room(chain.current.id, owner_id: user.id)
    {:ok, _, _} = subscribe_and_join(socket, SessionChannel, "session:#{chain.current.id}", %{"role" => "observer"})

    expected = chain.earlier
    assert_push "replay", %{"messages" => ^expected, "earlier_count" => 3}
  end

  test "the earlier conversation is capped at the newest messages", %{user: user} do
    chain = resumed_chain(user)
    assert ClaudiverseServer.Sessions.earlier_conversation(chain.current.id, 2) == Enum.drop(chain.earlier, 1)
    assert ClaudiverseServer.Sessions.earlier_conversation(chain.current.id, 1) == Enum.drop(chain.earlier, 2)
  end

  test "a seat that was not resumed has no earlier conversation", %{socket: socket, session: session} do
    {:ok, _, _} = subscribe_and_join(socket, SessionChannel, "session:#{session.id}", %{"role" => "observer"})
    assert_push "replay", %{"messages" => [], "earlier_count" => 0}
  end

  test "an observer receives each mirrored message exactly once", %{socket: socket, session: session} do
    {:ok, _, _} = subscribe_and_join(socket, SessionChannel, "session:#{session.id}", %{"role" => "observer"})
    assert_push "replay", _

    event = %{"type" => "stream_event", "uuid" => "u-1", "event" => %{"delta" => %{"text" => "The"}}}
    ClaudiverseServer.Sessions.Room.mirror_messages(session.id, [event])

    assert_push "message", ^event
    refute_push "message", _, 300
  end

  test "an observer joining under a non-canonical id still receives each message once", %{socket: socket, session: session} do
    {:ok, _, _} = subscribe_and_join(socket, SessionChannel, "session:0#{session.id}", %{"role" => "observer"})
    assert_push "replay", _

    event = %{"type" => "assistant", "uuid" => "u-2", "timestamp" => "2026-10-09T07:30:24.437Z"}
    ClaudiverseServer.Sessions.Room.mirror_messages(session.id, [event])

    assert_push "message", ^event
    refute_push "message", _, 300
  end

  test "replay leaves out stream fragments, live and from earlier rows", %{user: user, socket: socket} do
    chain = resumed_chain(user)
    {:ok, _} = ClaudiverseServer.Sessions.create_message(%{type: "stream_event", payload: %{"type" => "stream_event", "n" => 0},
                                                           sequence: 99, session_id: chain.current.id - 1})
    {:ok, _pid} = ClaudiverseServer.Sessions.Supervisor.start_room(chain.current.id, owner_id: user.id)
    final = %{"type" => "assistant", "uuid" => "final", "timestamp" => "2026-10-09T07:30:24.437Z"}
    ClaudiverseServer.Sessions.Room.mirror_messages(chain.current.id, [%{"type" => "stream_event", "n" => 1}, final])

    {:ok, _, _} = subscribe_and_join(socket, SessionChannel, "session:#{chain.current.id}", %{"role" => "observer"})
    expected = chain.earlier ++ [final]
    assert_push "replay", %{"messages" => ^expected, "earlier_count" => 3}
  end

  test "a Room that starts fresh (a server restart) replays the stored history, without stream fragments", %{user: user, socket: socket} do
    s = session_fixture(user, %{title: "restarted"})
    a = msg!(s, 1, "before the restart")
    {:ok, _} = ClaudiverseServer.Sessions.create_message(%{type: "stream_event", payload: %{"type" => "stream_event"}, sequence: 2, session_id: s.id})
    b = msg!(s, 3, "also before")

    # Session ids repeat across sandboxed tests, and a Room another test left
    # running at this id would be joined instead of a fresh one, replaying
    # that test's rows (seen intermittently in full-suite runs).
    with [{old, _}] <- Registry.lookup(ClaudiverseServer.Sessions.Registry, s.id),
         do: ClaudiverseServer.Sessions.Supervisor.stop_room(old)

    {:ok, _pid} = ClaudiverseServer.Sessions.Supervisor.start_room(s.id, owner_id: user.id)
    {:ok, _, _} = subscribe_and_join(socket, SessionChannel, "session:#{s.id}", %{"role" => "observer"})
    expected = [a, b]
    assert_push "replay", %{"messages" => ^expected, "earlier_count" => 0}
  end

  # --- who may answer a permission prompt -------------------------------------

  defp held_prompt(session) do
    rid = "hook-" <> Integer.to_string(System.unique_integer([:positive]))
    ClaudiverseServer.Sessions.Room.mirror_messages(session.id, [
      %{"type" => "control_request", "request_id" => rid, "hook" => true,
        "request" => %{"subtype" => "can_use_tool", "tool_name" => "Bash", "input" => %{"command" => "touch x"}}}
    ])
    :ok = ClaudiverseServer.SeatLinks.register_request(rid)
    rid
  end

  defp observer(session, token) do
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    {:ok, _, chan} = subscribe_and_join(socket, SessionChannel, "session:#{session.id}", %{"role" => "observer"})
    chan
  end

  test "a seat's or runner's token (api) may not ALLOW a permission prompt; the prompt stays open", %{token: api, session: session} do
    rid = held_prompt(session)
    ref = push(observer(session, api), "permission_response", %{"request_id" => rid, "decision" => "allow"})
    assert_reply ref, :error, %{reason: "only the operator's app may allow a permission prompt"}
    refute_receive {:permission_decision, _}, 200
    assert Map.has_key?(:sys.get_state(room_pid(session)).pending_permissions, rid)
  end

  test "a viewer that opens the seat after a prompt was asked gets it in its replay, until it is answered", %{token: api, session: session} do
    rid = held_prompt(session)

    chan = observer(session, api)
    assert_push "replay", %{"pending_permissions" => [%{"request_id" => ^rid, "tool_name" => "Bash", "input" => %{"command" => "touch x"}}]}

    ref = push(chan, "permission_response", %{"request_id" => rid, "decision" => "deny"})
    assert_reply ref, :ok
    observer(session, api)
    assert_push "replay", %{"pending_permissions" => []}
  end

  test "an api token may DENY", %{token: api, session: session} do
    rid = held_prompt(session)
    ref = push(observer(session, api), "permission_response", %{"request_id" => rid, "decision" => "deny"})
    assert_reply ref, :ok
    assert_receive {:permission_decision, "deny"}
  end

  test "the operator's app token may allow, once: a replayed allow finds nothing", %{user: user, session: session} do
    app = ClaudiverseServer.Accounts.create_user_api_token(user, "app")
    chan = observer(session, app)
    rid = held_prompt(session)
    ref = push(chan, "permission_response", %{"request_id" => rid, "decision" => "allow"})
    assert_reply ref, :ok
    assert_receive {:permission_decision, "allow"}

    # A later prompt is not answered by replaying the earlier answer.
    later = held_prompt(session)
    ref = push(chan, "permission_response", %{"request_id" => rid, "decision" => "allow"})
    assert_reply ref, :ok
    refute_receive {:permission_decision, _}, 200
    assert Map.has_key?(:sys.get_state(room_pid(session)).pending_permissions, later)
  end

  defp room_pid(session) do
    [{pid, _}] = Registry.lookup(ClaudiverseServer.Sessions.Registry, session.id)
    pid
  end

  test "raw keystrokes are the operator's apps' alone", %{user: user, token: api, session: session} do
    ClaudiverseServer.Sessions.Room.register_sidecar(session.id, self())
    ref = push(observer(session, api), "send_raw", %{"data" => "1\r"})
    assert_reply ref, :error, %{reason: "only the operator's app may send keystrokes to a seat"}
    refute_receive {:forward_to_sidecar, "remote_raw", _}, 200

    app = ClaudiverseServer.Accounts.create_user_api_token(user, "app")
    ref = push(observer(session, app), "send_raw", %{"data" => "1\r"})
    assert_reply ref, :ok
  end
end
