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

  # --- usage events (PoolEvents), by their reserved titles ---------------------

  @reset %{"change" => "reset", "limit" => "weekly", "text" => "POOL reset: work weekly 94% → 0% (next reset Sun 2026-10-18 09:59 UTC)"}
  @reset_session %{"change" => "reset", "limit" => "session", "text" => "POOL reset: work session 80% → 0% (next reset Sun 2026-10-11 14:00 UTC)"}
  @capped %{"change" => "capped", "limit" => "weekly", "text" => "POOL capped: personal weekly 100%, cooling until Mon 2026-10-12 00:00 UTC"}
  @step5 %{"change" => "step", "limit" => "weekly", "every" => 5, "crossed" => 85, "text" => "POOL step: work weekly crossed 85% (now 86%)"}
  @step10 %{"change" => "step", "limit" => "weekly", "every" => 10, "crossed" => 90, "text" => "POOL step: work weekly crossed 90% (now 91%)"}

  defp event(e), do: Phoenix.PubSub.broadcast(ClaudiverseServer.PubSub, AnthropicAuths.pool_topic(), {"pool", e})

  defp pinged(l, watch, e) do
    {:ok, _} = Router.subscribe(l.title, l.id, watch)
    event(e)

    receive do
      {:forward_to_sidecar, "remote_input", %{"content" => content}} -> content
    after
      400 -> nil
    end
  end

  test "each usage event pings the listeners of its own title, with its line", %{listener: l} do
    for {watch, e} <- [{"@pool:reset", @reset}, {"@pool:reset:session", @reset_session}, {"@pool:capped", @capped},
                       {"@pool:step:5", @step5}, {"@pool:step:10", @step10}] do
      content = pinged(l, [watch], e)
      assert content =~ "[claudiverse] 1 event(s) ready — #{e["text"]}.", "#{watch}: #{inspect(content)}"
      Router.ack(l.title, :all)
      Room.mirror_messages(l.id, [%{"type" => "idle"}])
    end
  end

  test "a usage event pings nobody watching another title", %{listener: l} do
    assert pinged(l, ["@pool:reset:session"], @reset) == nil, "the session form does not get weekly resets"
    assert pinged(l, ["@pool:reset"], @reset_session) == nil, "nor the weekly form session resets"
    assert pinged(l, ["@pool:step:10"], @step5) == nil
    assert pinged(l, ["@pool"], @capped) == nil, "plain @pool is switches only"
  end

  test "@pool:* gets the weekly events with steps of 5, and the switches", %{listener: l} do
    for e <- [@reset, @capped, @step5] do
      assert pinged(l, ["@pool:*"], e) =~ e["text"]
      Router.ack(l.title, :all)
      Room.mirror_messages(l.id, [%{"type" => "idle"}])
    end

    for e <- [@reset_session, @step10], do: assert(pinged(l, ["@pool:*"], e) == nil)

    {:ok, _} = Router.subscribe(l.title, l.id, ["@pool:*"])
    pool("degrade", 3)
    assert_receive {:forward_to_sidecar, "remote_input", %{"content" => content}}, 1_000
    assert content =~ "ACCOUNT POOL switched"
  end

  @needs_reauth %{"change" => "needs_reauth", "auth_id" => 2, "label" => "Personal", "reason" => "refresh rejected with HTTP 400",
                  "text" => "POOL needs re-auth: Personal (refresh rejected with HTTP 400) — re-authorize in the app"}
  @reauthorized %{"change" => "reauthorized", "auth_id" => 2, "label" => "Personal", "text" => "POOL re-authorized: Personal (available)"}

  test "an account needing re-auth, and its re-authorization, ping @pool and @pool:*", %{listener: l} do
    for e <- [@needs_reauth, @reauthorized], watch <- [["@pool"], ["@pool:*"]] do
      assert pinged(l, watch, e) =~ e["text"]
      Router.ack(l.title, :all)
      Room.mirror_messages(l.id, [%{"type" => "idle"}])
    end

    assert pinged(l, ["@pool:reset"], @needs_reauth) == nil
  end

  test "a listener not watching @pool is not pinged", %{listener: l} do
    {:ok, _} = Router.subscribe(l.title, l.id, ["some-seat"])
    pool("degrade", 3)
    refute_receive {:forward_to_sidecar, "remote_input", _}, 300
  end
end
