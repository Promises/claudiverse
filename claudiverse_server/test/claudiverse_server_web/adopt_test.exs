defmodule ClaudiverseServerWeb.AdoptTest do
  @moduledoc """
  Adopt: a seat started by hand becomes a profile seat. The machine's agent is
  played by the test process over a real channel, as in ProfileTest.
  """
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures
  import Ecto.Query
  import Phoenix.ChannelTest, except: [connect: 2, connect: 3]

  @endpoint ClaudiverseServerWeb.Endpoint

  alias ClaudiverseServer.{Accounts, Hosts, Repo}
  alias ClaudiverseServer.Sessions.Session
  alias ClaudiverseServerWeb.{HostChannel, UserSocket}

  # A patched seat's row carries a stale conversation id; its process knows the live one.
  @stale "6d9b917b-1779-49d0-b95b-ad36f8a84f8b"
  @live "d7dba841-a246-4186-9c74-da1d8534d610"

  setup do
    {user, api} = user_with_token()
    app = Accounts.create_user_api_token(user, "app")
    super_token = Accounts.create_user_api_token(user, "super", "desktop")
    {:ok, host} = Accounts.create_host_token(user, "m5")
    :sys.replace_state(Hosts, fn st -> %{st | last_spawn: %{}} end)
    # A start's outcome waits this long for the seat to register; it must land
    # inside its own test, or it writes into the next one's (same ids).
    Application.put_env(:claudiverse_server, :host_adopt_timeout_ms, 200)
    on_exit(fn -> Application.delete_env(:claudiverse_server, :host_adopt_timeout_ms) end)
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, Hosts.events_topic(user.id))

    seat =
      session_fixture(user, %{title: "ipsum-admin", host: "m5", working_directory: "/srv/ipsum", claude_session_id: @stale,
                              client_version: "2.1.286 (Claude Code) [claudiverse]", origin: "manual", fleet: "ipsum-fleet"})

    %{user: user, api: api, app: app, super: super_token, host: host, seat: seat}
  end

  defp agent!(ctx, version \\ "0.9.0") do
    {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{"token" => ctx.host})
    {:ok, _, chan} =
      subscribe_and_join(socket, HostChannel, "host:m5", %{"roots" => ["/srv"], "version" => version,
                                                          "runtimes" => [%{"name" => "stock+mod"}, %{"name" => "patched"}]})
    chan
  end

  defp as(token), do: build_conn() |> put_req_header("authorization", "Bearer " <> token)

  @found %{"pid" => 87920, "proc_start" => "Sat Oct  3 08:18:54 2026", "tmux" => "ipsum-admin:@199.%199", "status" => "idle",
           "version" => "2.1.286", "matched_by" => "tmux_title", "session_id" => @live, "cwd" => "/srv/ipsum", "transcript" => true}

  # The agent answers the next request `op` with `reply`; returns its args.
  defp answer(chan, op, reply) do
    assert_push "request", %{"request_id" => rid, "op" => ^op, "args" => args}, 2_000
    Phoenix.ChannelTest.push(chan, "reply", Map.put(reply, "request_id", rid))
    args
  end

  defp preview(ctx, chan, reply) do
    task = Task.async(fn -> as(ctx.app) |> get("/api/sessions/#{ctx.seat.id}/adopt_preview") |> json_response(200) end)
    args = answer(chan, "locate_seat", reply)
    {args, Task.await(task)}
  end

  test "preview is app-only and asks the agent for the seat's process; resume comes from the PROCESS", ctx do
    chan = agent!(ctx)
    assert as(ctx.api) |> get("/api/sessions/#{ctx.seat.id}/adopt_preview") |> json_response(403)

    {args, out} = preview(ctx, chan, %{"ok" => true, "result" => @found})
    assert %{"session_ids" => [@stale], "title" => "ipsum-admin", "cwd" => "/srv/ipsum", "runtime" => "patched"} = args

    assert %{"blocked" => nil, "existing_profile" => nil,
             "process" => %{"pid" => 87920, "matched_by" => "tmux_title", "session_id" => @live},
             "suggested" => %{"runtime" => "patched", "pooled" => false, "resume" => @live, "folder" => "/srv/ipsum", "machine" => "m5", "fleet" => "ipsum-fleet"}} = out
  end

  test "preview is blocked, with a reason, for what the app cannot see", ctx do
    chan = agent!(ctx)
    {_, out} = preview(ctx, chan, %{"ok" => true, "result" => %{@found | "transcript" => false}})
    assert out["blocked"] =~ "cannot resume"

    {_, out} = preview(ctx, chan, %{"ok" => false, "code" => "several", "error" => "2 running processes match"})
    assert %{"process" => nil, "blocked" => "2 running processes match"} = out
    refute Map.has_key?(out, "folder")

    # A folder outside the agent's roots is named, so the app can offer to allow it.
    {_, out} = preview(ctx, chan, %{"ok" => false, "code" => "outside_roots", "error" => "/srv/x is outside this machine's allowed folders", "path" => "/srv/x"})
    assert %{"blocked" => "/srv/x is outside this machine's allowed folders", "folder" => "/srv/x", "process" => nil} = out

    seat_id = ctx.seat.id
    Repo.update_all(from(s in Session, where: s.id == ^seat_id), set: [origin: "runner"])
    out = as(ctx.app) |> get("/api/sessions/#{ctx.seat.id}/adopt_preview") |> json_response(200)
    assert out["blocked"] =~ "cv-runner"
    refute_push "request", _, 100
  end

  test "a fork of a profile seat (origin profile, no profile id) can be adopted; a real profile seat cannot", ctx do
    seat_id = ctx.seat.id
    Repo.update_all(from(s in Session, where: s.id == ^seat_id), set: [origin: "profile"])
    chan = agent!(ctx)
    {_, out} = preview(ctx, chan, %{"ok" => true, "result" => @found})
    assert out["blocked"] == nil

    Repo.update_all(from(s in Session, where: s.id == ^seat_id), set: [profile_id: 999])
    out = as(ctx.app) |> get("/api/sessions/#{ctx.seat.id}/adopt_preview") |> json_response(200)
    assert out["blocked"] == "it already runs from a profile"
  end

  test "an agent older than 0.9.0 is never asked", ctx do
    agent!(ctx, "0.8.3")
    out = as(ctx.app) |> get("/api/sessions/#{ctx.seat.id}/adopt_preview") |> json_response(200)
    assert out["blocked"] =~ "needs 0.9.0"
    refute_push "request", _, 100
  end

  @fields %{"machine" => "m5", "folder" => "/srv/ipsum", "fleet" => "ipsum-fleet", "role" => "orchestrator", "can_notify" => true,
            "runtime" => "patched", "permission_mode" => "auto", "mcp" => ["claudiverse"], "pooled" => false,
            "autostart" => false, "resume" => @live, "debug" => false}

  defp adopt(ctx, extra) do
    Task.async(fn -> as(ctx.app) |> post("/api/sessions/#{ctx.seat.id}/adopt", Map.merge(@fields, extra)) end)
  end

  test "adopt creates the profile, stops exactly that process, ends the hand-started row and starts the profile", ctx do
    chan = agent!(ctx)
    task = adopt(ctx, %{"pid" => 87920, "proc_start" => @found["proc_start"]})

    release = answer(chan, "release_seat", %{"ok" => true, "result" => %{"stopped" => 87920}})
    assert %{"pid" => 87920, "proc_start" => "Sat Oct  3 08:18:54 2026", "force" => false, "title" => "ipsum-admin",
             "runtime" => "patched", "cwd" => "/srv/ipsum"} = release
    assert hd(release["session_ids"]) == @live

    start = answer(chan, "start_profile", %{"ok" => true, "result" => %{"title" => "ipsum-admin"}})
    assert %{"name" => "ipsum-admin", "resume" => @live, "resume_policy" => "fixed", "runtime" => "patched"} = start

    assert %{"profile" => %{"name" => "ipsum-admin", "machine" => "m5"}} = json_response(Task.await(task), 202)
    assert %{status: :stopped} = Repo.get!(Session, ctx.seat.id)
    assert_receive {"profile", %{"op" => "start", "profile" => %{last_start: %{"outcome" => "started"}}}}, 2_000
  end

  test "a refused stop leaves the process running and starts nothing; the profile is kept", ctx do
    chan = agent!(ctx)
    task = adopt(ctx, %{"pid" => 87920, "proc_start" => @found["proc_start"]})
    answer(chan, "release_seat", %{"ok" => false, "code" => "busy", "error" => "ipsum-admin is mid-turn"})

    assert %{"code" => "busy", "error" => "ipsum-admin is mid-turn"} = json_response(Task.await(task), 409)
    refute_push "request", %{"op" => "start_profile"}, 200
    assert %{status: :running} = Repo.get!(Session, ctx.seat.id)
    assert [%{"name" => "ipsum-admin", "status" => "stopped"}] = as(ctx.api) |> get("/api/profiles") |> json_response(200) |> Map.fetch!("profiles")
  end

  test "a profile with the seat's name is adopted into, only when named; a running one refuses", ctx do
    p = as(ctx.super) |> post("/api/profiles", Map.merge(@fields, %{"name" => "ipsum-admin", "runtime" => "stock+mod"}))
        |> json_response(201) |> Map.fetch!("profile")
    chan = agent!(ctx)

    {_, out} = preview(ctx, chan, %{"ok" => true, "result" => @found})
    assert %{"existing_profile" => %{"id" => id}} = out
    assert id == p["id"]

    assert %{"code" => "blocked"} = json_response(Task.await(adopt(ctx, %{"pid" => 87920, "proc_start" => "x"})), 409)
    refute_push "request", _, 100

    task = adopt(ctx, %{"pid" => 87920, "proc_start" => @found["proc_start"], "profile_id" => p["id"]})
    assert %{"runtime" => "patched"} = answer(chan, "release_seat", %{"ok" => true, "result" => %{}})
    answer(chan, "start_profile", %{"ok" => true, "result" => %{"title" => "ipsum-admin"}})
    assert %{"profile" => %{"id" => ^id, "runtime" => "patched", "revision" => 2}} = json_response(Task.await(task), 202)
    assert_receive {"profile", %{"op" => "start", "profile" => %{last_start: %{"outcome" => "started"}}}}, 2_000
  end

  test "with no agent on the machine, preview says offline and adopt creates nothing", ctx do
    out = as(ctx.app) |> get("/api/sessions/#{ctx.seat.id}/adopt_preview") |> json_response(200)
    assert out["blocked"] =~ "offline"
    resp = as(ctx.app) |> post("/api/sessions/#{ctx.seat.id}/adopt", Map.merge(@fields, %{"pid" => 1, "proc_start" => "x"}))
    assert %{"code" => "blocked"} = json_response(resp, 409)
    assert [] = as(ctx.api) |> get("/api/profiles") |> json_response(200) |> Map.fetch!("profiles")
  end

  # --- a row with no host ---------------------------------------------------------

  defp hostless!(ctx) do
    seat_id = ctx.seat.id
    Repo.update_all(from(s in Session, where: s.id == ^seat_id), set: [host: nil])
    seat_id
  end

  test "a row with no host is looked for on the hinted machine, by conversation id only", ctx do
    chan = agent!(ctx)
    id = hostless!(ctx)

    assert %{"blocked" => "its machine is not known"} = as(ctx.app) |> get("/api/sessions/#{id}/adopt_preview") |> json_response(200)

    task = Task.async(fn -> as(ctx.app) |> get("/api/sessions/#{id}/adopt_preview?host=m5") |> json_response(200) end)
    answer(chan, "locate_seat", %{"ok" => true, "result" => %{@found | "matched_by" => "session_id", "session_id" => @stale}})
    assert %{"blocked" => nil, "suggested" => %{"machine" => "m5", "resume" => @stale}} = Task.await(task)

    task = Task.async(fn -> as(ctx.app) |> get("/api/sessions/#{id}/adopt_preview?host=m5") |> json_response(200) end)
    answer(chan, "locate_seat", %{"ok" => true, "result" => @found})
    assert Task.await(task)["blocked"] =~ "found only by tmux name on m5"

    # Adopt on a guessed machine re-checks the match before stopping anything.
    task = adopt(ctx, %{"pid" => 87920, "proc_start" => @found["proc_start"], "host" => "m5"})
    answer(chan, "locate_seat", %{"ok" => true, "result" => @found})
    assert %{"code" => "blocked"} = json_response(Task.await(task), 409)
    refute_push "request", %{"op" => "release_seat"}, 200
  end

  test "a row that recorded its machine ignores the hint", ctx do
    chan = agent!(ctx)
    task = Task.async(fn -> as(ctx.app) |> get("/api/sessions/#{ctx.seat.id}/adopt_preview?host=elsewhere") |> json_response(200) end)
    answer(chan, "locate_seat", %{"ok" => true, "result" => @found})
    assert %{"blocked" => nil, "suggested" => %{"machine" => "m5"}} = Task.await(task)
  end

  test "a stock+mod seat is suggested pooled", ctx do
    seat_id = ctx.seat.id
    Repo.update_all(from(s in Session, where: s.id == ^seat_id), set: [client_version: "2.1.292 (Claude Code) [claudiverse-mod]"])
    chan = agent!(ctx)
    {_, out} = preview(ctx, chan, %{"ok" => true, "result" => @found})
    assert %{"suggested" => %{"runtime" => "stock+mod", "pooled" => true}} = out
  end

  # --- placing a seat by its address ---------------------------------------------

  defp agent_at!(_ctx, name, token, ip) do
    {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{"token" => token}, connect_info: %{peer_data: %{address: ip}})
    {:ok, _, chan} = subscribe_and_join(socket, HostChannel, "host:#{name}", %{"roots" => ["/srv"], "version" => "0.9.0"})
    chan
  end

  test "a seat that reports no host is placed on the one agent at its address", ctx do
    # Bandit hands an IPv4 peer to the IPv6 listener as ::ffff:a.b.c.d; ConnCase's conn is 127.0.0.1.
    agent_at!(ctx, "m5", ctx.host, {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001})
    seat = as(ctx.api) |> post("/api/sessions", %{title: "plain-1", claude_session_id: "11111111-2222-4333-8444-555555555555"})
           |> json_response(201) |> Map.fetch!("session")
    assert seat["host"] == "m5"

    reported = as(ctx.api) |> post("/api/sessions", %{title: "plain-2", host: "laptop", claude_session_id: "21111111-2222-4333-8444-555555555555"})
               |> json_response(201) |> Map.fetch!("session")
    assert reported["host"] == "laptop", "a reported host is never overridden"
  end

  test "a seat that registered before its machine's agent is placed when the agent joins", ctx do
    :sys.replace_state(Hosts, fn st -> Map.put(st, :unplaced, %{}) end)
    seat = as(ctx.api) |> post("/api/sessions", %{title: "early-1"}) |> json_response(201) |> Map.fetch!("session")
    assert seat["host"] == nil

    agent_at!(ctx, "m5", ctx.host, {127, 0, 0, 1})
    assert %{host: "m5"} = Repo.get!(Session, seat["id"])
  end

  test "no agent, or two agents, at the address: the host stays unknown", ctx do
    seat = as(ctx.api) |> post("/api/sessions", %{title: "plain-3"}) |> json_response(201) |> Map.fetch!("session")
    assert seat["host"] == nil

    agent_at!(ctx, "m5", ctx.host, {127, 0, 0, 1})
    {:ok, other} = Accounts.create_host_token(ctx.user, "m1")
    agent_at!(ctx, "m1", other, {127, 0, 0, 1})
    seat = as(ctx.api) |> post("/api/sessions", %{title: "plain-4"}) |> json_response(201) |> Map.fetch!("session")
    assert seat["host"] == nil
  end

  # --- the live permission mode of a seat with no sidecar ------------------------

  test "the app's mode switch reaches a mod seat through its machine's agent", ctx do
    {:ok, room} = ClaudiverseServer.Sessions.Supervisor.start_room(ctx.seat.id, owner_id: ctx.user.id)
    on_exit(fn -> if Process.alive?(room), do: ClaudiverseServer.Sessions.Supervisor.stop_room(room) end)
    chan = agent!(ctx)
    assert as(ctx.api) |> post("/api/sessions/#{ctx.seat.id}/permission_mode", %{mode: "auto"}) |> json_response(403)

    task = Task.async(fn -> as(ctx.app) |> post("/api/sessions/#{ctx.seat.id}/permission_mode", %{mode: "auto"}) end)
    assert %{"title" => "ipsum-admin", "mode" => "auto"} = answer(chan, "set_mode", %{"ok" => true, "result" => %{"title" => "ipsum-admin", "mode" => "auto"}})
    assert %{"status" => "applied", "mode" => "auto"} = json_response(Task.await(task), 200)
    live = as(ctx.api) |> get("/api/sessions/#{ctx.seat.id}") |> json_response(200) |> get_in(["live", "permission_mode"])
    assert live == "auto", "the applied mode is reported at once, not at the next footer read"

    task = Task.async(fn -> as(ctx.app) |> post("/api/sessions/#{ctx.seat.id}/permission_mode", %{mode: "plan"}) end)
    answer(chan, "set_mode", %{"ok" => false, "code" => "busy", "error" => "ipsum-admin has a dialog open; answer it first"})
    assert %{"status" => "refused", "code" => "busy"} = json_response(Task.await(task), 409)
  end

  test "the agent's footer reading becomes the seat's reported mode; only its own machine's", ctx do
    {:ok, room} = ClaudiverseServer.Sessions.Supervisor.start_room(ctx.seat.id, owner_id: ctx.user.id)
    on_exit(fn -> if Process.alive?(room), do: ClaudiverseServer.Sessions.Supervisor.stop_room(room) end)
    live = fn -> as(ctx.api) |> get("/api/sessions/#{ctx.seat.id}") |> json_response(200) |> get_in(["live", "permission_mode"]) end
    assert live.() == nil

    chan = agent!(ctx)
    Phoenix.ChannelTest.push(chan, "seat_modes", %{"modes" => %{"ipsum-admin" => "auto", "nobody" => "plan"}})
    wait = fn want -> Enum.find_value(1..50, fn _ -> (live.() == want && true) || (Process.sleep(20) && nil) end) end
    assert wait.("auto")

    Phoenix.ChannelTest.push(chan, "seat_modes", %{"modes" => %{"ipsum-admin" => "bogus"}})
    Process.sleep(100)
    assert live.() == "auto", "an unknown mode is ignored"

    {:ok, other} = Accounts.create_host_token(ctx.user, "m1")
    {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{"token" => other})
    {:ok, _, m1} = subscribe_and_join(socket, HostChannel, "host:m1", %{"roots" => ["/srv"], "version" => "0.9.3"})
    Phoenix.ChannelTest.push(m1, "seat_modes", %{"modes" => %{"ipsum-admin" => "plan"}})
    Process.sleep(100)
    assert live.() == "auto", "another machine's agent cannot set it"
  end

  test "session JSON carries profile_id", ctx do
    assert %{"session" => %{"profile_id" => nil}} = as(ctx.api) |> get("/api/sessions/#{ctx.seat.id}") |> json_response(200)
  end
end
