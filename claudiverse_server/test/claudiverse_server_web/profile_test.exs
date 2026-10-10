defmodule ClaudiverseServerWeb.ProfileTest do
  @moduledoc """
  Seat profiles: CRUD (super token), revision-checked edits, derived status,
  start/stop/restart relayed to the machine's agent (the test process plays
  it over a real channel), registration filled from the profile, fleets'
  members and the hosts' choices.
  """
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures
  import Ecto.Query
  import Phoenix.ChannelTest, except: [connect: 2, connect: 3]

  @endpoint ClaudiverseServerWeb.Endpoint

  alias ClaudiverseServer.{Accounts, Hosts, Profiles, Repo}
  alias ClaudiverseServerWeb.{HostChannel, UserSocket}

  @uuid "0b5e4c2a-1111-4222-8333-944455556666"

  setup do
    {user, api} = user_with_token()
    app = Accounts.create_user_api_token(user, "app")
    super_token = Accounts.create_user_api_token(user, "super", "desktop")
    {:ok, host} = Accounts.create_host_token(user, "m5")
    Application.put_env(:claudiverse_server, :host_adopt_timeout_ms, 1_000)
    :sys.replace_state(Hosts, fn st -> %{st | last_spawn: %{}} end)
    on_exit(fn -> Application.delete_env(:claudiverse_server, :host_adopt_timeout_ms) end)
    %{user: user, api: api, app: app, super: super_token, host: host}
  end

  defp agent!(ctx, join \\ %{}) do
    {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{"token" => ctx.host})
    {:ok, _, chan} = subscribe_and_join(socket, HostChannel, "host:m5", Map.merge(%{"roots" => ["/srv"], "version" => "0.7.0"}, join))
    chan
  end

  defp as(token), do: build_conn() |> put_req_header("authorization", "Bearer " <> token)

  @base %{"name" => "ipsum-admin", "machine" => "m5", "folder" => "/srv/ipsum", "fleet" => "ipsum-fleet", "role" => "orchestrator",
          "can_notify" => true, "permission_mode" => "auto", "mcp" => ["claudiverse"]}

  defp profile!(ctx, attrs \\ %{}) do
    as(ctx.super) |> post("/api/profiles", Map.merge(@base, attrs)) |> json_response(201) |> Map.fetch!("profile")
  end

  # --- CRUD ------------------------------------------------------------------

  test "only the super token creates, edits and deletes; any token reads", ctx do
    for t <- [ctx.api, ctx.app] do
      assert as(t) |> post("/api/profiles", @base) |> json_response(403)
    end

    p = profile!(ctx)
    assert %{"name" => "ipsum-admin", "revision" => 1, "status" => "offline", "seat" => nil, "runtime" => "stock+mod"} = p
    assert [%{"name" => "ipsum-admin"}] = as(ctx.api) |> get("/api/profiles") |> json_response(200) |> Map.fetch!("profiles")

    for t <- [ctx.api, ctx.app] do
      assert as(t) |> patch("/api/profiles/#{p["id"]}", %{revision: 1, model: "x"}) |> json_response(403)
      assert as(t) |> delete("/api/profiles/#{p["id"]}") |> json_response(403)
    end
  end

  test "a name is unique per user and validated; folder, mode and resume are checked", ctx do
    profile!(ctx)
    assert %{"errors" => %{"name" => _}} = as(ctx.super) |> post("/api/profiles", @base) |> json_response(422)
    assert %{"errors" => %{"name" => _}} = as(ctx.super) |> post("/api/profiles", %{@base | "name" => "a b"}) |> json_response(422)
    assert %{"errors" => %{"folder" => _}} = as(ctx.super) |> post("/api/profiles", %{@base | "name" => "b", "folder" => "srv"}) |> json_response(422)

    assert %{"errors" => %{"permission_mode" => _}} =
             as(ctx.super) |> post("/api/profiles", %{@base | "name" => "c", "permission_mode" => "bypassPermissions"}) |> json_response(422)

    assert %{"errors" => %{"resume" => _}} =
             as(ctx.super) |> post("/api/profiles", Map.merge(@base, %{"name" => "d", "resume" => "yesterday"})) |> json_response(422)

    assert %{"errors" => %{"mcp" => _}} =
             as(ctx.super) |> post("/api/profiles", Map.merge(@base, %{"name" => "e", "mcp" => ["node /evil.js"]})) |> json_response(422)

    assert %{"errors" => %{"runtime" => _}} =
             as(ctx.super) |> post("/api/profiles", Map.merge(@base, %{"name" => "g", "runtime" => "/bin/sh"})) |> json_response(422)

    assert profile!(ctx, %{"name" => "f", "resume" => @uuid})
    # A runtime given explicitly is validated like any other field.
    assert %{"runtime" => "stock+mod"} = profile!(ctx, %{"name" => "h", "runtime" => "stock+mod"})
  end

  test "an edit needs the revision it read; a stale one is 409 with the current profile", ctx do
    p = profile!(ctx)
    path = "/api/profiles/#{p["id"]}"

    assert as(ctx.super) |> patch(path, %{model: "opus"}) |> json_response(400)
    assert %{"profile" => %{"revision" => 2, "model" => "opus"}} = as(ctx.super) |> patch(path, %{revision: 1, model: "opus"}) |> json_response(200)
    assert %{"profile" => %{"revision" => 2, "model" => "opus"}} = as(ctx.super) |> patch(path, %{revision: 1, model: "sonnet"}) |> json_response(409)
    assert %{"errors" => %{"name" => _}} = as(ctx.super) |> patch(path, %{revision: 2, name: "other"}) |> json_response(422)
    assert %{"profile" => %{"revision" => 3, "fleet" => nil}} = as(ctx.super) |> patch(path, %{revision: 2, fleet: nil}) |> json_response(200)
  end

  test "a profile with a running seat cannot be deleted", ctx do
    p = profile!(ctx)
    s = session_fixture(ctx.user, %{title: "ipsum-admin", profile_id: p["id"]})
    assert as(ctx.super) |> delete("/api/profiles/#{p["id"]}") |> json_response(409)
    Repo.update!(Ecto.Changeset.change(s, status: :stopped))
    assert as(ctx.super) |> delete("/api/profiles/#{p["id"]}") |> response(204)
  end

  # --- status ------------------------------------------------------------------

  test "status: offline, stopped, running with restart_needed", ctx do
    p = profile!(ctx)
    assert %{"status" => "offline"} = as(ctx.api) |> get("/api/profiles/#{p["id"]}") |> json_response(200) |> Map.fetch!("profile")

    agent!(ctx)
    assert %{"status" => "stopped"} = as(ctx.api) |> get("/api/profiles/#{p["id"]}") |> json_response(200) |> Map.fetch!("profile")

    s = session_fixture(ctx.user, %{title: "ipsum-admin", profile_id: p["id"], profile_revision: 1})
    assert %{"status" => "running", "seat" => seat, "restart_needed" => false} =
             as(ctx.api) |> get("/api/profiles/#{p["id"]}") |> json_response(200) |> Map.fetch!("profile")
    assert seat == s.id

    as(ctx.super) |> patch("/api/profiles/#{p["id"]}", %{revision: 1, effort: "high"}) |> json_response(200)
    assert %{"status" => "running", "restart_needed" => true} = as(ctx.api) |> get("/api/profiles/#{p["id"]}") |> json_response(200) |> Map.fetch!("profile")
  end

  # --- start / stop / restart -----------------------------------------------------

  test "start is app-only, relays start_profile with names only, and records the outcome", ctx do
    p = profile!(ctx, %{"model" => "claude-opus-5-5", "effort" => "high"})
    chan = agent!(ctx)
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, Hosts.events_topic(ctx.user.id))

    assert as(ctx.api) |> post("/api/profiles/#{p["id"]}/start") |> json_response(403)
    assert %{"profile" => %{"status" => "starting", "last_start" => %{"requested_at" => starting_at, "at" => starting_at}}} =
             as(ctx.app) |> post("/api/profiles/#{p["id"]}/start") |> json_response(202)
    # (A start that finishes within the same second would hide a lost requested_at.)
    Process.sleep(1_100)

    assert_push "request", %{"request_id" => rid, "op" => "start_profile", "args" => args}
    assert %{"name" => "ipsum-admin", "profile_id" => id, "revision" => 1, "folder" => "/srv/ipsum", "runtime" => "stock+mod",
             "model" => "claude-opus-5-5", "effort" => "high", "mode" => "auto", "mcp" => ["claudiverse"], "resume" => nil, "resume_policy" => "latest", "pooled" => true} = args
    assert id == p["id"]

    # The seat registers through the mod, reporting only its profile.
    seat = as(ctx.api) |> post("/api/sessions", %{title: "ipsum-admin", claude_session_id: @uuid, profile_id: id, profile_revision: 1})
           |> json_response(201) |> get_in(["session", "id"])
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => true, "result" => %{"title" => "ipsum-admin"}})

    assert_receive {"profile", %{"op" => "start", "profile" => %{status: "running", last_start: %{"outcome" => "started", "seat" => ^seat} = last}}}, 3_000
    # The outcome keeps the time the start was asked for.
    assert last["requested_at"] == starting_at

    row = Repo.get!(ClaudiverseServer.Sessions.Session, seat)
    assert %{origin: "profile", fleet: "ipsum-fleet", can_notify: true, host: "m5", tmux_session: "ipsum-admin", profile_revision: 1} = row

    assert as(ctx.app) |> post("/api/profiles/#{p["id"]}/start") |> json_response(409)
  end

  test "a resumed seat re-registering on its old row is adopted as started", ctx do
    p = profile!(ctx)
    old = session_fixture(ctx.user, %{title: "ipsum-admin", claude_session_id: @uuid, status: :stopped})
    Repo.update_all(from(s in ClaudiverseServer.Sessions.Session, where: s.id == ^old.id),
      set: [inserted_at: ~N[2026-09-23 20:31:40], updated_at: ~N[2026-09-23 20:31:40]])
    chan = agent!(ctx)
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, Hosts.events_topic(ctx.user.id))
    as(ctx.app) |> post("/api/profiles/#{p["id"]}/start") |> json_response(202)
    assert_push "request", %{"request_id" => rid, "op" => "start_profile"}

    # The resumed seat registers with the same Claude session id: the old row is reused.
    seat = as(ctx.api) |> post("/api/sessions", %{title: "ipsum-admin", claude_session_id: @uuid, profile_id: p["id"], profile_revision: 1})
           |> json_response(201) |> get_in(["session", "id"])
    assert seat == old.id
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => true, "result" => %{"title" => "ipsum-admin"}})
    assert_receive {"profile", %{"op" => "start", "profile" => %{last_start: %{"outcome" => "started", "seat" => ^seat, "reason" => nil}}}}, 3_000
  end

  test "a refusal by the agent is recorded as failed with its reason", ctx do
    p = profile!(ctx)
    chan = agent!(ctx)
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, Hosts.events_topic(ctx.user.id))
    as(ctx.app) |> post("/api/profiles/#{p["id"]}/start") |> json_response(202)
    assert_push "request", %{"request_id" => rid}
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => false, "code" => "outside_roots", "error" => "/srv/ipsum is outside the roots"})

    assert_receive {"profile", %{"op" => "start", "profile" => %{status: "failed", last_start: %{"outcome" => "refused", "reason" => "outside_roots: " <> _}}}}, 3_000
  end

  test "a started seat that never registered reads unregistered until stopped", ctx do
    p = profile!(ctx)
    chan = agent!(ctx)
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, Hosts.events_topic(ctx.user.id))
    as(ctx.app) |> post("/api/profiles/#{p["id"]}/start") |> json_response(202)
    assert_push "request", %{"request_id" => rid, "op" => "start_profile"}
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => true, "result" => %{"title" => "ipsum-admin"}})
    assert_receive {"profile", %{"op" => "start", "profile" => %{status: "unregistered", last_start: %{"outcome" => "started", "seat" => nil}}}}, 3_000

    task = Task.async(fn -> as(ctx.app) |> post("/api/profiles/#{p["id"]}/stop") |> json_response(200) end)
    assert_push "request", %{"request_id" => rid2, "op" => "stop"}
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid2, "ok" => true, "result" => %{}})
    Task.await(task)
    assert %{"status" => "stopped", "last_start" => %{"stopped_at" => _}} =
             as(ctx.api) |> get("/api/profiles/#{p["id"]}") |> json_response(200) |> Map.fetch!("profile")
  end

  test "start on an offline machine is 504 and recorded", ctx do
    p = profile!(ctx)
    assert as(ctx.app) |> post("/api/profiles/#{p["id"]}/start") |> json_response(504)
    assert %{"last_start" => %{"outcome" => "offline"}} = as(ctx.api) |> get("/api/profiles/#{p["id"]}") |> json_response(200) |> Map.fetch!("profile")
  end

  test "resume latest continues the newest conversation a seat of the profile had", ctx do
    p = profile!(ctx)
    session_fixture(ctx.user, %{title: "ipsum-admin", profile_id: p["id"], claude_session_id: "11111111-1111-4111-8111-111111111111", status: :stopped})
    # A resumed seat's row: a placeholder claude_session_id, the conversation set on adoption.
    resumed = session_fixture(ctx.user, %{title: "ipsum-admin", profile_id: p["id"], claude_session_id: "x", status: :stopped})
    Repo.update!(Ecto.Changeset.change(resumed, conversation_id: @uuid))
    session_fixture(ctx.user, %{title: "ipsum-admin", claude_session_id: "22222222-2222-4222-8222-222222222222", status: :stopped})
    agent!(ctx)
    as(ctx.app) |> post("/api/profiles/#{p["id"]}/start") |> json_response(202)
    assert_push "request", %{"op" => "start_profile", "args" => %{"resume" => @uuid}}
  end

  # A mod seat has no socket whose closing ends its row; the confirmed stop does.
  test "stop closes the tmux session named after the profile and ends the seat's row at once", ctx do
    p = profile!(ctx)
    chan = agent!(ctx)
    seat = as(ctx.api) |> post("/api/sessions", %{title: "ipsum-admin", profile_id: p["id"], profile_revision: 1}) |> json_response(201) |> get_in(["session", "id"])
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, Hosts.events_topic(ctx.user.id))

    task = Task.async(fn -> as(ctx.app) |> post("/api/profiles/#{p["id"]}/stop") |> json_response(200) end)
    assert_push "request", %{"request_id" => rid, "op" => "stop", "args" => %{"title" => "ipsum-admin"}}
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => true, "result" => %{}})
    assert %{"ok" => true} = Task.await(task)

    assert %{status: :stopped} = Repo.get!(ClaudiverseServer.Sessions.Session, seat)
    assert_receive {"profile", %{"op" => "stopped", "profile" => %{status: "stopped", seat: nil}}}
  end

  test "a refused stop leaves the seat running", ctx do
    p = profile!(ctx)
    chan = agent!(ctx)
    seat = session_fixture(ctx.user, %{title: "ipsum-admin", profile_id: p["id"]})
    task = Task.async(fn -> as(ctx.app) |> post("/api/profiles/#{p["id"]}/stop") |> json_response(403) end)
    assert_push "request", %{"request_id" => rid, "op" => "stop"}
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => false, "code" => "outside_roots", "error" => "no"})
    Task.await(task)
    assert %{status: :running} = Repo.reload!(seat)
  end

  test "restart of a running seat stops it, then starts the current revision", ctx do
    p = profile!(ctx)
    chan = agent!(ctx)
    seat = as(ctx.api) |> post("/api/sessions", %{title: "ipsum-admin", profile_id: p["id"], profile_revision: 1}) |> json_response(201) |> get_in(["session", "id"])
    as(ctx.super) |> patch("/api/profiles/#{p["id"]}", %{revision: 1, effort: "high"}) |> json_response(200)

    task = Task.async(fn -> as(ctx.app) |> post("/api/profiles/#{p["id"]}/restart") |> json_response(202) end)
    assert_push "request", %{"request_id" => rid, "op" => "stop"}
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => true, "result" => %{}})
    assert %{"profile" => %{"status" => "starting"}} = Task.await(task)
    assert_push "request", %{"op" => "start_profile", "args" => %{"revision" => 2, "effort" => "high"}}
    assert %{status: :stopped} = Repo.get!(ClaudiverseServer.Sessions.Session, seat)
  end

  test "restart of a seat that is not running starts it", ctx do
    p = profile!(ctx)
    chan = agent!(ctx)
    task = Task.async(fn -> as(ctx.app) |> post("/api/profiles/#{p["id"]}/restart") |> json_response(202) end)
    assert_push "request", %{"request_id" => rid, "op" => "stop"}
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => false, "code" => "not_found", "error" => "no seat named ipsum-admin runs here"})
    assert %{"profile" => %{"status" => "starting"}} = Task.await(task)
    assert_push "request", %{"op" => "start_profile"}
  end

  # --- rename ---------------------------------------------------------------------------

  alias ClaudiverseServer.Forum.{Channel, Handoff, Post, Subscription}
  alias ClaudiverseServer.Notifications.Router
  alias ClaudiverseServer.Sessions.Session

  defp rename(ctx, p, body), do: as(ctx.super) |> post("/api/profiles/#{p["id"]}/rename", body)

  test "rename is super-only, checks the revision, the format and taken names", ctx do
    p = profile!(ctx)
    profile!(ctx, %{"name" => "other"})

    assert rename(%{ctx | super: ctx.app}, p, %{revision: 1, name: "x"}) |> json_response(403)
    assert rename(ctx, p, %{name: "x"}) |> json_response(400)
    assert %{"code" => "stale", "profile" => %{"name" => "ipsum-admin"}} = rename(ctx, p, %{revision: 7, name: "x"}) |> json_response(409)
    assert %{"errors" => %{"name" => _}} = rename(ctx, p, %{revision: 1, name: "a b"}) |> json_response(422)
    assert %{"code" => "name_taken"} = rename(ctx, p, %{revision: 1, name: "other"}) |> json_response(409)

    session_fixture(ctx.user, %{title: "manual-seat"})
    assert %{"code" => "name_taken"} = rename(ctx, p, %{revision: 1, name: "manual-seat"}) |> json_response(409)

    Repo.insert!(%Handoff{role: "old-seat", body: "x"})
    assert %{"code" => "name_taken"} = rename(ctx, p, %{revision: 1, name: "old-seat"}) |> json_response(409)

    Repo.insert!(%ClaudiverseServer.Tasks.Task{fleet: "ipsum-fleet", lane: "l", title: "t", created_by: "x", state: "CLAIMED", claimed_by: "ipsum-admin"})
    assert %{"code" => "claimed_task", "task_ids" => [_]} = rename(ctx, p, %{revision: 1, name: "ceo"}) |> json_response(409)
    assert %{name: "ipsum-admin", revision: 1} = Repo.get!(Profiles.Profile, p["id"])
  end

  test "a stopped profile is renamed at once, and what is keyed by its title moves", ctx do
    p = profile!(ctx)
    old_row = session_fixture(ctx.user, %{title: "ipsum-admin", profile_id: p["id"], status: :stopped})
    Repo.update!(Ecto.Changeset.change(old_row, display_title: "An old auto-title"))
    unrelated = session_fixture(ctx.user, %{title: "ipsum-admin", status: :stopped})

    ch = Repo.insert!(%Channel{slug: "rn-#{System.unique_integer([:positive])}", title: "c"})
    Repo.insert!(%Subscription{channel_id: ch.id, subscriber_title: "ipsum-admin"})
    Repo.insert!(%Handoff{role: "ipsum-admin", body: "state"})
    open = Repo.insert!(%Post{channel_id: ch.id, author: "w", body: "b", title: "t", status: "active", owner: "ipsum-admin"})
    done = Repo.insert!(%Post{channel_id: ch.id, author: "ipsum-admin", body: "b", title: "t", status: "done", owner: "ipsum-admin"})

    for t <- ["ceo", "ipsum-admin", "watcher"], do: Router.unsubscribe(t)
    Router.subscribe("ipsum-admin", nil, ["w1"])
    Router.subscribe("watcher", nil, ["ipsum-admin", "w2"])

    assert %{"profile" => %{"name" => "ceo", "revision" => 2}, "moved" => moved} =
             rename(ctx, p, %{revision: 1, name: "ceo"}) |> json_response(200)

    assert %{"past_seats" => 1, "forum_subscriptions" => 1, "handoffs" => 1, "open_tasks" => 1, "watch_lists" => 1, "watchers" => 1} = moved
    assert %{title: "ceo", display_title: nil} = Repo.reload!(old_row)
    assert %{title: "ipsum-admin"} = Repo.reload!(unrelated)
    assert Repo.get_by(Handoff, role: "ceo")
    assert %{owner: "ceo"} = Repo.reload!(open)
    assert %{owner: "ipsum-admin", author: "ipsum-admin"} = Repo.reload!(done)
    assert Repo.get_by(Subscription, subscriber_title: "ceo")

    assert Router.watching("ceo") == ["w1"]
    assert Router.watching("ipsum-admin") == []
    assert Enum.sort(Router.watching("watcher")) == ["ceo", "w2"]
    assert %{"ceo" => ["w1"]} = ClaudiverseServer.Sessions.list_subscriptions()
    refute Map.has_key?(ClaudiverseServer.Sessions.list_subscriptions(), "ipsum-admin")

    # The Router is global: leave it as found, while the sandbox is still ours.
    for t <- ["ceo", "watcher"], do: Router.unsubscribe(t)
    Router.watching("ceo")
  end

  test "a running seat is stopped, renamed and started again on its conversation", ctx do
    # resume "new" would start a fresh conversation; a rename must not.
    p = profile!(ctx, %{"resume" => "new"})
    chan = agent!(ctx)
    seat = session_fixture(ctx.user, %{title: "ipsum-admin", profile_id: p["id"], tmux_session: "ipsum-admin", claude_session_id: @uuid})

    task = Task.async(fn -> rename(ctx, p, %{revision: 1, name: "ceo"}) |> json_response(202) end)
    assert_push "request", %{"request_id" => rid, "op" => "stop", "args" => %{"title" => "ipsum-admin"}}
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => true, "result" => %{}})
    assert %{"profile" => %{"name" => "ceo", "status" => "starting"}, "moved" => %{"past_seats" => 1}} = Task.await(task)

    assert_push "request", %{"op" => "start_profile", "args" => %{"name" => "ceo", "resume" => @uuid, "resume_policy" => "latest"}}
    assert %{status: :stopped, title: "ceo", tmux_session: "ceo"} = Repo.get!(Session, seat.id)
  end

  test "a busy seat is not renamed, and a refused stop leaves the name", ctx do
    p = profile!(ctx)
    chan = agent!(ctx)
    seat = session_fixture(ctx.user, %{title: "ipsum-admin", profile_id: p["id"]})
    {:ok, _} = ClaudiverseServer.Sessions.Supervisor.start_room(seat.id, owner_id: ctx.user.id)
    :sys.replace_state({:via, Registry, {ClaudiverseServer.Sessions.Registry, seat.id}}, &%{&1 | idle: false, readiness_known: true})
    assert %{"code" => "busy"} = rename(ctx, p, %{revision: 1, name: "ceo"}) |> json_response(409)

    :sys.replace_state({:via, Registry, {ClaudiverseServer.Sessions.Registry, seat.id}}, &%{&1 | idle: true})
    task = Task.async(fn -> rename(ctx, p, %{revision: 1, name: "ceo"}) |> json_response(403) end)
    assert_push "request", %{"request_id" => rid, "op" => "stop"}
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => false, "code" => "outside_roots", "error" => "no"})
    Task.await(task)
    assert %{name: "ipsum-admin"} = Repo.get!(Profiles.Profile, p["id"])
    assert %{status: :running, title: "ipsum-admin"} = Repo.reload!(seat)
  end

  # --- autostart ---------------------------------------------------------------------

  test "an agent coming online starts its stopped autostart profiles, and only those", ctx do
    Application.put_env(:claudiverse_server, :host_spawn_interval_ms, 50)
    on_exit(fn -> Application.delete_env(:claudiverse_server, :host_spawn_interval_ms) end)
    profile!(ctx, %{"name" => "auto-a", "autostart" => true})
    profile!(ctx, %{"name" => "manual-b"})
    running = profile!(ctx, %{"name" => "auto-running", "autostart" => true})
    session_fixture(ctx.user, %{title: "auto-running", profile_id: running["id"]})
    elsewhere = profile!(ctx, %{"name" => "auto-elsewhere", "autostart" => true, "machine" => "m1"})

    agent!(ctx)
    assert_push "request", %{"op" => "start_profile", "args" => %{"name" => "auto-a"}}, 2_000
    # Wider than the gap between autostarts (interval + 500 ms).
    refute_push "request", %{"op" => "start_profile"}, 2_000
    # Another machine's profile is not even tried (a try would record "offline").
    assert %{"last_start" => nil} = as(ctx.api) |> get("/api/profiles/#{elsewhere["id"]}") |> json_response(200) |> Map.fetch!("profile")
  end

  test "a profile whose last start failed recently is not retried on every reconnect", ctx do
    p = profile!(ctx, %{"name" => "auto-broken", "autostart" => true})
    recent = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    Repo.update_all(from(x in ClaudiverseServer.Profiles.Profile, where: x.id == ^p["id"]),
      set: [last_start: %{"outcome" => "failed", "at" => recent, "reason" => "spawn_failed: exited"}])

    agent!(ctx)
    refute_push "request", %{"op" => "start_profile"}, 500

    # Control: the same failure 11 minutes ago is retried.
    old = DateTime.utc_now() |> DateTime.add(-660) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    Repo.update_all(from(x in ClaudiverseServer.Profiles.Profile, where: x.id == ^p["id"]),
      set: [last_start: %{"outcome" => "failed", "at" => old, "reason" => "spawn_failed: exited"}])
    agent!(ctx)
    assert_push "request", %{"op" => "start_profile", "args" => %{"name" => "auto-broken"}}, 2_000
  end

  # --- registration, whoami, fleets, hosts -------------------------------------------

  test "registration: the profile wins; another user's profile id is dropped", ctx do
    p = profile!(ctx)

    s = as(ctx.api) |> post("/api/sessions", %{title: "ipsum-admin", profile_id: p["id"], fleet: "other", notify: false}) |> json_response(201) |> Map.fetch!("session")
    row = Repo.get!(ClaudiverseServer.Sessions.Session, s["id"])
    assert %{origin: "profile", fleet: "ipsum-fleet", can_notify: true, profile_id: id} = row
    assert id == p["id"]

    {_other, other_api} = user_with_token()
    s2 = as(other_api) |> post("/api/sessions", %{title: "x", profile_id: p["id"], fleet: "mine"}) |> json_response(201) |> Map.fetch!("session")
    assert %{profile_id: nil, fleet: "mine", origin: nil} = Repo.get!(ClaudiverseServer.Sessions.Session, s2["id"])
  end

  test "whoami reports the profile id", ctx do
    p = profile!(ctx)
    session_fixture(ctx.user, %{title: "ipsum-admin", claude_session_id: @uuid, profile_id: p["id"], origin: "profile"})
    assert %{"profile_id" => id, "role" => "orchestrator"} = as(ctx.api) |> get("/api/seats/whoami?claude_session_id=#{@uuid}") |> json_response(200)
    assert id == p["id"]
  end

  test "fleets list the profiles declaring them as members", ctx do
    p = profile!(ctx)
    profile!(ctx, %{"name" => "loner", "fleet" => nil})
    # (Runners is in memory and user ids repeat across sandboxed tests, so
    # other tests' runner fleets may be listed too.)
    fleets = as(ctx.api) |> get("/api/fleets") |> json_response(200) |> Map.fetch!("fleets")
    assert %{"members" => [%{"id" => id, "name" => "ipsum-admin", "role" => "orchestrator", "machine" => "m5", "status" => "offline", "seat" => nil}]} =
             Enum.find(fleets, &(&1["fleet"] == "ipsum-fleet"))
    assert id == p["id"]
    refute Enum.any?(fleets, fn f -> Enum.any?(f["members"], &(&1["name"] == "loner")) end)
  end

  test "hosts list the choices the machine's agent offers", ctx do
    agent!(ctx, %{"modes" => ["default", "auto"], "runtimes" => [%{"name" => "stock+mod", "version" => "2.1.289"}], "mcp" => ["claudiverse", "ghidra"]})
    [m5] = as(ctx.api) |> get("/api/hosts") |> json_response(200) |> Map.fetch!("hosts")
    assert %{"modes" => ["default", "auto"], "runtimes" => [%{"name" => "stock+mod", "version" => "2.1.289"}], "mcp" => ["claudiverse", "ghidra"]} = m5
  end
end
