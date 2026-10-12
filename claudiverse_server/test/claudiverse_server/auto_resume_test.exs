defmodule ClaudiverseServer.AutoResumeTest.Upstream do
  @moduledoc false
  # A stand-in for api.anthropic.com: "slow" streams until the client is gone,
  # anything else answers at once.
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, _body, conn} = read_body(conn, length: 10_000_000)

    case get_req_header(conn, "x-test-scenario") do
      ["slow"] ->
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

        Enum.reduce_while(1..1500, conn, fn _, conn ->
          Process.sleep(20)

          case chunk(conn, "event: ping\ndata: {\"type\":\"ping\"}\n\n") do
            {:ok, conn} -> {:cont, conn}
            {:error, _} -> {:halt, conn}
          end
        end)

      _ ->
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_resp(200, "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
    end
  end
end

defmodule ClaudiverseServer.AutoResumeTest.Front do
  @moduledoc false
  # The proxy plug alone, as the endpoint mounts it. Tells the test which
  # process relays a "slow" stream, so the test can kill it as a stopping VM does.
  def init(opts), do: opts

  def call(conn, _opts) do
    if Plug.Conn.get_req_header(conn, "x-test-scenario") == ["slow"],
      do: send(:persistent_term.get({__MODULE__, :owner}), {:relaying, self()})

    conn = ClaudiverseServerWeb.ProxyPlug.call(conn, [])
    if conn.halted, do: conn, else: Plug.Conn.send_resp(conn, 404, "not proxied")
  end
end

defmodule ClaudiverseServer.AutoResumeTest do
  @moduledoc """
  Auto-resume (ClaudiverseServer.AutoResume): a seat whose turn died on a
  restart that cut its stream, or on an empty pool, gets exactly one
  `continue` through its reject-busy delivery once the server can serve it
  again. The streams go through the real proxy plug to a stand-in upstream;
  the seat is a Room with the test process as its sidecar, so a delivery
  arrives here as {:forward_to_sidecar, "remote_input", ...}.
  """
  # Not async: the AutoResume server and the Rooms read the database from their
  # own processes, which needs the shared sandbox.
  use ClaudiverseServer.DataCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.AnthropicAuths.AnthropicAuth
  alias ClaudiverseServer.AutoResume
  alias ClaudiverseServer.AutoResume.{Server, Stall}
  alias ClaudiverseServer.Proxy.Request
  alias ClaudiverseServer.Sessions.{Room, Supervisor}

  @tools [%{name: "Bash", input_schema: %{type: "object"}}]

  setup do
    {:ok, up} = Bandit.start_link(plug: __MODULE__.Upstream, port: 0, ip: :loopback, startup_log: false)
    {:ok, {_, up_port}} = ThousandIsland.listener_info(up)
    {:ok, front} = Bandit.start_link(plug: __MODULE__.Front, port: 0, ip: :loopback, startup_log: false)
    {:ok, {_, port}} = ThousandIsland.listener_info(front)
    :persistent_term.put({__MODULE__.Front, :owner}, self())

    prev = {Application.get_env(:claudiverse_server, :proxy_upstream), Application.get_env(:claudiverse_server, AutoResume)}
    Application.put_env(:claudiverse_server, :proxy_upstream, "http://127.0.0.1:#{up_port}")
    Application.put_env(:claudiverse_server, AutoResume, enabled: false, track: true, grace_s: 60)
    fresh_server()
    ClaudiverseServer.Proxy.Credentials.reset()

    on_exit(fn ->
      # Every cast the proxy sent is handled before the sandbox goes.
      :sys.get_state(Server)
      fresh_server()

      for {_, pid, _, _} <- DynamicSupervisor.which_children(ClaudiverseServer.Sessions.Supervisor), is_pid(pid),
          do: DynamicSupervisor.terminate_child(ClaudiverseServer.Sessions.Supervisor, pid)

      {u, a} = prev
      if u, do: Application.put_env(:claudiverse_server, :proxy_upstream, u), else: Application.delete_env(:claudiverse_server, :proxy_upstream)
      Application.put_env(:claudiverse_server, AutoResume, a)
    end)

    {user, token} = user_with_token()
    n = System.unique_integer([:positive])
    %{user: user, token: token, base: "http://127.0.0.1:#{port}", title: "ipsum-worker-#{n}", sid: "claude-session-#{n}"}
  end

  # What a VM that just started holds: no counts, nothing stopping.
  defp fresh_server, do: :sys.replace_state(Server, fn _ -> %{streams: %{}, stalled: MapSet.new(), open: %{}, stopping: false} end)

  # --- helpers ---------------------------------------------------------------

  # One model call through the proxy, as a mod seat makes it (its own login,
  # not observed). `pooled: true` asks for the pool account.
  defp model_call(ctx, opts \\ []) do
    headers =
      [
        {"content-type", "application/json"},
        {"authorization", "Bearer seat-own-login"},
        {"x-claudiverse-token", ctx.token},
        {"x-claudiverse-observe", "off"},
        {"x-claude-code-session-id", Keyword.get(opts, :sid, ctx.sid)},
        {"x-test-scenario", Keyword.get(opts, :scenario, "text")}
      ] ++
        if(opts[:pooled], do: [{"x-claudiverse-pool", "1"}], else: []) ++
        if(a = opts[:agent], do: [{"x-claude-code-agent-id", a}], else: [])

    body = Jason.encode!(%{model: "claude-test", max_tokens: 1000, stream: true, tools: Keyword.get(opts, :tools, @tools),
                           messages: [%{role: "user", content: [%{type: "text", text: "work"}]}]})

    Finch.build(:post, "#{ctx.base}/proxy/seat/#{ctx.title}/v1/messages?beta=true", headers, body)
    |> Finch.request(ClaudiverseServer.Proxy.Finch, receive_timeout: 60_000)
  end

  # A seat whose Room has the test process as its sidecar.
  defp seat(ctx, idle, sid \\ nil) do
    seat = session_fixture(ctx.user, %{title: ctx.title, claude_session_id: sid || ctx.sid})
    {:ok, _} = Supervisor.start_room(seat.id, owner_id: ctx.user.id)
    Room.register_sidecar(seat.id, self())
    if idle, do: go_idle(seat)
    seat
  end

  # The seat finishes a turn: the Room reads idle and tells the Router, which
  # tells AutoResume.Server.
  defp go_idle(seat) do
    Room.mirror_messages(seat.id, [%{"type" => "idle"}])
    Room.get_status(seat.id)
    :sys.get_state(ClaudiverseServer.Notifications.Router)
    :sys.get_state(Server)
  end

  defp stall(ctx) do
    :sys.get_state(Server)
    AutoResume.get(ctx.user.id, ctx.title)
  end

  defp eventually(fun, tries \\ 200) do
    case fun.() do
      x when x in [nil, false] ->
        if tries == 0, do: flunk("condition never held"), else: (Process.sleep(25); eventually(fun, tries - 1))

      x ->
        x
    end
  end

  # A model response streaming to the seat when the server goes down: the
  # application's prep_stop, then the VM stops, which kills the process
  # relaying the stream mid-response. Then a new VM: fresh in-memory state.
  defp restart_mid_stream(ctx) do
    {:ok, _} = Task.start(fn -> model_call(ctx, scenario: "slow") end)
    assert_receive {:relaying, relay}, 2_000
    eventually(fn -> match?(%Stall{in_flight: true}, AutoResume.get(ctx.user.id, ctx.title)) end)

    Server.shutting_down()
    kill(relay)
    :sys.get_state(Server)
    fresh_server()
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}, 1_000
  end

  defp continues(timeout \\ 300) do
    receive do
      {:forward_to_sidecar, "remote_input", %{"content" => "continue"}} -> 1 + continues(timeout)
    after
      timeout -> 0
    end
  end

  # --- the restart ------------------------------------------------------------

  test "a proxy stream cut mid-response by a restart gets exactly one continue, after the grace", ctx do
    restart_mid_stream(ctx)
    boot = DateTime.utc_now()
    assert [%Stall{reason: "server_restart"}] = Server.boot(boot)
    seat = seat(ctx, true)

    Server.tick(DateTime.add(boot, 30, :second))
    assert continues() == 0, "within the grace, nothing"
    assert %Stall{state: "stalled", waiting: "grace"} = stall(ctx)

    Server.tick(DateTime.add(boot, 61, :second))
    assert continues() == 1

    assert %Stall{state: "nudged", nudged_session_id: sid, reason: "server_restart"} = stall(ctx)
    assert sid == seat.id
    assert [%{kind: "auto_resume", trigger: "server_restart"}] = ClaudiverseServer.Sessions.list_events(seat.id, kind: "auto_resume")

    # The seat comes back idle again (say its continue failed too): never a second one.
    go_idle(seat)
    Server.tick(DateTime.add(boot, 120, :second))
    Server.tick(DateTime.add(boot, 600, :second))
    assert continues() == 0
    assert Server.boot(DateTime.add(boot, 700, :second)) == [], "a second boot finds nothing in flight"

    # Its next model call is answered: the incident is closed.
    {:ok, %{status: 200}} = model_call(ctx)
    assert %Stall{state: "clear", reason: nil, in_flight: false} = stall(ctx)
  end

  test "a stream that ended before the restart is no casualty", ctx do
    {:ok, %{status: 200}} = model_call(ctx)
    assert %Stall{in_flight: false} = stall(ctx)

    Server.shutting_down()
    fresh_server()

    assert Server.boot(~U[2026-10-11 12:51:00Z]) == []
    seat(ctx, true)
    Server.tick(~U[2026-10-11 12:55:00Z])
    assert continues() == 0
  end

  test "while the server stops, a stream cut stays in flight; one that finished whole does not", ctx do
    cut = {ctx.user.id, ctx.title, ctx.sid}
    whole = {ctx.user.id, ctx.title <> "-b", "other-session"}
    Server.stream_started(cut)
    Server.stream_started(whole)
    Server.shutting_down()
    Server.stream_ended(cut, false)
    Server.stream_ended(whole, true)
    fresh_server()

    assert [%Stall{seat_title: title}] = Server.boot(DateTime.utc_now())
    assert title == ctx.title
  end

  test "a seat whose own retry got through after the restart is not nudged", ctx do
    restart_mid_stream(ctx)

    [_] = Server.boot(~U[2026-10-11 12:51:00Z])
    {:ok, %{status: 200}} = model_call(ctx)
    seat(ctx, true)

    Server.tick(~U[2026-10-11 12:53:00Z])
    assert continues() == 0
    assert %Stall{state: "clear"} = stall(ctx)
  end

  test "a busy seat gets its continue when it goes idle, not before", ctx do
    restart_mid_stream(ctx)
    boot = DateTime.add(DateTime.utc_now(), -120, :second)
    [_] = Server.boot(boot)
    seat = seat(ctx, false)

    Server.tick(DateTime.utc_now())
    assert continues() == 0
    assert %Stall{waiting: "busy"} = stall(ctx)

    go_idle(seat)
    assert continues() == 1
    assert %Stall{state: "nudged"} = stall(ctx)
  end

  test "an absent seat gets it when it comes back; a new conversation under the title does not", ctx do
    restart_mid_stream(ctx)
    [_] = Server.boot(DateTime.add(DateTime.utc_now(), -120, :second))

    Server.tick(DateTime.utc_now())
    assert %Stall{waiting: "seat"} = stall(ctx)

    other = seat(ctx, true, "a-fresh-conversation")
    Server.tick(DateTime.utc_now())
    assert continues() == 0, "a fresh conversation has no dead turn"
    assert %Stall{waiting: "seat"} = stall(ctx)
    assert other.claude_session_id != ctx.sid

    seat = seat(ctx, false)
    ClaudiverseServer.Notifications.Router.seat_seen(ctx.title, seat.id)
    :sys.get_state(Server)
    assert continues() == 0, "seen, but busy"
    go_idle(seat)
    assert continues() == 1
  end

  # --- the pool ---------------------------------------------------------------

  defp account! do
    Repo.insert!(%AnthropicAuth{label: "Work", priority: 10, status: "available", scopes: "user:inference"})
  end

  test "a call refused for an empty pool gets one continue when an account is leasable, once per incident", ctx do
    {:ok, %{status: 429, body: body}} = model_call(ctx, pooled: true)
    assert body =~ "no_available_auth"
    {:ok, %{status: 429}} = model_call(ctx, pooled: true)
    assert %Stall{state: "stalled", reason: "no_available_auth", waiting: "pool", stalled_at: first} = stall(ctx)

    seat = seat(ctx, true)
    Server.tick(DateTime.utc_now())
    assert continues() == 0, "the pool is still empty"

    auth = account!()
    Server.tick(DateTime.utc_now())
    assert continues() == 1
    assert %Stall{state: "nudged", stalled_at: ^first} = stall(ctx)

    # The continue was refused too (the account went again): same incident, no second one.
    Repo.delete!(auth)
    ClaudiverseServer.Proxy.Credentials.reset()
    {:ok, %{status: 429}} = model_call(ctx, pooled: true)
    go_idle(seat)
    account!()
    Server.tick(DateTime.utc_now())
    send(Server, {"pool", %{"change" => "upgrade"}})
    assert continues() == 0
    assert %Stall{state: "nudged"} = stall(ctx)

    # An account's weekly reset is new capacity: one more.
    send(Server, {"pool", %{"change" => "reset", "limit" => "session"}})
    assert continues() == 0, "a 5-hour reset re-arms nothing"
    send(Server, {"pool", %{"change" => "reset", "limit" => "weekly"}})
    assert continues() == 1
    go_idle(seat)
    Server.tick(DateTime.utc_now())
    assert continues() == 0, "nudged once for this reset"
  end

  test "a restart incident whose continue meets an empty pool becomes a pool incident", ctx do
    restart_mid_stream(ctx)

    [_] = Server.boot(DateTime.add(DateTime.utc_now(), -120, :second))
    seat = seat(ctx, true)
    Server.tick(DateTime.utc_now())
    assert continues() == 1

    {:ok, %{status: 429}} = model_call(ctx, pooled: true)
    assert %Stall{state: "stalled", reason: "no_available_auth"} = stall(ctx)
    go_idle(seat)
    account!()
    Server.tick(DateTime.utc_now())
    assert continues() == 1
  end

  test "only the main loop's calls count: a subagent's or a title's refusal opens nothing", ctx do
    {:ok, %{status: 429}} = model_call(ctx, pooled: true, agent: "agent-1")
    {:ok, %{status: 429}} = model_call(ctx, pooled: true, tools: [])
    assert stall(ctx) == nil

    assert Request.main_loop?([], ~s({"tools":[{"name":"Bash"}],"messages":[]}))
    refute Request.main_loop?([], ~s({"tools":[],"messages":[{"content":"quota"}]}))
    refute Request.main_loop?([], ~s({"messages":[{"content":"say \\"tools\\":[{ here"}]}))
    refute Request.main_loop?([{"x-claude-code-agent-id", "a1"}], ~s({"tools":[{"name":"Bash"}]}))
    assert Request.main_loop?([{"x-claude-code-request-class", "compaction"}], "{}")
    refute Request.main_loop?([{"x-claude-code-request-class", "auxiliary"}], ~s({"tools":[{"name":"Bash"}]}))
  end

  test "with tracking off the proxy reports nothing", ctx do
    Application.put_env(:claudiverse_server, AutoResume, enabled: false, track: false)
    {:ok, %{status: 200}} = model_call(ctx)
    {:ok, %{status: 429}} = model_call(ctx, pooled: true)
    assert stall(ctx) == nil
  end
end
