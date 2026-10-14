defmodule ClaudiverseServerWeb.RestartTest do
  @moduledoc """
  Restarting idle seats (Restarts): which seats, by what the server can see,
  and the machine's restart_plan / restart_seat, played by the test process
  over a real host channel.
  """
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures
  import Ecto.Query
  import Phoenix.ChannelTest, except: [connect: 2, connect: 3]

  @endpoint ClaudiverseServerWeb.Endpoint

  alias ClaudiverseServer.{Accounts, Fleets, Hosts, Repo, Restarts}
  alias ClaudiverseServer.Profiles.Profile
  alias ClaudiverseServer.Sessions.Session
  alias ClaudiverseServerWeb.{HostChannel, UserSocket}

  @spawn %{"options" => ["model", "pooled"], "pool_only" => true, "pooled" => true, "runtime" => "stock+mod", "version" => "2.1.296"}

  setup do
    {user, api} = user_with_token()
    app = Accounts.create_user_api_token(user, "app")
    {:ok, host} = Accounts.create_host_token(user, "m5")
    {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{"token" => host})
    {:ok, _, chan} = subscribe_and_join(socket, HostChannel, "host:m5", %{"roots" => ["/srv"], "version" => "0.14.0", "spawn" => @spawn})
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, Hosts.events_topic(user.id))
    %{user: user, api: api, app: app, chan: chan}
  end

  # A running seat on m5, idle for 5 minutes, connected, on 2.1.292.
  defp seat!(ctx, attrs \\ %{}) do
    s = session_fixture(ctx.user, Map.merge(%{title: "w#{System.unique_integer([:positive])}", host: "m5", status: :running,
                                              claude_session_id: Ecto.UUID.generate(), client_version: "2.1.292",
                                              working_directory: "/srv/a"}, attrs))
    old = NaiveDateTime.utc_now() |> NaiveDateTime.add(-300) |> NaiveDateTime.truncate(:second)
    Repo.update_all(from(x in Session, where: x.id == ^s.id), set: [inserted_at: old, updated_at: old])
    {:ok, pid} = ClaudiverseServer.Sessions.Supervisor.start_room(s.id, owner_id: ctx.user.id)
    idle(pid, Map.get(attrs, :busy, false))
    on_exit(fn -> if Process.alive?(pid), do: ClaudiverseServer.Sessions.Supervisor.stop_room(pid) end)
    Repo.get!(Session, s.id)
  end

  defp idle(pid, busy) do
    me = self()
    :sys.replace_state(pid, &%{&1 | idle: not busy, readiness_known: true, sidecar_channel_pid: me})
  end

  defp as(token), do: build_conn() |> put_req_header("authorization", "Bearer " <> token)
  defp restart(ctx, s, body), do: Task.async(fn -> as(ctx.app) |> post("/api/sessions/#{s.id}/restart", body) end)
  defp bulk(ctx, body), do: Task.async(fn -> as(ctx.app) |> post("/api/hosts/m5/restart_idle", body) end)

  # The machine's plan for a seat it looks at.
  defp answer_plan(chan, action \\ "restart") do
    assert_push "request", %{"request_id" => rid, "op" => "restart_plan", "args" => args}
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => true,
      "result" => %{"action" => action, "via" => "spawn", "target_version" => "2.1.296", "argv" => ["--permission-mode", "--mcp-config", "--resume"],
                    "env" => ["CLAUDE_CONFIG_DIR"], "carried" => ["--mcp-config"], "dropped" => []}})
    args
  end

  test "a busy seat is never stopped: refused, and its machine is not even asked", ctx do
    busy = seat!(ctx, %{busy: true})
    resp = Task.await(restart(ctx, busy, %{}))
    assert %{"reason_code" => "busy"} = json_response(resp, 409)
    refute_push "request", _

    t = bulk(ctx, %{"dry_run" => true})
    assert %{"seats" => [%{"action" => "skip", "reason_code" => "busy"}]} = json_response(Task.await(t), 200)
    refute_push "request", %{"op" => "restart_seat"}
  end

  test "dry_run shows the plan, by names, and stops nothing", ctx do
    s = seat!(ctx)
    t = restart(ctx, s, %{"dry_run" => true})
    args = answer_plan(ctx.chan)
    assert args["session_id"] == s.claude_session_id
    assert %{"seat" => %{"action" => "restart", "client_version" => "2.1.292", "target_version" => "2.1.296",
                         "launch" => %{"argv" => ["--permission-mode", "--mcp-config", "--resume"], "env" => ["CLAUDE_CONFIG_DIR"]}}} =
             json_response(Task.await(t), 200)
    refute_push "request", %{"op" => "restart_seat"}
  end

  test "a runner's worker is left out, and so is the caller's own seat unless asked", ctx do
    runner = seat!(ctx, %{origin: "runner"})
    assert %{"reason_code" => "runner"} = json_response(Task.await(restart(ctx, runner, %{})), 409)
    me = seat!(ctx)
    assert %{"reason_code" => "self"} = json_response(Task.await(restart(ctx, me, %{"caller" => me.id})), 409)
    refute_push "request", _
  end

  test "a restart: started, the machine restarts it, and the re-registered row reports the new version", ctx do
    s = seat!(ctx)
    t = restart(ctx, s, %{})
    answer_plan(ctx.chan)
    assert %{"restart_id" => rid} = json_response(Task.await(t), 202)
    assert_receive {"seat_restart", %{restart_id: ^rid, outcome: "started", old_version: "2.1.292"}}, 2_000

    assert_push "request", %{"request_id" => req, "op" => "restart_seat", "args" => %{"session_id" => sid, "profile" => nil}}, 2_000
    assert sid == s.claude_session_id
    # The seat comes back on its own row (the same conversation), on 2.1.296.
    Repo.update_all(from(x in Session, where: x.id == ^s.id), set: [client_version: "2.1.296", updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)])
    Phoenix.ChannelTest.push(ctx.chan, "reply", %{"request_id" => req, "ok" => true, "result" => %{"action" => "restart", "target_version" => "2.1.296", "killed" => false}})

    sid_row = s.id
    assert_receive {"seat_restart", %{restart_id: ^rid, outcome: "restarted", new_version: "2.1.296", new_session_id: ^sid_row, note: nil}}, 5_000
  end

  test "a seat that does not register again is failed, not restarted", ctx do
    Application.put_env(:claudiverse_server, :restart_register_ms, 1_000)
    on_exit(fn -> Application.delete_env(:claudiverse_server, :restart_register_ms) end)
    # Its row was registered before the restart and nothing touches it after.
    s = seat!(ctx, %{title: "gone"})
    Repo.update_all(from(x in Session, where: x.id == ^s.id), set: [updated_at: ~N[2026-01-01 00:00:00]])
    t = restart(ctx, s, %{})
    answer_plan(ctx.chan)
    assert %{"restart_id" => rid} = json_response(Task.await(t), 202)
    assert_push "request", %{"request_id" => req, "op" => "restart_seat"}, 2_000
    Phoenix.ChannelTest.push(ctx.chan, "reply", %{"request_id" => req, "ok" => true, "result" => %{"action" => "restart", "target_version" => "2.1.296"}})
    assert_receive {"seat_restart", %{restart_id: ^rid, outcome: "failed", reason_code: "not_registered", new_session_id: nil}}, 5_000
  end

  test "a seat its machine could not start again is skipped, never stopped: max_seats", ctx do
    s = seat!(ctx)
    t = bulk(ctx, %{})
    assert_push "request", %{"request_id" => rid, "op" => "restart_plan"}
    Phoenix.ChannelTest.push(ctx.chan, "reply", %{"request_id" => rid, "ok" => false, "code" => "limit",
      "error" => "would exceed max_seats (10): this machine already runs 10 app-started seats"})
    sid = s.id
    assert %{"seats" => [%{"session_id" => ^sid, "action" => "skip", "reason_code" => "max_seats", "reason" => "would exceed max_seats (10)" <> _}]} =
             json_response(Task.await(t), 202)
    refute_push "request", %{"op" => "restart_seat"}, 500
  end

  test "a dry run counts the places the seats planned before it would take on the same machine", ctx do
    seats = for _ <- 1..3, do: seat!(ctx)
    # One of them is the agent's own (its place back); the other two take places.
    own = hd(seats).claude_session_id
    t = bulk(ctx, %{"dry_run" => true})
    # In whatever order they are planned, each sees the places taken before it.
    Enum.reduce(1..3, 0, fn _, taken ->
      assert_push "request", %{"request_id" => rid, "op" => "restart_plan", "args" => %{"session_id" => sid, "taking" => taking}}
      assert taking == taken
      takes = sid != own
      Phoenix.ChannelTest.push(ctx.chan, "reply", %{"request_id" => rid, "ok" => true,
        "result" => %{"action" => "restart", "via" => "spawn", "takes_place" => takes, "argv" => [], "env" => []}})
      if takes, do: taken + 1, else: taken
    end)
    seats = json_response(Task.await(t), 200)["seats"]
    assert Enum.all?(seats, &(&1["action"] == "restart" and not Map.has_key?(&1, "takes_place")))
  end

  test "refused by its machine at the restart, before the stop: skipped, not failed", ctx do
    s = seat!(ctx)
    t = restart(ctx, s, %{})
    answer_plan(ctx.chan)
    assert %{"restart_id" => rid} = json_response(Task.await(t), 202)
    assert_push "request", %{"request_id" => req, "op" => "restart_seat"}, 2_000
    Phoenix.ChannelTest.push(ctx.chan, "reply", %{"request_id" => req, "ok" => false, "code" => "limit",
      "error" => "would exceed max_seats (10): this machine already runs 10 app-started seats"})
    assert_receive {"seat_restart", %{restart_id: ^rid, outcome: "skipped", reason_code: "max_seats"}}, 5_000
    assert Repo.get!(Session, s.id).status == :running
  end

  test "stopped and not started again: failed, with the machine's resume command, and its row ended", ctx do
    s = seat!(ctx)
    t = restart(ctx, s, %{})
    answer_plan(ctx.chan)
    assert %{"restart_id" => rid} = json_response(Task.await(t), 202)
    assert_push "request", %{"request_id" => req, "op" => "restart_seat"}, 2_000
    why = "w1 was STOPPED, and did not start again (tried twice): lorem. Bring it back with: cd /srv/a && claude --resume #{s.claude_session_id}"
    Phoenix.ChannelTest.push(ctx.chan, "reply", %{"request_id" => req, "ok" => false, "code" => "not_restarted", "error" => why})
    assert_receive {"seat_restart", %{restart_id: ^rid, outcome: "failed", reason_code: "not_restarted", reason: ^why}}, 5_000
    assert Repo.get!(Session, s.id).status == :stopped
  end

  test "the mode sent is the one its room last heard; none heard, none sent (the row's column is only its default)", ctx do
    s = seat!(ctx, %{permission_mode: "default"})
    t = restart(ctx, s, %{"dry_run" => true})
    assert %{"mode" => nil} = answer_plan(ctx.chan)
    Task.await(t)

    {:ok, pid} = ClaudiverseServer.Sessions.Supervisor.start_room(s.id, owner_id: ctx.user.id)
    :sys.replace_state(pid, &%{&1 | permission_mode: "plan"})
    t = restart(ctx, s, %{"dry_run" => true})
    assert %{"mode" => "plan"} = answer_plan(ctx.chan)
    Task.await(t)
  end

  test "a seat in a plain terminal is adopted, and the result says its old window shows the exited claude", ctx do
    s = seat!(ctx)
    t = restart(ctx, s, %{})
    answer_plan(ctx.chan, "adopt")
    assert %{"seat" => %{"action" => "adopt"}} = json_response(Task.await(t), 202)
    assert_push "request", %{"request_id" => req, "op" => "restart_seat"}, 2_000
    Repo.update_all(from(x in Session, where: x.id == ^s.id), set: [client_version: "2.1.296", updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)])
    Phoenix.ChannelTest.push(ctx.chan, "reply", %{"request_id" => req, "ok" => true,
      "result" => %{"action" => "adopt", "target_version" => "2.1.296", "note" => "the old terminal window is left showing the exited claude"}})
    assert_receive {"seat_restart", %{outcome: "adopted", note: "the old terminal window is left showing the exited claude"}}, 5_000
  end

  test "a profile's seat is restarted by its profile", ctx do
    {:ok, p} = Repo.insert(%Profile{user_id: ctx.user.id, name: "ipsum-admin", machine: "m5", folder: "/srv/a", runtime: "stock+mod",
                                    permission_mode: "auto", model: "claude-opus-5-5[1m]", effort: "high", revision: 1, mcp: []})
    s = seat!(ctx, %{title: "ipsum-admin", profile_id: p.id, origin: "profile"})
    t = restart(ctx, s, %{"dry_run" => true})
    args = answer_plan(ctx.chan)
    assert %{"profile" => %{"name" => "ipsum-admin", "runtime" => "stock+mod", "effort" => "high", "model" => "claude-opus-5-5[1m]"}} = args
    assert json_response(Task.await(t), 200)
  end

  test "protected: a bulk restart leaves it out unless named; one seat needs confirm_protected", ctx do
    {:ok, p} = Repo.insert(%Profile{user_id: ctx.user.id, name: "ceo", machine: "m5", folder: "/srv/a", runtime: "stock+mod",
                                    permission_mode: "auto", revision: 1, mcp: [], protected: true})
    s = seat!(ctx, %{title: "ceo", profile_id: p.id})

    assert %{"seats" => [%{"action" => "skip", "reason_code" => "protected", "protected" => true}]} =
             json_response(Task.await(bulk(ctx, %{"dry_run" => true})), 200)
    assert %{"reason_code" => "protected"} = json_response(Task.await(restart(ctx, s, %{})), 409)

    t = bulk(ctx, %{"dry_run" => true, "session_ids" => [s.id]})
    answer_plan(ctx.chan)
    assert %{"seats" => [%{"action" => "restart"}]} = json_response(Task.await(t), 200)

    t = restart(ctx, s, %{"dry_run" => true, "confirm_protected" => true})
    answer_plan(ctx.chan)
    assert %{"seat" => %{"action" => "restart"}} = json_response(Task.await(t), 200)

    assert [%{"protected" => true}] = as(ctx.api) |> get("/api/sessions?title=ceo") |> json_response(200) |> Map.fetch!("sessions")
  end

  test "a paused fleet is left out by default, and in when asked", ctx do
    :ok = Fleets.set_paused(ctx.user.id, "lorem-fleet", true)
    seat!(ctx, %{fleet: "lorem-fleet"})

    assert %{"seats" => [%{"reason_code" => "paused"}]} = json_response(Task.await(bulk(ctx, %{"dry_run" => true})), 200)
    t = bulk(ctx, %{"dry_run" => true, "exclude_paused" => false})
    answer_plan(ctx.chan)
    assert %{"seats" => [%{"action" => "restart"}]} = json_response(Task.await(t), 200)

    # (Runner slots kept in memory by other tests may list fleets of their own here.)
    fleets = as(ctx.app) |> get("/api/fleets") |> json_response(200) |> Map.fetch!("fleets")
    assert %{"paused" => true} = Enum.find(fleets, &(&1["fleet"] == "lorem-fleet"))
    assert %{"paused" => false} = as(ctx.app) |> patch("/api/fleets/lorem-fleet", %{"paused" => false}) |> json_response(200)
    assert as(ctx.api) |> patch("/api/fleets/lorem-fleet", %{"paused" => true}) |> json_response(403)
  end

  test "session_ids restarts exactly those; exclude_session_ids and fleet filters leave seats out", ctx do
    a = seat!(ctx, %{fleet: "ipsum-fleet"})
    b = seat!(ctx, %{fleet: "ipsum-fleet"})
    c = seat!(ctx, %{fleet: "other"})

    t = bulk(ctx, %{"dry_run" => true, "session_ids" => [a.id]})
    answer_plan(ctx.chan)
    seats = json_response(Task.await(t), 200)["seats"]
    assert %{"action" => "restart"} = Enum.find(seats, &(&1["session_id"] == a.id))
    assert %{"reason_code" => "excluded"} = Enum.find(seats, &(&1["session_id"] == b.id))
    assert %{"reason_code" => "excluded"} = Enum.find(seats, &(&1["session_id"] == c.id))

    t = bulk(ctx, %{"dry_run" => true, "exclude_session_ids" => [a.id], "fleets" => ["ipsum-fleet"]})
    answer_plan(ctx.chan)
    seats = json_response(Task.await(t), 200)["seats"]
    assert %{"reason_code" => "excluded"} = Enum.find(seats, &(&1["session_id"] == a.id))
    assert %{"action" => "restart"} = Enum.find(seats, &(&1["session_id"] == b.id))
    assert %{"reason_code" => "fleet"} = Enum.find(seats, &(&1["session_id"] == c.id))
  end

  test "only_outdated leaves out a seat already on the version it would get", ctx do
    seat!(ctx, %{client_version: "2.1.296"})
    assert %{"seats" => [%{"reason_code" => "up_to_date"}]} = json_response(Task.await(bulk(ctx, %{"dry_run" => true, "only_outdated" => true})), 200)
  end

  test "app-only" , ctx do
    s = seat!(ctx)
    assert as(ctx.api) |> post("/api/sessions/#{s.id}/restart", %{}) |> json_response(403)
    assert as(ctx.api) |> post("/api/hosts/restart_idle", %{}) |> json_response(403)
  end

  test "an open question: the last AskUserQuestion with no answer after it" do
    ask = %{"type" => "assistant", "message" => %{"content" => [%{"type" => "tool_use", "name" => "AskUserQuestion", "id" => "q1"}]}}
    answer = %{"type" => "user", "message" => %{"content" => [%{"type" => "tool_result", "tool_use_id" => "q1"}]}}
    assert Restarts.open_question?([ask])
    refute Restarts.open_question?([ask, answer])
    refute Restarts.open_question?([%{"type" => "assistant", "message" => %{"content" => "text"}}])
  end
end
