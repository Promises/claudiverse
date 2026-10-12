defmodule ClaudiverseServerWeb.RunnerTest do
  @moduledoc "Runner heartbeats, the fleet list, and fleet membership stamped from a runner's report."
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.{Hosts, Repo, Runners}

  setup do
    {user, api} = user_with_token()
    :sys.replace_state(Runners, fn _ -> %{} end)
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, Hosts.events_topic(user.id))
    on_exit(fn -> Application.delete_env(:claudiverse_server, :runner_missing_after_ms) end)
    %{user: user, api: api}
  end

  defp beat(ctx, body), do: build_conn() |> put_req_header("authorization", "Bearer " <> ctx.api) |> post("/api/runners/heartbeat", body)
  defp fleets(ctx), do: build_conn() |> put_req_header("authorization", "Bearer " <> ctx.api) |> get("/api/fleets") |> json_response(200) |> Map.fetch!("fleets")
  defp idle(extra \\ %{}), do: Map.merge(%{slot: "lorem-w1", fleet: "lorem-fleet", state: "idle", host: "m1", lane: "lorem-tasks-deep"}, extra)

  test "a heartbeat with a bad slot, fleet or state is refused", ctx do
    for body <- [idle(%{slot: "a b"}), idle(%{fleet: nil}), idle(%{state: "sleeping"}), idle(%{host: String.duplicate("x", 201)})] do
      assert beat(ctx, body) |> json_response(400), inspect(body)
    end

    assert fleets(ctx) == []
  end

  test "fleets lists each fleet's runner slots and running seats", ctx do
    assert beat(ctx, idle()) |> json_response(200)
    assert beat(ctx, idle(%{slot: "ipsum-w4", fleet: "ipsum-fleet", channel: "ipsum-tasks-deep"})) |> json_response(200)
    session_fixture(ctx.user, %{title: "lorem-admin", fleet: "lorem-fleet", origin: "manual", host: "m5"})

    [ipsum, lorem] = fleets(ctx)
    assert %{"fleet" => "ipsum-fleet", "runners" => [%{"slot" => "ipsum-w4", "status" => "idle", "channel" => "ipsum-tasks-deep"}], "seats" => []} = ipsum
    assert %{"fleet" => "lorem-fleet", "runners" => [%{"slot" => "lorem-w1", "status" => "idle", "host" => "m1"}],
             "seats" => [%{"title" => "lorem-admin", "origin" => "manual"}]} = lorem
  end

  test "a busy runner's seat gets the fleet, origin runner and host, never overwriting the seat's own", ctx do
    bare = session_fixture(ctx.user, %{title: "lorem-w1-t1595"})
    own = session_fixture(ctx.user, %{title: "lorem-w2-t1600", fleet: "x", origin: "manual", host: "own-host"})

    beat(ctx, idle(%{state: "busy", seat: "lorem-w1-t1595", task: 1595})) |> json_response(200)
    beat(ctx, idle(%{slot: "lorem-w2", state: "busy", seat: "lorem-w2-t1600", task: 1600})) |> json_response(200)

    assert %{fleet: "lorem-fleet", origin: "runner", host: "m1"} = Repo.reload!(bare)
    assert %{fleet: "x", origin: "manual", host: "own-host"} = Repo.reload!(own)
  end

  test "a change is announced on operator:events; a repeat heartbeat is not", ctx do
    beat(ctx, idle())
    assert_receive {"runner", %{slot: "lorem-w1", status: "idle"}}
    beat(ctx, idle())
    refute_receive {"runner", _}, 100
    beat(ctx, idle(%{state: "busy", seat: "lorem-w1-t7", task: 7}))
    assert_receive {"runner", %{slot: "lorem-w1", status: "busy", seat: "lorem-w1-t7", task: 7}}
  end

  test "a slot that stops beating reads missing, announced once; beating again brings it back", ctx do
    beat(ctx, idle())
    assert_receive {"runner", %{status: "idle"}}
    Application.put_env(:claudiverse_server, :runner_missing_after_ms, 0)
    Process.sleep(5)

    send(Runners, :sweep)
    assert_receive {"runner", %{slot: "lorem-w1", status: "missing"}}, 1_000
    send(Runners, :sweep)
    refute_receive {"runner", _}, 100
    assert [%{"runners" => [%{"status" => "missing"}]}] = fleets(ctx)

    Application.put_env(:claudiverse_server, :runner_missing_after_ms, 75_000)
    beat(ctx, idle())
    assert_receive {"runner", %{status: "idle"}}
  end

  test "a runner that closes cleanly says stopped and leaves the list", ctx do
    beat(ctx, idle())
    beat(ctx, idle(%{state: "stopped"}))
    assert_receive {"runner", %{slot: "lorem-w1", status: "stopped"}}
    assert fleets(ctx) == []
  end

  test "another user's runners are not listed", ctx do
    {_other, other_api} = user_with_token(%{email: "other@test.com"})
    build_conn() |> put_req_header("authorization", "Bearer " <> other_api) |> post("/api/runners/heartbeat", idle()) |> json_response(200)
    assert fleets(ctx) == []
  end

  test "the report cv-runner sends is accepted as it is", ctx do
    # slotReport() in agent/tools/cv-runner.mjs, as JSON (undefined fields dropped)
    report = %{"slot" => "ipsum-w5", "fleet" => "ipsum-fleet", "state" => "busy", "host" => "my-mac.local",
               "channel" => "ipsum-tasks", "task_source" => "forum", "model" => "claude-opus-5-5[1m]",
               "seat" => "ipsum-w5-t30450", "task" => 30450, "since" => "2026-10-05T06:40:00.000Z"}
    assert beat(ctx, report) |> json_response(200)
    assert [%{"runners" => [%{"slot" => "ipsum-w5", "status" => "busy", "task" => 30450, "model" => "claude-opus-5-5[1m]"}]}] = fleets(ctx)
  end
end
