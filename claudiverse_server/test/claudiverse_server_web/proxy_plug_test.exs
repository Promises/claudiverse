defmodule ClaudiverseServerWeb.ProxyPlugTest.MockUpstream do
  @moduledoc false
  # A stand-in for api.anthropic.com. Records what it received and answers by
  # the `x-test-scenario` header.
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, body, conn} = read_body(conn, length: 100_000_000)
    owner = :persistent_term.get({__MODULE__, :owner})
    send(owner, {:upstream_saw, %{method: conn.method, path: conn.request_path, query: conn.query_string, headers: conn.req_headers, body: body}})
    scenario = get_req_header(conn, "x-test-scenario") |> List.first() || "text"
    bearer = get_req_header(conn, "authorization") |> List.first()

    # Pool scenarios: TOKEN-AAA is the exhausted account, anything else works.
    scenario =
      case {scenario, bearer} do
        {"pool", "Bearer TOKEN-AAA"} -> "429-exhausted"
        {"pool-transient", "Bearer TOKEN-AAA"} -> "429-short"
        {"pool" <> _, _} -> "text"
        _ -> scenario
      end
    rl = [{"anthropic-ratelimit-unified-5h-utilization", "0.42"}, {"anthropic-ratelimit-unified-status", "allowed"}]

    case {conn.request_path, scenario} do
      {"/api/" <> _, _} ->
        send_resp(conn, 200, "{}")

      {_, "429"} ->
        b = Jason.encode!(%{type: "error", error: %{type: "rate_limit_error", message: "slow down"}})
        conn |> merge_resp_headers([{"content-type", "application/json"} | rl]) |> send_resp(429, b)

      {_, "429-exhausted"} ->
        # Give a concurrent request time to be in flight on the same account.
        Process.sleep(80)
        reset = System.os_time(:second) + 7200
        b = Jason.encode!(%{type: "error", error: %{type: "rate_limit_error", message: "limit reached"}})

        conn
        |> merge_resp_headers([{"content-type", "application/json"},
                               {"anthropic-ratelimit-unified-status", "rejected"},
                               {"anthropic-ratelimit-unified-reset", Integer.to_string(reset)}])
        |> send_resp(429, b)

      {_, "429-short"} ->
        b = Jason.encode!(%{type: "error", error: %{type: "rate_limit_error", message: "slow down briefly"}})

        conn
        |> merge_resp_headers([{"content-type", "application/json"},
                               {"anthropic-ratelimit-unified-reset", Integer.to_string(System.os_time(:second) + 5)}])
        |> send_resp(429, b)

      {_, "sse_error"} ->
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
        {:ok, conn} = chunk(conn, "event: ping\ndata: {\"type\":\"ping\"}\n\n")
        {:ok, conn} = chunk(conn, "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n")
        conn

      {_, "slow"} ->
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
        Enum.reduce_while(1..250, conn, fn _, conn ->
          Process.sleep(20)
          case chunk(conn, "event: ping\ndata: {\"type\":\"ping\"}\n\n") do
            {:ok, conn} -> {:cont, conn}
            {:error, _} -> {:halt, conn}
          end
        end)

      {_, s} ->
        b =
          case s do
            "tool" -> tool_turn("Bash", %{command: "ls -la"})
            "ask" -> tool_turn("AskUserQuestion", %{questions: [%{question: "RED or BLUE?"}]})
            _ -> text_turn("Hello there")
          end

        send(owner, {:upstream_sent, b})
        conn = conn |> merge_resp_headers([{"content-type", "text/event-stream"} | rl]) |> send_chunked(200)
        # Two pieces, so the proxy really streams rather than relaying one blob.
        {:ok, conn} = chunk(conn, binary_part(b, 0, 200))
        Process.sleep(5)
        {:ok, conn} = chunk(conn, binary_part(b, 200, byte_size(b) - 200))
        conn
    end
  end

  def sse(events), do: Enum.map_join(events, "", &"event: #{&1.type}\ndata: #{Jason.encode!(&1)}\n\n")

  def text_turn(text) do
    sse([
      %{type: "message_start", message: %{id: "msg_1", type: "message", role: "assistant", model: "claude-test", content: [], usage: %{input_tokens: 10}}},
      %{type: "content_block_start", index: 0, content_block: %{type: "thinking", thinking: ""}},
      %{type: "content_block_delta", index: 0, delta: %{type: "thinking_delta", thinking: "pondering"}},
      %{type: "content_block_stop", index: 0},
      %{type: "content_block_start", index: 1, content_block: %{type: "text", text: ""}},
      %{type: "content_block_delta", index: 1, delta: %{type: "text_delta", text: String.slice(text, 0, 3)}},
      %{type: "content_block_delta", index: 1, delta: %{type: "text_delta", text: String.slice(text, 3..-1//1)}},
      %{type: "content_block_stop", index: 1},
      %{type: "message_delta", delta: %{stop_reason: "end_turn"}, usage: %{output_tokens: 7}},
      %{type: "message_stop"}
    ])
  end

  def tool_turn(name, input) do
    json = Jason.encode!(input)

    sse([
      %{type: "message_start", message: %{id: "msg_2", type: "message", role: "assistant", model: "claude-test", content: [], usage: %{}}},
      %{type: "content_block_start", index: 0, content_block: %{type: "tool_use", id: "toolu_X", name: name, input: %{}}},
      %{type: "content_block_delta", index: 0, delta: %{type: "input_json_delta", partial_json: String.slice(json, 0, 5)}},
      %{type: "content_block_delta", index: 0, delta: %{type: "input_json_delta", partial_json: String.slice(json, 5..-1//1)}},
      %{type: "content_block_stop", index: 0},
      %{type: "message_delta", delta: %{stop_reason: "tool_use"}, usage: %{output_tokens: 3}},
      %{type: "message_stop"}
    ])
  end
end

defmodule ClaudiverseServerWeb.ProxyPlugTest.Front do
  @moduledoc false
  # The proxy plug alone, as the endpoint mounts it, plus a 404 for the rest.
  def init(opts), do: opts

  def call(conn, _opts) do
    conn = ClaudiverseServerWeb.ProxyPlug.call(conn, [])
    if conn.halted, do: conn, else: Plug.Conn.send_resp(conn, 404, "not proxied")
  end
end

defmodule ClaudiverseServerWeb.ProxyPlugTest do
  use ClaudiverseServer.DataCase, async: false

  import ClaudiverseServer.Fixtures
  import Ecto.Query

  alias ClaudiverseServer.Proxy.Request
  alias ClaudiverseServer.Repo
  alias ClaudiverseServer.Sessions.{Message, Room, Session}
  alias ClaudiverseServerWeb.ProxyPlugTest.MockUpstream

  @idle_ms 60
  @secret "Bearer test-oauth-token-not-a-real-credential"
  @tools for i <- 1..3, do: %{name: "T#{i}", input_schema: %{type: "object"}}

  setup do
    :persistent_term.put({MockUpstream, :owner}, self())
    {:ok, up} = Bandit.start_link(plug: MockUpstream, port: 0, ip: :loopback, startup_log: false)
    {:ok, {_, up_port}} = ThousandIsland.listener_info(up)
    {:ok, front} = Bandit.start_link(plug: ClaudiverseServerWeb.ProxyPlugTest.Front, port: 0, ip: :loopback, startup_log: false)
    {:ok, {_, port}} = ThousandIsland.listener_info(front)

    prev = {Application.get_env(:claudiverse_server, :proxy_upstream), Application.get_env(:claudiverse_server, :proxy_idle_ms)}
    Application.put_env(:claudiverse_server, :proxy_upstream, "http://127.0.0.1:#{up_port}")
    Application.put_env(:claudiverse_server, :proxy_idle_ms, @idle_ms)

    {user, token} = user_with_token()
    ClaudiverseServer.Proxy.Credentials.reset()

    on_exit(fn ->
      # Observers, then the Rooms they started: both outlive the test otherwise
      # and write after the sandbox owner has gone.
      # Drain first (a synchronous call returns only after every earlier cast
      # is handled): killing one mid-insert leaves the sandbox a dead client.
      sups = [ClaudiverseServer.Proxy.Supervisor, ClaudiverseServer.Sessions.Supervisor]

      for sup <- sups, {_, pid, _, _} <- DynamicSupervisor.which_children(sup), is_pid(pid) do
        try do
          :sys.get_state(pid, 5_000)
        catch
          :exit, _ -> :ok
        end
      end

      for sup <- sups, {_, pid, _, _} <- DynamicSupervisor.which_children(sup), is_pid(pid),
          do: DynamicSupervisor.terminate_child(sup, pid)

      {u, i} = prev
      if u, do: Application.put_env(:claudiverse_server, :proxy_upstream, u), else: Application.delete_env(:claudiverse_server, :proxy_upstream)
      if i, do: Application.put_env(:claudiverse_server, :proxy_idle_ms, i), else: Application.delete_env(:claudiverse_server, :proxy_idle_ms)
    end)

    %{base: "http://127.0.0.1:#{port}", user: user, token: token}
  end

  # --- helpers ---------------------------------------------------------------

  defp send_msgs(ctx, sid, messages, opts \\ []) do
    headers =
      [
        {"content-type", "application/json"},
        {"authorization", Keyword.get(opts, :bearer, @secret)},
        # What a real client advertises. Bandit can stream deflate (not gzip), so a
        # gzip-only client would hide re-encoding of the relayed SSE stream.
        {"accept-encoding", "gzip, deflate, br, zstd"},
        {"x-claude-code-session-id", sid},
        {"x-test-scenario", Keyword.get(opts, :scenario, "text")}
      ] ++
        if(Keyword.get(opts, :auth, true), do: [{"x-claudiverse-token", ctx.token}], else: []) ++
        if(c = opts[:class], do: [{"x-claude-code-request-class", c}], else: []) ++
        if(a = opts[:agent], do: [{"x-claude-code-agent-id", a}], else: []) ++
        if(pv = opts[:provides], do: [{"x-claudiverse-provides", pv}], else: []) ++
        Keyword.get(opts, :headers, [])

    body =
      Jason.encode!(%{
        model: "claude-test",
        max_tokens: 1000,
        stream: true,
        tools: Keyword.get(opts, :tools, @tools),
        messages: messages,
        metadata: %{user_id: Jason.encode!(%{device_id: "d", account_uuid: Keyword.get(opts, :acct, "acct-1")})}
      })

    url = "#{ctx.base}/proxy/seat/#{Keyword.get(opts, :seat, "seat-a")}/v1/messages?beta=true"
    {:ok, resp} = Finch.build(:post, url, headers, body) |> Finch.request(ClaudiverseServer.Proxy.Finch)
    resp
  end

  defp user_msg(text), do: %{role: "user", content: [%{type: "text", text: text}]}

  defp proxy_session(sid), do: Repo.one(from s in Session, where: s.claude_session_id == ^("proxy:" <> sid))

  defp messages(sid) do
    case proxy_session(sid) do
      nil -> []
      s -> Repo.all(from m in Message, where: m.session_id == ^s.id, order_by: m.sequence) |> Enum.map(& &1.payload)
    end
  end

  defp types(sid), do: Enum.map(messages(sid), & &1["type"])

  defp eventually(fun, tries \\ 60) do
    case fun.() do
      x when x in [nil, false] ->
        if tries == 0, do: flunk("condition never held"), else: (Process.sleep(25); eventually(fun, tries - 1))

      x ->
        x
    end
  end

  defp observer_state(sid) do
    eventually(fn -> Enum.find(ClaudiverseServer.Proxy.Observer.status(), &(&1.claude_session_id == sid)) end)
  end

  # --- unit ------------------------------------------------------------------

  test "route strips the seat prefix" do
    assert Request.route(["seat", "lorem-w1", "v1", "messages"], []) == {"lorem-w1", "/v1/messages"}
    assert Request.route(["v1", "messages"], [{"x-claudiverse-seat", "h"}]) == {"h", "/v1/messages"}
  end

  test "classify prefers upstream's own request-class header, then falls back" do
    assert Request.classify([{"x-claude-code-request-class", "auxiliary"}], %{"tools" => [1]}) == "auxiliary"
    assert Request.classify([{"x-claude-code-agent-id", "a1"}], %{"tools" => [1]}) == "subagent"
    assert Request.classify([], %{"max_tokens" => 1, "tools" => []}) == "probe"
    assert Request.classify([], %{"tools" => []}) == "auxiliary"
    assert Request.classify([], %{"tools" => [1]}) == "main"
  end

  test "assistant/2 rebuilds text, thinking and tool input across deltas" do
    t = Request.assistant("text/event-stream", MockUpstream.text_turn("Hello there"))
    assert [%{"thinking" => "pondering"}, %{"text" => "Hello there"}] = t["content"]
    assert t["stop_reason"] == "end_turn"
    u = Request.assistant("text/event-stream", MockUpstream.tool_turn("Bash", %{command: "ls -la"}))
    assert [%{"input" => %{"command" => "ls -la"}}] = u["content"]
  end

  # --- end to end ------------------------------------------------------------

  test "bytes pass through unchanged; seat, token and encoding headers stay here", ctx do
    resp = send_msgs(ctx, "s-pass", [user_msg("hello-marker")])
    assert resp.status == 200
    assert_receive {:upstream_sent, sent}
    assert resp.body == sent
    refute List.keyfind(resp.headers, "content-encoding", 0), "the relayed stream was re-encoded"
    assert_receive {:upstream_saw, up}
    assert up.path == "/v1/messages" and up.query == "beta=true"
    assert List.keyfind(up.headers, "authorization", 0) == {"authorization", @secret}
    for h <- ~w(x-claudiverse-token x-claudiverse-seat accept-encoding), do: refute List.keyfind(up.headers, h, 0)
  end

  test "without a claudiverse token the request is refused and never reaches upstream", ctx do
    resp = send_msgs(ctx, "s-noauth", [user_msg("x")], auth: false)
    assert resp.status == 403
    assert %{"type" => "error", "error" => %{"type" => "permission_error"}} = Jason.decode!(resp.body)
    refute_receive {:upstream_saw, _}, 100
  end

  test "a main turn is mirrored into its own proxy: room and settles idle", ctx do
    send_msgs(ctx, "s-turn", [user_msg("first prompt")])
    eventually(fn -> "idle" in types("s-turn") end)
    assert types("s-turn") == ["user", "assistant", "turn_complete", "idle"]
    [u, a | _] = messages("s-turn")
    assert [%{"text" => "first prompt"}] = u["message"]["content"]
    assert [%{"thinking" => "pondering"}, %{"text" => "Hello there"}] = a["message"]["content"]

    session = proxy_session("s-turn")
    assert session.title == "proxy:seat-a" and session.type == :proxy
    assert Room.get_status(session.id).idle == true
    st = observer_state("s-turn")
    assert st.account == "acct-1"
    assert st.ratelimit["anthropic-ratelimit-unified-5h-utilization"] == "0.42"
  end

  test "the real seat's sidecar row, same Claude session id, gets nothing", ctx do
    real = session_fixture(ctx.user, %{title: "seat-a", claude_session_id: "s-shared"})
    send_msgs(ctx, "s-shared", [user_msg("hi")])
    eventually(fn -> "idle" in types("s-shared") end)
    assert proxy_session("s-shared").id != real.id
    assert Repo.aggregate(from(m in Message, where: m.session_id == ^real.id), :count) == 0
  end

  test "a tool turn is 'tool'; only the tool result is mirrored from the next request", ctx do
    m1 = [user_msg("list files")]
    send_msgs(ctx, "s-tool", m1, scenario: "tool")
    assert eventually(fn -> observer_state("s-tool").state == "tool" end)
    m2 = m1 ++ [%{role: "assistant", content: [%{type: "tool_use", id: "toolu_X", name: "Bash", input: %{}}]},
                %{role: "user", content: [%{type: "tool_result", tool_use_id: "toolu_X", content: "a.txt"}]}]
    send_msgs(ctx, "s-tool", m2)
    eventually(fn -> "idle" in types("s-tool") end)
    users = Enum.filter(messages("s-tool"), &(&1["type"] == "user"))
    assert length(users) == 2
    assert [%{"type" => "tool_result"}] = List.last(users)["message"]["content"]
  end

  test "a queued follow-up inside the debounce never reports a false idle", ctx do
    send_msgs(ctx, "s-q", [user_msg("one")])
    Process.sleep(div(@idle_ms, 3))
    send_msgs(ctx, "s-q", [user_msg("one"), %{role: "assistant", content: []}, user_msg("two")])
    Process.sleep(@idle_ms * 4)
    assert Enum.count(types("s-q"), &(&1 == "idle")) == 1
    assert List.last(types("s-q")) == "idle"
  end

  test "AskUserQuestion leaves the seat in 'question', not idle", ctx do
    send_msgs(ctx, "s-ask", [user_msg("ask me")], scenario: "ask")
    assert eventually(fn -> observer_state("s-ask").state == "question" end)
    Process.sleep(@idle_ms * 3)
    refute "idle" in types("s-ask")
    assert Enum.any?(messages("s-ask"), &(get_in(&1, ["message", "content", Access.at(0), "name"]) == "AskUserQuestion"))
  end

  test "auxiliary requests are never mirrored as conversation", ctx do
    send_msgs(ctx, "s-aux", [user_msg("name this session")], class: "auxiliary")
    send_msgs(ctx, "s-aux2", [user_msg("predict the next prompt")], tools: [])
    Process.sleep(@idle_ms * 3)
    # The only thing a side request may produce is a fresh seat's startup idle.
    assert types("s-aux") in [[], ["idle"]] and types("s-aux2") in [[], ["idle"]]
  end

  test "compaction emits compact; a shorter history afterwards is a context reset", ctx do
    send_msgs(ctx, "s-cmp", [user_msg("a"), %{role: "assistant", content: []}, user_msg("b")])
    send_msgs(ctx, "s-cmp", [user_msg("summarise")], class: "compaction")
    send_msgs(ctx, "s-cmp", [user_msg("summary + continue")])
    eventually(fn -> "proxy_context_reset" in types("s-cmp") end)
    assert "compact" in types("s-cmp")
  end

  test "subagent traffic is mirrored on its own thread and leaves main readiness alone", ctx do
    send_msgs(ctx, "s-sub", [user_msg("main prompt")])
    eventually(fn -> "idle" in types("s-sub") end)
    send_msgs(ctx, "s-sub", [user_msg("subagent task")], class: "subagent", agent: "agent-7")
    eventually(fn -> Enum.any?(messages("s-sub"), &(&1["proxy_thread"] == "agent:agent-7")) end)
    st = observer_state("s-sub")
    assert st.state == "idle" and st.subagent_active == true
  end

  test "a 429 is mirrored as an api error and the seat settles idle", ctx do
    resp = send_msgs(ctx, "s-429", [user_msg("go")], scenario: "429")
    assert resp.status == 429
    eventually(fn -> "idle" in types("s-429") end)
    err = Enum.find(messages("s-429"), &(&1["type"] == "proxy_api_error"))
    assert err["status"] == 429 and err["error"]["type"] == "rate_limit_error"
  end

  test "a client hang-up mid-stream is an interrupt, then idle", ctx do
    headers = [{"content-type", "application/json"}, {"x-claude-code-session-id", "s-int"},
               {"x-test-scenario", "slow"}, {"x-claudiverse-token", ctx.token}]
    body = Jason.encode!(%{model: "m", max_tokens: 10, tools: @tools, messages: [user_msg("long")]})

    {:ok, _} =
      Finch.build(:post, "#{ctx.base}/proxy/seat/seat-a/v1/messages", headers, body)
      |> Finch.stream_while(ClaudiverseServer.Proxy.Finch, nil, fn
        {:data, _}, acc -> {:halt, acc}
        _, acc -> {:cont, acc}
      end)

    eventually(fn -> "idle" in types("s-int") end, 200)
    assert "proxy_interrupted" in types("s-int")
  end

  # Claude Code calls every one of these "Server error mid-response"; the log
  # must say which it was.
  test "an error event inside a 200 stream is logged as the upstream's", ctx do
    log = ExUnit.CaptureLog.capture_log(fn -> assert send_msgs(ctx, "s-sse", [user_msg("go")], scenario: "sse_error").status == 200 end)
    assert log =~ "upstream sent an error event mid-stream"
    assert log =~ "overloaded_error"
    # A clean stream logs nothing of the kind.
    refute ExUnit.CaptureLog.capture_log(fn -> send_msgs(ctx, "s-ok", [user_msg("go")]) end) =~ "mid-stream"
  end

  test "an account switch is noticed", ctx do
    send_msgs(ctx, "s-acct", [user_msg("a")], acct: "acct-1")
    send_msgs(ctx, "s-acct", [user_msg("a"), %{role: "assistant", content: []}, user_msg("b")], acct: "acct-2")
    sw = eventually(fn -> Enum.find(messages("s-acct"), &(&1["type"] == "proxy_account_changed")) end)
    assert {sw["from"], sw["to"]} == {"acct-1", "acct-2"}
  end

  test "non-message paths pass through without observation", ctx do
    {:ok, resp} =
      Finch.build(:get, "#{ctx.base}/proxy/seat/seat-a/api/hello", [{"x-claudiverse-token", ctx.token}])
      |> Finch.request(ClaudiverseServer.Proxy.Finch)

    assert resp.status == 200
    assert_receive {:upstream_saw, %{path: "/api/hello"}}
  end

  test "the reachability probe needs no token and never reaches upstream; nothing else does", ctx do
    for method <- [:head, :get] do
      {:ok, resp} = Finch.build(method, "#{ctx.base}/proxy/seat/seat-a/api/hello") |> Finch.request(ClaudiverseServer.Proxy.Finch)
      assert resp.status == 200
    end

    refute_receive {:upstream_saw, _}, 100
    {:ok, resp} = Finch.build(:get, "#{ctx.base}/proxy/seat/seat-a/api/other") |> Finch.request(ClaudiverseServer.Proxy.Finch)
    assert resp.status == 403
  end

  test "an unreachable upstream answers 502 in the API's error shape", ctx do
    Application.put_env(:claudiverse_server, :proxy_upstream, "http://127.0.0.1:1")
    resp = send_msgs(ctx, "s-dead", [user_msg("x")])
    assert resp.status == 502
    assert %{"type" => "error", "error" => %{"type" => "api_error"}} = Jason.decode!(resp.body)
  end

  test "the first sight mirrors the operator's prompt, not the trailing system block or reminders", ctx do
    # The shape measured on 2.1.286: reminders around the typed prompt, and a
    # role "system" environment block AFTER the user message.
    first = [
      %{role: "user", content: [
        %{type: "text", text: "<system-reminder>\nCLAUDE.md contents\n</system-reminder>"},
        %{type: "text", text: "the typed prompt"},
        %{type: "text", text: "  <system-reminder>skills</system-reminder>"}
      ]},
      %{role: "system", content: [%{type: "text", text: "# Environment\nYou have been invoked in..."}]}
    ]

    send_msgs(ctx, "s-first", first)
    eventually(fn -> "idle" in types("s-first") end)
    [u | _] = messages("s-first")
    assert u["type"] == "user"
    assert [%{"text" => "the typed prompt"}] = u["message"]["content"]
    assert u["message"]["proxy_reminders_dropped"] == 2
  end

  # The exact string Claude Code 2.1.286 stored for an inbox prompt (seat
  # semi-inbox-1's transcript, 2026-10-02).
  @inbox_note "<task-notification>\n<summary>claudiverse message</summary>\n</task-notification>\n" <>
                "<system-reminder>\nMessage from the claudiverse orchestrator: Reply with exactly: INBOX-OK\n</system-reminder>"

  # The shape measured in a live request (8a7e72c): an outer reminder with the
  # inner one HTML-escaped. Prompt text with <, > and & is escaped as well.
  @inbox_note_escaped "<system-reminder>\n<task-notification>\n<summary>claudiverse message</summary>\n</task-notification>\n" <>
                        "&lt;system-reminder&gt;\nMessage from the claudiverse orchestrator: Reply with exactly: INBOX-OK\n" <>
                        "&lt;/system-reminder&gt;\n</system-reminder>"

  test "an escaped inbox prompt is unescaped: <, > and & survive the trip", ctx do
    note = "<system-reminder>\n&lt;system-reminder&gt;\nMessage from the claudiverse orchestrator: if a &lt; b &amp;&amp; c &gt; d\n&lt;/system-reminder&gt;\n</system-reminder>"
    send_msgs(ctx, "s-inbox-esc", [%{role: "user", content: [%{type: "text", text: note}]}])
    eventually(fn -> "idle" in types("s-inbox-esc") end)
    assert user_texts("s-inbox-esc") == ["if a < b && c > d"]
  end

  defp user_texts(seat) do
    for %{"type" => "user", "message" => %{"content" => c}} <- messages(seat), %{"text" => t} <- List.wrap(c), do: t
  end

  test "an inbox prompt is mirrored as a user prompt, without its notification wrapper", ctx do
    for {label, content} <- [string: @inbox_note,
                             block: [%{type: "text", text: @inbox_note}],
                             rewrapped: [%{type: "text", text: "<system-reminder>\n" <> @inbox_note <> "\n</system-reminder>"}],
                             escaped: [%{type: "text", text: @inbox_note_escaped}]] do
      seat = "s-inbox-#{label}"
      send_msgs(ctx, seat, [%{role: "user", content: content}])
      eventually(fn -> "idle" in types(seat) end)
      assert user_texts(seat) == ["Reply with exactly: INBOX-OK"], "#{label}: #{inspect(user_texts(seat))}"
      assert [%{"message" => %{"proxy_source" => "inbox"}}] = Enum.filter(messages(seat), &(&1["type"] == "user"))
    end
  end

  test "an inbox prompt landing mid-turn is pulled out of the tool result it rides on", ctx do
    m1 = [user_msg("work")]
    send_msgs(ctx, "s-inbox-mid", m1, scenario: "tool")
    assert eventually(fn -> observer_state("s-inbox-mid").state == "tool" end)

    m2 = m1 ++ [%{role: "assistant", content: [%{type: "tool_use", id: "toolu_M", name: "Bash", input: %{}}]},
                %{role: "user", content: [
                  %{type: "tool_result", tool_use_id: "toolu_M", content: [%{type: "text", text: "(no output)"}, %{type: "text", text: @inbox_note}]}]}]
    send_msgs(ctx, "s-inbox-mid", m2)
    eventually(fn -> "idle" in types("s-inbox-mid") end)

    users = Enum.filter(messages("s-inbox-mid"), &(&1["type"] == "user"))
    assert [%{"type" => "tool_result", "content" => [%{"text" => "(no output)"}]}] = Enum.at(users, 1)["message"]["content"]
    assert List.last(users)["message"]["content"] == [%{"type" => "text", "text" => "Reply with exactly: INBOX-OK"}]
  end

  test "a /compact at the prompt leaves the seat idle in its Room", ctx do
    send_msgs(ctx, "s-cidle", [user_msg("hi")])
    eventually(fn -> "idle" in types("s-cidle") end)
    session = proxy_session("s-cidle")
    assert Room.get_status(session.id).idle == true

    send_msgs(ctx, "s-cidle", [user_msg("summarise")], class: "compaction")
    eventually(fn -> Enum.any?(messages("s-cidle"), &(&1["proxy_thread"] == "compaction")) end)
    assert eventually(fn -> Room.get_status(session.id).idle == true end)
  end

  test "the Authorization value is never stored (with a positive control)", ctx do
    send_msgs(ctx, "s-secret", [user_msg("hello-marker")])
    eventually(fn -> "idle" in types("s-secret") end)
    stored = Repo.all(from m in Message, select: m.payload) |> Jason.encode!()
    assert stored =~ "hello-marker", "control: the scan must find a string that IS stored"
    refute stored =~ "SEEDED-SECRET"
  end

  # --- pooled seats (credentials from the pool) ------------------------------

  alias ClaudiverseServer.AnthropicAuths
  alias ClaudiverseServer.AnthropicAuths.{AnthropicAuth, Vault}

  defp pool_account!(label, priority, token) do
    Repo.insert!(%AnthropicAuth{
      label: label, priority: priority, status: "available", scopes: "user:inference",
      access_token: Vault.encrypt(token),
      expires_at: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    })
  end

  defp upstream_bearers do
    Stream.repeatedly(fn ->
      receive do
        {:upstream_saw, %{headers: h}} -> List.keyfind(h, "authorization", 0) |> elem(1)
      after
        50 -> nil
      end
    end)
    |> Enum.take_while(& &1)
  end

  defp pooled(opts), do: Keyword.merge([bearer: "Bearer cv-pool"], opts)

  test "a pooled seat's placeholder is swapped for the pool token and never sent upstream", ctx do
    pool_account!("Work", 10, "TOKEN-BBB")
    resp = send_msgs(ctx, "s-pool", [user_msg("hi")], pooled(scenario: "pool"))
    assert resp.status == 200
    assert upstream_bearers() == ["Bearer TOKEN-BBB"]
  end

  # A seat with its own login (flags, the mod) that asks for the pool by header.
  @own_login [bearer: "Bearer SEAT-OWN-LOGIN", headers: [{"x-claudiverse-pool", "1"}]]

  test "X-Claudiverse-Pool: the seat's own login is replaced by the pool token, never relayed", ctx do
    pool_account!("Work", 10, "TOKEN-BBB")
    resp = send_msgs(ctx, "s-hdr", [user_msg("hi")], Keyword.merge(@own_login, scenario: "pool"))
    assert resp.status == 200
    assert upstream_bearers() == ["Bearer TOKEN-BBB"]
  end

  test "X-Claudiverse-Pool fails over like the placeholder", ctx do
    pool_account!("Personal", 10, "TOKEN-AAA")
    pool_account!("Work", 20, "TOKEN-BBB")
    resp = send_msgs(ctx, "s-hdr-fo", [user_msg("hi")], Keyword.merge(@own_login, scenario: "pool"))
    assert resp.status == 200
    assert upstream_bearers() == ["Bearer TOKEN-AAA", "Bearer TOKEN-BBB"]
  end

  test "without the header a seat's own login goes upstream untouched (control)", ctx do
    pool_account!("Work", 10, "TOKEN-BBB")
    send_msgs(ctx, "s-own", [user_msg("hi")], bearer: "Bearer SEAT-OWN-LOGIN", scenario: "pool")
    assert upstream_bearers() == ["Bearer SEAT-OWN-LOGIN"]
  end

  test "X-Claudiverse-Observe: off relays without recording, and the opt-in headers stay here", ctx do
    pool_account!("Work", 10, "TOKEN-BBB")
    opts = [bearer: "Bearer SEAT-OWN-LOGIN", scenario: "pool",
            headers: [{"x-claudiverse-pool", "1"}, {"x-claudiverse-observe", "off"}]]
    assert send_msgs(ctx, "s-quiet", [user_msg("hi")], opts).status == 200

    assert_receive {:upstream_saw, %{headers: h}}
    refute List.keyfind(h, "x-claudiverse-pool", 0)
    refute List.keyfind(h, "x-claudiverse-observe", 0)
    Process.sleep(200)
    assert proxy_session("s-quiet") == nil

    # Control: the same request observed creates its proxy row.
    send_msgs(ctx, "s-loud", [user_msg("hi")], Keyword.merge(@own_login, scenario: "pool"))
    eventually(fn -> proxy_session("s-loud") != nil end)
  end

  test "an exhausted account fails over inside the proxy; the client never sees the 429", ctx do
    a = pool_account!("Personal", 10, "TOKEN-AAA")
    pool_account!("Work", 20, "TOKEN-BBB")

    resp = send_msgs(ctx, "s-fo", [user_msg("hi")], pooled(scenario: "pool"))
    assert resp.status == 200
    assert_receive {:upstream_sent, sent}
    assert resp.body == sent
    assert upstream_bearers() == ["Bearer TOKEN-AAA", "Bearer TOKEN-BBB"]

    a = Repo.get!(AnthropicAuth, a.id)
    assert a.status == "cooling_down"
    assert a.cooldown_reason =~ "429 via proxy"
    assert DateTime.diff(a.cooldown_until, DateTime.utc_now()) > 3600, "the API's reset time must be used"

    eventually(fn -> "idle" in types("s-fo") end)
    refute "proxy_api_error" in types("s-fo")

    vias = AnthropicAuths.list_assignments() |> Enum.filter(&(&1.title == "seat-a")) |> Enum.map(& &1.via)
    assert "proxy-failover" in vias
  end

  test "two requests in flight on an exhausted account cool it once, not the account they move to", ctx do
    a = pool_account!("Personal", 10, "TOKEN-AAA")
    b = pool_account!("Work", 20, "TOKEN-BBB")

    [r1, r2] =
      for sid <- ["s-race1", "s-race2"] do
        Task.async(fn -> send_msgs(ctx, sid, [user_msg("go")], pooled(scenario: "pool")) end)
      end
      |> Task.await_many(15_000)

    assert {r1.status, r2.status} == {200, 200}
    assert Repo.get!(AnthropicAuth, a.id).status == "cooling_down"
    assert Repo.get!(AnthropicAuth, b.id).status == "available", "the rescuing account was cooled by an in-flight 429"
  end

  test "a short, unexplained 429 is relayed and cools nothing", ctx do
    a = pool_account!("Personal", 10, "TOKEN-AAA")
    pool_account!("Work", 20, "TOKEN-BBB")

    resp = send_msgs(ctx, "s-short", [user_msg("hi")], pooled(scenario: "pool-transient"))
    assert resp.status == 429
    assert upstream_bearers() == ["Bearer TOKEN-AAA"]
    assert Repo.get!(AnthropicAuth, a.id).status == "available"
  end

  test "with every account cooling, a pooled request is refused without reaching upstream", ctx do
    Repo.insert!(%AnthropicAuth{label: "Personal", priority: 10, status: "cooling_down",
      cooldown_until: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)})

    resp = send_msgs(ctx, "s-none", [user_msg("hi")], pooled(scenario: "pool"))
    assert resp.status == 429
    assert %{"error" => %{"type" => "rate_limit_error", "message" => "cv-proxy: no pool account" <> _}} = Jason.decode!(resp.body)
    assert upstream_bearers() == []
  end

  test "pool tokens are never stored in mirrored messages", ctx do
    pool_account!("Personal", 10, "TOKEN-AAA")
    pool_account!("Work", 20, "TOKEN-BBB")
    send_msgs(ctx, "s-ptok", [user_msg("hello-marker")], pooled(scenario: "pool"))
    eventually(fn -> "idle" in types("s-ptok") end)
    stored = Repo.all(from m in Message, select: m.payload) |> Jason.encode!()
    assert stored =~ "hello-marker"
    refute stored =~ "TOKEN-AAA"
    refute stored =~ "TOKEN-BBB"
  end

  # --- primary mode: a seat that retired patches -------------------------------

  defp row_messages(session_id) do
    Repo.all(from m in Message, where: m.session_id == ^session_id, order_by: m.sequence) |> Enum.map(& &1.payload)
  end

  test "provides=mirror writes the conversation into the seat's own row, nothing else", ctx do
    own = session_fixture(ctx.user, %{title: "seat-a", claude_session_id: "s-prim"})
    send_msgs(ctx, "s-prim", [user_msg("primary prompt")], provides: "mirror")
    eventually(fn -> "turn_complete" in Enum.map(row_messages(own.id), & &1["type"]) end)
    Process.sleep(@idle_ms * 3)

    types = Enum.map(row_messages(own.id), & &1["type"])
    assert types == ["user", "assistant", "turn_complete"], "readiness stays with the seat's 008 until handed over: #{inspect(types)}"
    assert proxy_session("s-prim") == nil, "no shadow row in primary mode"
    assert Repo.aggregate(from(x in Session, where: x.claude_session_id == "s-prim"), :count) == 1
  end

  test "primary mode creates the seat's row when the proxy is first, and the sidecar then reuses it", ctx do
    send_msgs(ctx, "s-first-prim", [user_msg("hi")], provides: "mirror")
    row = eventually(fn -> Repo.one(from x in Session, where: x.claude_session_id == "s-first-prim") end)
    assert row.title == "seat-a" and row.type == :sidecar

    {:ok, again} = ClaudiverseServer.Sessions.create_session(%{title: "seat-a", type: :sidecar, mode: :json, status: :running,
                                                             claude_session_id: "s-first-prim", user_id: ctx.user.id})
    assert again.id == row.id
  end

  test "provides=mirror,idle,compact hands readiness over too", ctx do
    own = session_fixture(ctx.user, %{title: "seat-a", claude_session_id: "s-all"})
    send_msgs(ctx, "s-all", [user_msg("hi")], provides: "mirror,idle,compact")
    eventually(fn -> "idle" in Enum.map(row_messages(own.id), & &1["type"]) end)
    assert Room.get_status(own.id).idle == true
  end

  test "unknown provides names are ignored: the seat stays in shadow mode", ctx do
    own = session_fixture(ctx.user, %{title: "seat-a", claude_session_id: "s-unk"})
    send_msgs(ctx, "s-unk", [user_msg("hi")], provides: "everything")
    eventually(fn -> "idle" in types("s-unk") end)
    assert row_messages(own.id) == []
  end

  test "a fresh seat is idle once its startup side requests complete, before any prompt", ctx do
    own = session_fixture(ctx.user, %{title: "seat-a", claude_session_id: "s-boot"})
    # The quota probe (max_tokens 1, no tools) and a titling request, as at startup.
    send_msgs(ctx, "s-boot", [user_msg("quota")], tools: [], provides: "mirror,idle")
    send_msgs(ctx, "s-boot", [user_msg("name this session")], class: "auxiliary", provides: "mirror,idle")
    eventually(fn -> Room.get_status(own.id).idle == true end)
    assert Enum.map(row_messages(own.id), & &1["type"]) == ["idle"], "side requests are not conversation"
  end

  test "a prompt arriving during the startup debounce cancels the startup idle", ctx do
    own = session_fixture(ctx.user, %{title: "seat-a", claude_session_id: "s-boot2"})
    send_msgs(ctx, "s-boot2", [user_msg("quota")], tools: [], provides: "mirror,idle")
    send_msgs(ctx, "s-boot2", [user_msg("first prompt")], scenario: "tool", provides: "mirror,idle")
    Process.sleep(@idle_ms * 4)
    refute "idle" in Enum.map(row_messages(own.id), & &1["type"]), "a seat running a tool was reported idle"
  end
end
