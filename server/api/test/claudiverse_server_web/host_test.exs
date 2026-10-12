defmodule ClaudiverseServerWeb.HostTest do
  @moduledoc """
  "New seat": host agents on host:<name> with per-host tokens, and the app's
  hosts / recent_dirs / ls / spawn endpoints relayed to them. The test process
  plays the agent over a real channel; HTTP calls run in a Task so the test
  can answer the requests they cause.
  """
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures
  import Phoenix.ChannelTest, except: [connect: 2, connect: 3]

  @endpoint ClaudiverseServerWeb.Endpoint

  alias ClaudiverseServer.{Accounts, Hosts}
  alias ClaudiverseServerWeb.{HostChannel, UserSocket}

  setup do
    {user, api} = user_with_token()
    app = Accounts.create_user_api_token(user, "app")
    {:ok, host} = Accounts.create_host_token(user, "m5")
    Application.put_env(:claudiverse_server, :host_spawn_interval_ms, 10_000)
    Application.put_env(:claudiverse_server, :host_adopt_timeout_ms, 1_000)
    # User ids repeat across sandboxed tests: forget earlier tests' spawns.
    :sys.replace_state(Hosts, fn st -> %{st | last_spawn: %{}} end)
    on_exit(fn ->
      Application.delete_env(:claudiverse_server, :host_spawn_interval_ms)
      Application.delete_env(:claudiverse_server, :host_adopt_timeout_ms)
    end)
    %{user: user, api: api, app: app, host: host}
  end

  defp agent!(ctx, name \\ "m5", roots \\ ["/srv/projects"]) do
    {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{"token" => ctx.host})
    {:ok, _, chan} = subscribe_and_join(socket, HostChannel, "host:" <> name, %{"roots" => roots, "version" => "0.1"})
    chan
  end

  # An agent that says what its plain spawn offers (0.13+).
  @spawn %{"options" => ["model", "pooled"], "pool_only" => true, "pooled" => true}
  defp agent_offering!(ctx, spawn \\ @spawn) do
    {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{"token" => ctx.host})
    {:ok, _, chan} = subscribe_and_join(socket, HostChannel, "host:m5", %{"roots" => ["/srv/projects"], "version" => "0.13.0", "spawn" => spawn})
    chan
  end

  defp as(token), do: build_conn() |> put_req_header("authorization", "Bearer " <> token)
  defp async(fun), do: Task.async(fun)

  # --- tokens ------------------------------------------------------------------

  test "a host token joins only its own host topic", ctx do
    {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{"token" => ctx.host})
    assert {:ok, _, _} = subscribe_and_join(socket, HostChannel, "host:m5", %{})
    assert {:error, _} = subscribe_and_join(socket, HostChannel, "host:m1", %{})
  end

  test "the shared seat token and the app token cannot join a host topic", ctx do
    for token <- [ctx.api, ctx.app] do
      {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{"token" => token})
      assert {:error, _} = subscribe_and_join(socket, HostChannel, "host:m5", %{})
    end
  end

  test "a host token is refused on the HTTP API and on seat and operator topics", ctx do
    assert as(ctx.host) |> get("/api/me") |> json_response(401)
    s = session_fixture(ctx.user, %{title: "x"})
    {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{"token" => ctx.host})
    assert {:error, _} = subscribe_and_join(socket, ClaudiverseServerWeb.SessionChannel, "session:#{s.id}", %{})
    assert {:error, _} = subscribe_and_join(socket, ClaudiverseServerWeb.OperatorChannel, "operator:events", %{})
  end

  # --- hosts / recent_dirs ----------------------------------------------------------

  test "hosts lists online agents and hosts with running seats", ctx do
    agent!(ctx)
    session_fixture(ctx.user, %{title: "on-m1", host: "m1"})
    session_fixture(ctx.user, %{title: "on-m5", host: "m5"})

    hosts = as(ctx.api) |> get("/api/hosts") |> json_response(200) |> Map.fetch!("hosts")
    assert %{"name" => "m1", "online" => false, "seats" => 1} = Enum.find(hosts, &(&1["name"] == "m1"))
    assert %{"name" => "m5", "online" => true, "seats" => 1, "roots" => ["/srv/projects"]} = Enum.find(hosts, &(&1["name"] == "m5"))
  end

  test "hosts lists a machine seen before that is offline now, and when it was last seen", ctx do
    chan = agent!(ctx)
    Process.unlink(chan.channel_pid)
    close(chan)

    hosts = as(ctx.app) |> get("/api/hosts") |> json_response(200) |> Map.fetch!("hosts")
    assert %{"online" => false, "seats" => 0, "last_seen_at" => seen} = Enum.find(hosts, &(&1["name"] == "m5"))
    assert {:ok, at, 0} = DateTime.from_iso8601(seen)
    assert DateTime.diff(DateTime.utc_now(), at) < 5
  end

  test "an agent coming online and going offline is announced as host on operator:events", ctx do
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, Hosts.events_topic(ctx.user.id))
    chan = agent!(ctx)
    assert_receive {"host", %{"name" => "m5", "online" => true}}, 1_000
    Process.unlink(chan.channel_pid)
    close(chan)
    assert_receive {"host", %{"name" => "m5", "online" => false, "last_seen_at" => %DateTime{}}}, 1_000
  end

  test "the operator's apps are told on operator:events when a machine comes online", ctx do
    {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{"token" => ctx.app})
    {:ok, _, _} = subscribe_and_join(socket, ClaudiverseServerWeb.OperatorChannel, "operator:events", %{})
    agent!(ctx)
    assert_push "host", %{"name" => "m5", "online" => true}
  end

  test "hosts says what each machine's spawn offers; an older agent offers nothing", ctx do
    agent_offering!(ctx)
    hosts = as(ctx.app) |> get("/api/hosts") |> json_response(200) |> Map.fetch!("hosts")
    assert %{"spawn" => %{"options" => ["model", "pooled"], "pool_only" => true, "pooled" => true}} = Enum.find(hosts, &(&1["name"] == "m5"))

    {:ok, m1} = Accounts.create_host_token(ctx.user, "m1")
    {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{"token" => m1})
    {:ok, _, _} = subscribe_and_join(socket, HostChannel, "host:m1", %{"roots" => [], "version" => "0.12.0"})
    hosts = as(ctx.app) |> get("/api/hosts") |> json_response(200) |> Map.fetch!("hosts")
    assert %{"spawn" => nil} = Enum.find(hosts, &(&1["name"] == "m1"))
  end

  test "spawn passes a model and pooling on; the model is the new seat's until it replies", ctx do
    chan = agent_offering!(ctx)
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, Hosts.events_topic(ctx.user.id))
    as(ctx.app) |> post("/api/hosts/m5/spawn", %{path: "/srv/projects/a", title: "quick", model: "claude-haiku-4-5", pooled: false})
    |> json_response(202)

    assert_push "request", %{"request_id" => rid, "op" => "spawn", "args" => %{"model" => "claude-haiku-4-5", "pooled" => false}}
    bare = session_fixture(ctx.user, %{title: "quick"})
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => true, "result" => %{"title" => "quick"}})
    assert_receive {"host_spawn", %{"ok" => true}}, 3_000
    assert %{model: "claude-haiku-4-5"} = ClaudiverseServer.Repo.reload!(bare)
  end

  test "spawn refuses a bad model or pooling, and a model the machine's agent can't apply", ctx do
    agent_offering!(ctx)

    for body <- [%{path: "/srv/projects/a", model: "haiku; rm -rf /"}, %{path: "/srv/projects/a", pooled: "yes"}] do
      assert as(ctx.app) |> post("/api/hosts/m5/spawn", body) |> json_response(400), inspect(body)
    end

    refute_push "request", _

    {:ok, m1} = Accounts.create_host_token(ctx.user, "m1")
    {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{"token" => m1})
    {:ok, _, _} = subscribe_and_join(socket, HostChannel, "host:m1", %{"roots" => ["/srv"], "version" => "0.12.0"})
    assert %{"error" => error} = as(ctx.app) |> post("/api/hosts/m1/spawn", %{path: "/srv/a", model: "claude-haiku-4-5"}) |> json_response(409)
    assert error =~ "update"
    refute_push "request", _
  end

  test "recent_dirs lists a host's past working directories", ctx do
    session_fixture(ctx.user, %{title: "a", host: "m5", working_directory: "/srv/projects/a"})
    session_fixture(ctx.user, %{title: "b", host: "m5", working_directory: "/srv/projects/b", status: :stopped})
    session_fixture(ctx.user, %{title: "c", host: "m1", working_directory: "/elsewhere"})

    dirs = as(ctx.api) |> get("/api/hosts/m5/recent_dirs") |> json_response(200) |> Map.fetch!("dirs")
    assert Enum.sort(Enum.map(dirs, & &1["path"])) == ["/srv/projects/a", "/srv/projects/b"]
    assert Enum.find(dirs, &(&1["path"] == "/srv/projects/a"))["seats_running"] == 1
  end

  # --- ls ------------------------------------------------------------------------------

  test "ls is relayed to the agent and its answer returned", ctx do
    chan = agent!(ctx)
    t = async(fn -> as(ctx.api) |> get("/api/hosts/m5/ls?path=/srv/projects") end)

    assert_push "request", %{"request_id" => rid, "op" => "ls", "args" => %{"path" => "/srv/projects"}}
    result = %{"path" => "/srv/projects", "parent" => nil, "dirs" => ["a", "b"], "truncated" => false}
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => true, "result" => result})

    assert Task.await(t) |> json_response(200) == result
  end

  test "the agent's refusal is passed on: outside its roots is 403", ctx do
    chan = agent!(ctx)
    t = async(fn -> as(ctx.api) |> get("/api/hosts/m5/ls?path=/etc") end)
    assert_push "request", %{"request_id" => rid}
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => false, "code" => "outside_roots", "error" => "/etc is outside the roots"})
    assert Task.await(t) |> json_response(403) == %{"error" => "/etc is outside the roots", "code" => "outside_roots"}
  end

  test "an offline host is 504", ctx do
    assert as(ctx.api) |> get("/api/hosts/m1/ls") |> json_response(504)
  end

  # --- spawn --------------------------------------------------------------------------

  test "spawn is app-only: the seat token is 403 and the agent is never asked", ctx do
    agent!(ctx)
    assert as(ctx.api) |> post("/api/hosts/m5/spawn", %{path: "/srv/projects/a"}) |> json_response(403)
    refute_push "request", _
  end

  test "spawn refuses bypassPermissions, a bad title or a missing path before asking the agent", ctx do
    agent!(ctx)

    for body <- [%{path: "/srv/projects/a", mode: "bypassPermissions"},
                 %{path: "/srv/projects/a", mode: "dontAsk"},
                 %{path: "/srv/projects/a", title: "bad title:with colon"},
                 %{mode: "auto"}] do
      assert as(ctx.app) |> post("/api/hosts/m5/spawn", body) |> json_response(400), inspect(body)
    end

    refute_push "request", _
  end

  test "spawn is 202 at once; the outcome arrives as host_spawn on operator:events", ctx do
    chan = agent!(ctx)
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, Hosts.events_topic(ctx.user.id))

    %{"spawn_id" => sid} =
      as(ctx.app) |> post("/api/hosts/m5/spawn", %{path: "/srv/projects/a", prompt: "hi"}) |> json_response(202)

    assert_push "request", %{"request_id" => rid, "op" => "spawn",
                             "args" => %{"path" => "/srv/projects/a", "mode" => "auto", "prompt" => "hi"}}
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => true, "result" => %{"title" => "a"}})

    assert_receive {"host_spawn", %{"spawn_id" => ^sid, "host" => "m5", "title" => "a", "ok" => true}}, 2_000
  end

  test "a spawned seat that reports no placement is given its machine, origin and folder", ctx do
    chan = agent!(ctx)
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, Hosts.events_topic(ctx.user.id))
    as(ctx.app) |> post("/api/hosts/m5/spawn", %{path: "/srv/projects/a", title: "bare"}) |> json_response(202)
    assert_push "request", %{"request_id" => rid, "op" => "spawn"}

    # A runtime without placement (the XPS's): no host, origin or folder.
    # A same-titled row on ANOTHER machine is not this seat.
    # (created AFTER this seat's row, so the newest-first pick would take it)
    bare = session_fixture(ctx.user, %{title: "bare"})
    elsewhere = session_fixture(ctx.user, %{title: "bare", host: "m1"})
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => true, "result" => %{"title" => "bare"}})

    id = bare.id
    assert_receive {"host_spawn", %{"op" => "spawn", "ok" => true, "started_as" => ^id}}, 3_000
    assert %{host: "m5", origin: "spawn", working_directory: "/srv/projects/a"} = ClaudiverseServer.Repo.reload!(bare)
    assert %{host: "m1", origin: nil} = ClaudiverseServer.Repo.reload!(elsewhere)
  end

  test "what a seat reported itself is kept", ctx do
    chan = agent!(ctx)
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, Hosts.events_topic(ctx.user.id))
    as(ctx.app) |> post("/api/hosts/m5/spawn", %{path: "/srv/projects/a", title: "full"}) |> json_response(202)
    assert_push "request", %{"request_id" => rid}
    full = session_fixture(ctx.user, %{title: "full", host: "m5", origin: "runner", working_directory: "/elsewhere"})
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => true, "result" => %{"title" => "full"}})

    assert_receive {"host_spawn", %{"started_as" => _}}, 3_000
    assert %{origin: "runner", working_directory: "/elsewhere"} = ClaudiverseServer.Repo.reload!(full)
  end

  test "a second spawn on the same host within the interval is 429", ctx do
    agent!(ctx)
    assert as(ctx.app) |> post("/api/hosts/m5/spawn", %{path: "/srv/projects/a"}) |> json_response(202)
    assert as(ctx.app) |> post("/api/hosts/m5/spawn", %{path: "/srv/projects/b"}) |> json_response(429)
  end

  test "spawning on an offline host is 504", ctx do
    assert as(ctx.app) |> post("/api/hosts/m1/spawn", %{path: "/x"}) |> json_response(504)
  end

  # --- stop / resume ---------------------------------------------------------------------

  @sid "6d9b917b-1779-49d0-b95b-ad36f8a84f8b"

  defp stopped_seat(ctx, attrs \\ %{}) do
    session_fixture(ctx.user, Map.merge(%{title: "seat-a", host: "m5", working_directory: "/srv/projects/a",
                                          claude_session_id: @sid, status: :stopped, permission_mode: "plan"}, attrs))
  end

  test "resume of a seat with no usable mode on record starts it in auto", ctx do
    agent!(ctx)
    s = stopped_seat(ctx, %{permission_mode: nil})
    as(ctx.app) |> post("/api/sessions/#{s.id}/resume") |> json_response(202)
    assert_push "request", %{"op" => "resume", "args" => %{"mode" => "auto"}}
  end

  test "stop and resume are app-only: the seat token is 403 and the agent is never asked", ctx do
    agent!(ctx)
    s = stopped_seat(ctx)
    assert as(ctx.api) |> post("/api/sessions/#{s.id}/stop") |> json_response(403)
    assert as(ctx.api) |> post("/api/sessions/#{s.id}/resume") |> json_response(403)
    refute_push "request", _
  end

  test "stop asks the seat's machine to close the seat's tmux session", ctx do
    chan = agent!(ctx)
    s = stopped_seat(ctx, %{status: :running})
    t = async(fn -> as(ctx.app) |> post("/api/sessions/#{s.id}/stop") end)

    assert_push "request", %{"request_id" => rid, "op" => "stop", "args" => %{"title" => "seat-a"}}
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => true, "result" => %{"title" => "seat-a"}})
    assert Task.await(t) |> json_response(200) == %{"ok" => true, "host" => "m5", "title" => "seat-a"}
  end

  test "stop passes on the agent's not_found as 404", ctx do
    chan = agent!(ctx)
    s = stopped_seat(ctx, %{status: :running})
    t = async(fn -> as(ctx.app) |> post("/api/sessions/#{s.id}/stop") end)
    assert_push "request", %{"request_id" => rid}
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => false, "code" => "not_found", "error" => "no seat named seat-a runs here"})
    assert Task.await(t) |> json_response(404)
  end

  test "stop and resume of a seat on an offline machine are 504", ctx do
    s = stopped_seat(ctx)
    assert as(ctx.app) |> post("/api/sessions/#{s.id}/stop") |> json_response(504)
    assert as(ctx.app) |> post("/api/sessions/#{s.id}/resume") |> json_response(504)
  end

  test "stop and resume refuse another user's seat, a proxy row and a seat with no machine", ctx do
    agent!(ctx)
    {other, _} = user_with_token()
    theirs = session_fixture(other, %{title: "theirs", host: "m5"})
    proxy = session_fixture(ctx.user, %{title: "proxy:x", type: :proxy, host: "m5"})
    nohost = session_fixture(ctx.user, %{title: "nohost"})

    for {s, status} <- [{theirs, 404}, {proxy, 404}, {nohost, 422}], action <- ["stop", "resume"] do
      assert as(ctx.app) |> post("/api/sessions/#{s.id}/#{action}") |> json_response(status), "#{action} #{s.title}"
    end

    refute_push "request", _
  end

  test "resume starts the seat again with its Claude session, folder, title and mode", ctx do
    chan = agent!(ctx)
    s = stopped_seat(ctx)
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, Hosts.events_topic(ctx.user.id))

    %{"spawn_id" => spawn_id} = as(ctx.app) |> post("/api/sessions/#{s.id}/resume") |> json_response(202)

    assert_push "request", %{"request_id" => rid, "op" => "resume",
                             "args" => %{"path" => "/srv/projects/a", "title" => "seat-a", "mode" => "plan", "session_id" => @sid}}
    # The resumed seat registers a NEW row under a placeholder session id.
    placeholder = "aeb24d74-6ab8-485a-b80e-5521c2d80739"
    resumed = session_fixture(ctx.user, %{title: "seat-a", host: "m5", working_directory: "/srv/projects/a",
                                          claude_session_id: placeholder})
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => true, "result" => %{"title" => "seat-a"}})

    sid = s.id
    rid2 = resumed.id
    assert_receive {"host_spawn", %{"spawn_id" => ^spawn_id, "op" => "resume", "session_id" => ^sid,
                                    "resumed_as" => ^rid2, "ok" => true}}, 3_000

    # ...which now carries the conversation, so resuming IT continues the same one.
    assert ClaudiverseServer.Repo.reload!(resumed).conversation_id == @sid
    ClaudiverseServer.Sessions.update_session(ClaudiverseServer.Repo.reload!(resumed), %{status: :stopped})
    :sys.replace_state(Hosts, fn st -> %{st | last_spawn: %{}} end)

    assert as(ctx.app) |> post("/api/sessions/#{rid2}/resume") |> json_response(202)
    assert_push "request", %{"op" => "resume", "args" => %{"session_id" => @sid}}
  end

  test "a resumed seat that never registers gives resumed_as nil, and nothing else is adopted", ctx do
    chan = agent!(ctx)
    s = stopped_seat(ctx)
    other = session_fixture(ctx.user, %{title: "other", host: "m5"})
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, Hosts.events_topic(ctx.user.id))

    as(ctx.app) |> post("/api/sessions/#{s.id}/resume") |> json_response(202)
    assert_push "request", %{"request_id" => rid, "op" => "resume"}
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => true, "result" => %{"title" => "seat-a"}})

    assert_receive {"host_spawn", %{"op" => "resume", "resumed_as" => nil, "ok" => true}}, 3_000
    assert ClaudiverseServer.Repo.reload!(other).conversation_id == nil
    assert ClaudiverseServer.Repo.reload!(s).conversation_id == nil
  end

  test "resume takes the app's title and mode; bypassPermissions or a bypass seat's mode never pass", ctx do
    agent!(ctx)
    s = stopped_seat(ctx, %{permission_mode: "bypassPermissions"})

    assert as(ctx.app) |> post("/api/sessions/#{s.id}/resume", %{mode: "bypassPermissions"}) |> json_response(400)
    assert as(ctx.app) |> post("/api/sessions/#{s.id}/resume", %{title: "bad:title"}) |> json_response(400)
    refute_push "request", _

    assert as(ctx.app) |> post("/api/sessions/#{s.id}/resume", %{title: "seat-b"}) |> json_response(202)
    # A bypass seat's mode never passes: it falls back as no mode does, to auto.
    assert_push "request", %{"op" => "resume", "args" => %{"title" => "seat-b", "mode" => "auto"}}
  end

  test "resume refuses a running seat and one that never reported its Claude session", ctx do
    agent!(ctx)
    running = stopped_seat(ctx, %{status: :running})
    legacy = stopped_seat(ctx, %{title: "legacy", claude_session_id: nil})

    assert as(ctx.app) |> post("/api/sessions/#{running.id}/resume") |> json_response(409)
    assert as(ctx.app) |> post("/api/sessions/#{legacy.id}/resume") |> json_response(422)
    refute_push "request", _
  end

  test "resume shares spawn's per-host rate limit", ctx do
    agent!(ctx)
    s = stopped_seat(ctx)
    assert as(ctx.app) |> post("/api/hosts/m5/spawn", %{path: "/srv/projects/b"}) |> json_response(202)
    assert as(ctx.app) |> post("/api/sessions/#{s.id}/resume") |> json_response(429)
  end

  # --- interrupt ------------------------------------------------------------------------

  # A FRESH Room: sandboxed rows reuse ids, so start_room would otherwise hand
  # back an earlier test's Room for the same id, with that test's state.
  defp busy_seat(ctx, attrs \\ %{}) do
    s = session_fixture(ctx.user, Map.merge(%{title: "seat-a", host: "m5"}, attrs))
    registry = ClaudiverseServer.Sessions.Registry

    with [{old, _}] <- Registry.lookup(registry, s.id) do
      ClaudiverseServer.Sessions.Supervisor.stop_room(old)
      Enum.find(1..100, fn _ -> Registry.lookup(registry, s.id) == [] or (Process.sleep(10) && false) end)
    end

    {:ok, pid} = ClaudiverseServer.Sessions.Supervisor.start_room(s.id, owner_id: ctx.user.id)
    on_exit(fn -> if Process.alive?(pid), do: ClaudiverseServer.Sessions.Supervisor.stop_room(pid) end)
    s
  end

  test "interrupting a busy seat with no inbox poller asks its machine to press Escape, once", ctx do
    chan = agent!(ctx)
    s = busy_seat(ctx)
    ClaudiverseServer.Sessions.Room.interrupt(s.id)

    assert_push "request", %{"request_id" => rid, "op" => "interrupt", "args" => %{"title" => "seat-a"}}, 1_000
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => true, "result" => %{"title" => "seat-a"}})
    refute_push "request", _, 300
  end

  test "a seat with a live inbox poller is interrupted through it, not the machine", ctx do
    agent!(ctx)
    s = busy_seat(ctx)
    :ok = ClaudiverseServer.SeatLinks.register(:inbox, ctx.user.id, "seat-a")
    ClaudiverseServer.Sessions.Room.interrupt(s.id)

    assert_receive :inbox_interrupt, 1_000
    refute_push "request", _, 300
  end

  test "an idle seat, or one with no machine, is not sent an Escape", ctx do
    agent!(ctx)
    idle = busy_seat(ctx, %{title: "idle-seat"})
    :sys.replace_state({:via, Registry, {ClaudiverseServer.Sessions.Registry, idle.id}}, &%{&1 | idle: true})
    ClaudiverseServer.Sessions.Room.interrupt(idle.id)

    nohost = busy_seat(ctx, %{title: "nohost", host: nil})
    ClaudiverseServer.Sessions.Room.interrupt(nohost.id)

    refute_push "request", _, 300
  end

  test "the removed /api/spawn no longer exists", ctx do
    assert as(ctx.app) |> post("/api/spawn", %{path: "/x"}) |> response(404)
  end
end
