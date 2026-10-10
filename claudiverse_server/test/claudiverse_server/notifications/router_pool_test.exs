defmodule ClaudiverseServer.Notifications.RouterPoolTest do
  @moduledoc "The reserved @pool watch: a ping when the account pool's current account changes."
  use ClaudiverseServer.DataCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.{AnthropicAuths, Notifications.Router}
  alias ClaudiverseServer.Sessions.{Room, Supervisor}

  setup do
    user = user_fixture()
    listener = session_fixture(user, %{title: "pool-listener-#{System.unique_integer([:positive])}"})
    {:ok, room} = Supervisor.start_room(listener.id, owner_id: user.id)
    Room.register_sidecar(listener.id, self())
    Room.mirror_messages(listener.id, [%{"type" => "idle"}])
    before = :sys.get_state(Router) |> Map.get(:pool_current)
    :sys.replace_state(Router, &Map.put(&1, :pool_current, 4))

    on_exit(fn ->
      Router.unsubscribe(listener.title)
      :sys.replace_state(Router, &Map.put(&1, :pool_current, before))
      if Process.alive?(room), do: Supervisor.stop_room(room)
    end)

    %{listener: listener}
  end

  defp pool(change, current_id),
    do: Phoenix.PubSub.broadcast(ClaudiverseServer.PubSub, AnthropicAuths.pool_topic(), {"pool", %{"change" => change, "current_id" => current_id, "by" => nil}})

  test "a @pool listener is pinged when the current account changes, naming both", %{listener: l} do
    {:ok, _} = Router.subscribe(l.title, l.id, ["@pool"])
    pool("degrade", 3)
    assert_receive {:forward_to_sidecar, "remote_input", %{"content" => content}}, 1_000
    assert content =~ "ACCOUNT POOL switched: leases now go to account 3 (was account 4; degrade)"
  end

  test "a pool change that leaves the current account as it was pings nobody", %{listener: l} do
    {:ok, _} = Router.subscribe(l.title, l.id, ["@pool"])
    pool("cooling", 4)
    refute_receive {:forward_to_sidecar, "remote_input", _}, 300
  end

  test "a listener not watching @pool is not pinged", %{listener: l} do
    {:ok, _} = Router.subscribe(l.title, l.id, ["some-seat"])
    pool("degrade", 3)
    refute_receive {:forward_to_sidecar, "remote_input", _}, 300
  end
end
