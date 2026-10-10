defmodule ClaudiverseServer.Notifications.RouterSeatSeenTest do
  @moduledoc """
  A forum subscriber whose listener is unbound (a server restart rehydrates
  listeners with no session) gets its queued pings when the seat is next seen
  alive, not at its next finished turn: ipsum-orchestrator, idle across the 2026-10-09
  08:14Z restart, got thread reply 31000 two hours late.
  """
  use ClaudiverseServer.DataCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.Notifications.Router
  alias ClaudiverseServer.Sessions.{Room, Supervisor}

  setup do
    user = user_fixture()
    seat = session_fixture(user, %{title: "seat-seen-#{System.unique_integer([:positive])}"})
    {:ok, room} = Supervisor.start_room(seat.id, owner_id: user.id)
    Room.register_sidecar(seat.id, self())
    Room.mirror_messages(seat.id, [%{"type" => "idle"}])
    # The idle frame casts went_idle to the Router; let it land before a test
    # queues a ping, or it rebinds the listener by title and delivers at once.
    Room.get_status(seat.id)
    :sys.get_state(Router)

    on_exit(fn -> if Process.alive?(room), do: Supervisor.stop_room(room) end)

    %{seat: seat}
  end

  # The listener goes while this test's sandbox still owns the database: the
  # Router's unsubscribe writes to it, and from on_exit that write crashed it.
  defp done(seat) do
    Router.unsubscribe(seat.title)
    :sys.get_state(Router)
  end

  defp reply_in_thread(title),
    do: Router.forum_post(%{channel: "ipsum-tasks", post_id: 31000, author: "ipsum-w6-t30998"}, [title])

  test "an unbound listener holds its ping until the seat is seen, then gets it", %{seat: seat} do
    reply_in_thread(seat.title)
    refute_receive {:forward_to_sidecar, "remote_input", _}, 300

    Router.seat_seen(seat.title, seat.id)
    assert_receive {:forward_to_sidecar, "remote_input", %{"content" => content}}, 1_000
    assert content =~ "forum #ipsum-tasks"
    assert content =~ "31000"
    done(seat)
  end

  test "a seat seen with nothing queued is bound and sent nothing", %{seat: seat} do
    # As a restart leaves a subscriber: a listener, no session bound.
    Router.forum_subscribe(seat.title, nil)
    Router.seat_seen(seat.title, seat.id)
    refute_receive {:forward_to_sidecar, "remote_input", _}, 300

    # Bound now: the next reply reaches it at once.
    reply_in_thread(seat.title)
    assert_receive {:forward_to_sidecar, "remote_input", %{"content" => content}}, 1_000
    assert content =~ "31000"
    done(seat)
  end

  test "a title with no listener is left alone", %{seat: seat} do
    Router.seat_seen("nobody-#{seat.id}", seat.id)
    refute_receive {:forward_to_sidecar, "remote_input", _}, 300
  end
end
