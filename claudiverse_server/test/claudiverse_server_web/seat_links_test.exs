defmodule ClaudiverseServerWeb.SeatLinksTest do
  @moduledoc """
  The patch-free links a seat holds to the server: an MCP channel stream
  (prompts, permission decisions) and a held PreToolUse hook (AskUserQuestion
  answers). Real HTTP, because both are long-lived requests. A fake sidecar is
  registered on every Room so each test can assert which path a delivery took.
  """
  use ClaudiverseServer.DataCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.SeatLinks
  alias ClaudiverseServer.Sessions.{Room, Supervisor}

  @finch ClaudiverseServer.Proxy.Finch

  setup do
    # User ids repeat across sandboxed tests, so links left by an earlier
    # test's streams would match this test's seat.
    for pid <- Registry.select(ClaudiverseServer.SeatLinks.Registry, [{{:_, :"$1", :_}, [], [:"$1"]}]),
        do: Process.exit(pid, :kill)

    # Same reason: inbox marks and queues are keyed by {user_id, seat}.
    :sys.replace_state(ClaudiverseServer.SeatInbox, fn _ -> %{queues: %{}, events: %{}, polled: %{}} end)
    :sys.replace_state(ClaudiverseServer.QuestionHolds, fn _ -> %{} end)

    # SUPERVISED, so the server and every request it is still holding stop when
    # the test ends. Measured: with a bare start_link the server outlived its
    # test (a normal exit does not kill links), and a held poll from one test —
    # registering after the next test's cleanup above — took that test's
    # prompt or interrupt: three different tests failed, 3 runs in 12.
    # A short shutdown timeout: several tests end with a stream or poll still
    # held, and a graceful wait for each took the file from 18 s to 78 s.
    srv =
      start_supervised!(
        {Bandit,
         plug: ClaudiverseServerWeb.Endpoint, port: 0, ip: :loopback, startup_log: false,
         thousand_island_options: [shutdown_timeout: 100]}
      )
    {:ok, {_, port}} = ThousandIsland.listener_info(srv)
    {user, token} = user_with_token()
    session = session_fixture(user, %{title: "seat-x"})
    {:ok, _} = Supervisor.start_room(session.id, owner_id: user.id)
    Room.register_sidecar(session.id, self())

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(ClaudiverseServer.Sessions.Supervisor), is_pid(pid),
          do: DynamicSupervisor.terminate_child(ClaudiverseServer.Sessions.Supervisor, pid)
      Application.delete_env(:claudiverse_server, :question_hold_ms)
      Application.delete_env(:claudiverse_server, :question_poll_hold_ms)
    end)

    %{base: "http://127.0.0.1:#{port}", user: user, token: token, session: session}
  end

  defp headers(ctx), do: [{"authorization", "Bearer " <> ctx.token}, {"content-type", "application/json"}]

  defp post(ctx, path, body) do
    {:ok, r} = Finch.build(:post, ctx.base <> path, headers(ctx), Jason.encode!(body)) |> Finch.request(@finch, receive_timeout: 10_000)
    r
  end

  # Opens the seat's channel stream; every SSE chunk is sent to the test as {:sse, data}.
  defp open_stream(ctx, seat \\ "seat-x") do
    test = self()

    task =
      Task.async(fn ->
        Finch.build(:get, ctx.base <> "/api/mcp/seat/" <> seat, [{"authorization", "Bearer " <> ctx.token}, {"accept", "text/event-stream"}])
        |> Finch.stream(@finch, nil, fn
          {:data, d}, acc -> send(test, {:sse, d}); acc
          {:status, s}, acc -> send(test, {:sse_status, s}); acc
          _, acc -> acc
        end, receive_timeout: 60_000)
      end)

    assert_receive {:sse_status, 200}, 5_000
    wait_until(fn -> SeatLinks.linked?(:channel, ctx.user.id, seat) end)
    task
  end

  defp wait_until(f, n \\ 100) do
    cond do
      f.() -> :ok
      n == 0 -> flunk("condition never held")
      true -> Process.sleep(20); wait_until(f, n - 1)
    end
  end

  # Stops the seat's Room and waits for its name to clear. The Registry drops
  # a dead process's name asynchronously, so "a Room is registered" right
  # after a stop can still be the old one (measured: 2 runs in 6 hit it).
  defp stop_room!(ctx) do
    [{pid, _}] = Registry.lookup(ClaudiverseServer.Sessions.Registry, ctx.session.id)
    ClaudiverseServer.Sessions.Supervisor.stop_room(pid)
    wait_until(fn -> Registry.lookup(ClaudiverseServer.Sessions.Registry, ctx.session.id) == [] end)
  end

  defp make_idle(session), do: Room.mirror_messages(session.id, [%{"type" => "idle"}])

  defp sse_message do
    receive do
      {:sse, "event: message\ndata: " <> rest} -> rest |> String.trim() |> Jason.decode!()
      {:sse, ": keepalive" <> _} -> sse_message()
    after
      3_000 -> flunk("no SSE message")
    end
  end

  test "initialize advertises the channel and permission-relay capabilities", ctx do
    r = post(ctx, "/api/mcp/seat/seat-x", %{jsonrpc: "2.0", id: 0, method: "initialize", params: %{protocolVersion: "2025-06-18"}})
    assert r.status == 200
    caps = Jason.decode!(r.body)["result"]["capabilities"]["experimental"]
    assert Map.has_key?(caps, "claude/channel") and Map.has_key?(caps, "claude/channel/permission")
    assert List.keyfind(r.headers, "mcp-session-id", 0)
  end

  test "without a token the MCP endpoint refuses", ctx do
    {:ok, r} = Finch.build(:post, ctx.base <> "/api/mcp/seat/seat-x", [{"content-type", "application/json"}], "{}") |> Finch.request(@finch)
    assert r.status == 401
  end

  test "cv_send to an idle seat with a channel goes down the channel, not the sidecar", ctx do
    open_stream(ctx)
    make_idle(ctx.session)
    wait_until(fn -> Room.get_status(ctx.session.id).idle end)

    assert Room.send_message(ctx.session.id, "hello seat") == :delivered
    msg = sse_message()
    assert msg["method"] == "notifications/claude/channel"
    assert msg["params"]["content"] == "hello seat"
    refute_receive {:forward_to_sidecar, _, _}, 200

    # Reject-busy still applies: the seat is busy after delivery.
    assert {:busy, _} = Room.send_message(ctx.session.id, "second")
    refute_receive {:sse, "event: message" <> _}, 300
  end

  test "a seat without a channel still gets cv_send through its sidecar", ctx do
    make_idle(ctx.session)
    wait_until(fn -> Room.get_status(ctx.session.id).idle end)
    assert Room.send_message(ctx.session.id, "via sidecar") == :delivered
    assert_receive {:forward_to_sidecar, "remote_input", %{"content" => "via sidecar"}}
  end

  test "a relayed permission prompt is tracked by the Room and answered down the channel", ctx do
    open_stream(ctx)
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, "session:#{ctx.session.id}")

    r = post(ctx, "/api/mcp/seat/seat-x", %{jsonrpc: "2.0", method: "notifications/claude/channel/permission_request",
              params: %{request_id: "abcde", tool_name: "Bash", description: "touch x", input_preview: "{\"command\":\"touch x\"}"}})
    assert r.status == 202

    Room.send_permission_response(ctx.session.id, "abcde", "allow")
    msg = sse_message()
    assert msg["method"] == "notifications/claude/channel/permission"
    assert msg["params"] == %{"request_id" => "abcde", "behavior" => "allow"}
    refute_receive {:forward_to_sidecar, "remote_permission_response", _}, 200
  end

  test "a newer stream replaces the older one", ctx do
    first = open_stream(ctx)
    _second = open_stream(ctx)
    assert {:ok, _} = Task.await(first, 5_000)
  end

  defp ask(ctx, tool_name \\ "AskUserQuestion") do
    Task.async(fn ->
      post(ctx, "/api/hooks/seat/seat-x/pretooluse", %{
        hook_event_name: "PreToolUse", tool_name: tool_name, tool_use_id: "toolu_1",
        tool_input: %{questions: [%{question: "RED or BLUE?", header: "Color", options: [%{label: "RED"}, %{label: "BLUE"}]}]}
      })
    end)
  end

  test "the hook ignores tools other than AskUserQuestion", ctx do
    r = ctx |> ask("Bash") |> Task.await(5_000)
    assert r.status == 200 and Jason.decode!(r.body) == %{}
  end

  test "a held question is answered by cv_answer, and the sidecar is not used", ctx do
    t = ask(ctx)
    wait_until(fn -> SeatLinks.linked?(:question, ctx.user.id, "seat-x") end)
    Room.answer(ctx.session.id, %{"response" => "RED"})
    out = Jason.decode!(Task.await(t, 5_000).body)["hookSpecificOutput"]
    assert out["permissionDecision"] == "allow"
    assert out["updatedInput"]["answers"] == %{"RED or BLUE?" => "RED"}
    assert out["updatedInput"]["questions"] != nil, "the original input must be kept"
    refute_receive {:forward_to_sidecar, "remote_answer", _}, 200
  end

  test "the apps' header lines answer each question with its own choice" do
    alias ClaudiverseServerWeb.HookController
    two = %{"questions" => [%{"question" => "Which color?", "header" => "Color"}, %{"question" => "Which size?", "header" => "Size"}]}

    assert HookController.answers(two, %{"response" => "Color: Red\nSize: Large"}) ==
             %{"Which color?" => "Red", "Which size?" => "Large"}
    # One choice made: the other question is not answered with it.
    assert HookController.answers(two, %{"response" => "Color: Red"}) ==
             %{"Which color?" => "Red", "Which size?" => "(no answer given)"}
    # Free text, or a line naming no header, is ONE reply to the whole set:
    # the first question carries it once and the rest point to it, never the
    # same text copied into every answer.
    see = ~s|(one reply for all questions: see "Color")|
    assert HookController.answers(two, %{"response" => "use gpl2"}) == %{"Which color?" => "use gpl2", "Which size?" => see}
    assert HookController.answers(two, %{"response" => "Color: Red\nnote: hurry"}) ==
             %{"Which color?" => "Color: Red\nnote: hurry", "Which size?" => see}
    # One question: its answer is the text, whatever it looks like.
    one = %{"questions" => [%{"question" => "Which color?", "header" => "Color"}]}
    assert HookController.answers(one, %{"response" => "Color: Red"}) == %{"Which color?" => "Color: Red"}
  end

  test "structured answers pass through; cv_decline denies", ctx do
    t = ask(ctx)
    wait_until(fn -> SeatLinks.linked?(:question, ctx.user.id, "seat-x") end)
    Room.answer(ctx.session.id, %{"answers" => %{"RED or BLUE?" => "BLUE"}})
    assert Jason.decode!(Task.await(t, 5_000).body)["hookSpecificOutput"]["updatedInput"]["answers"] == %{"RED or BLUE?" => "BLUE"}

    t2 = ask(ctx)
    wait_until(fn -> SeatLinks.linked?(:question, ctx.user.id, "seat-x") end)
    Room.decline(ctx.session.id, %{})
    assert Jason.decode!(Task.await(t2, 5_000).body)["hookSpecificOutput"]["permissionDecision"] == "deny"
  end

  test "an unanswered question times out empty, so the dialog opens locally", ctx do
    Application.put_env(:claudiverse_server, :question_hold_ms, 200)
    r = ctx |> ask() |> Task.await(5_000)
    assert Jason.decode!(r.body) == %{}
  end

  # --- polled questions (the claudiverse-seat mod, 0.8.5+) --------------------

  defp ask_polled(ctx, extra) do
    Task.async(fn ->
      post(ctx, "/api/hooks/seat/seat-x/pretooluse", Map.merge(%{
        tool_name: "AskUserQuestion", tool_use_id: "toolu_p",
        tool_input: %{questions: [%{question: "RED or BLUE?", header: "Color", options: [%{label: "RED"}, %{label: "BLUE"}]}]}
      }, extra))
    end)
  end

  # The server restarted while the seat asked: it knows no question until the
  # mod's next poll, and the app's answer must not be dropped meanwhile.
  test "an answer for a question no poll has named yet is kept for the poll that names it", ctx do
    Room.answer(ctx.session.id, %{"tool_use_id" => "toolu_p", "response" => "BLUE"})
    # Still offered to a sidecar, as for any seat not polling a question.
    assert_receive {:forward_to_sidecar, "remote_answer", _}
    {us, r} = :timer.tc(fn -> ctx |> ask_polled(%{wait: 5}) |> Task.await(5_000) end)
    assert Jason.decode!(r.body)["hookSpecificOutput"]["updatedInput"]["answers"] == %{"RED or BLUE?" => "BLUE"}
    assert us < 1_000_000

    # Kept for that question only: one without the id is not kept.
    Room.answer(ctx.session.id, %{"response" => "RED"})
    assert Jason.decode!(Task.await(ask_polled(ctx, %{wait: 1, tool_use_id: "toolu_q"}), 5_000).body) == %{"pending" => true}
  end

  test "a poll that sees no answer ends pending within its wait", ctx do
    {us, r} = :timer.tc(fn -> ctx |> ask_polled(%{wait: 1}) |> Task.await(5_000) end)
    assert Jason.decode!(r.body) == %{"pending" => true}
    assert us >= 900_000 and us < 3_000_000
  end

  test "an answer between two polls is kept for the next one, never sent to the sidecar", ctx do
    assert Jason.decode!(Task.await(ask_polled(ctx, %{wait: 1}), 5_000).body) == %{"pending" => true}
    Room.answer(ctx.session.id, %{"response" => "BLUE"})
    refute_receive {:forward_to_sidecar, "remote_answer", _}, 200
    {us, r} = :timer.tc(fn -> ctx |> ask_polled(%{wait: 5}) |> Task.await(5_000) end)
    assert Jason.decode!(r.body)["hookSpecificOutput"]["updatedInput"]["answers"] == %{"RED or BLUE?" => "BLUE"}
    assert us < 1_000_000, "a kept answer is handed over at once, not after the wait"
  end

  test "an answer during a poll ends it; a decline denies", ctx do
    t = ask_polled(ctx, %{wait: 5})
    wait_until(fn -> SeatLinks.linked?(:question, ctx.user.id, "seat-x") end)
    Room.answer(ctx.session.id, %{"answers" => %{"RED or BLUE?" => "RED"}})
    assert Jason.decode!(Task.await(t, 5_000).body)["hookSpecificOutput"]["updatedInput"]["answers"] == %{"RED or BLUE?" => "RED"}

    t2 = ask_polled(ctx, %{wait: 5, tool_use_id: "toolu_q"})
    wait_until(fn -> SeatLinks.linked?(:question, ctx.user.id, "seat-x") end)
    Room.decline(ctx.session.id, %{})
    assert Jason.decode!(Task.await(t2, 5_000).body)["hookSpecificOutput"]["permissionDecision"] == "deny"
  end

  test "an answered question is forgotten: a later answer goes to the sidecar", ctx do
    t = ask_polled(ctx, %{wait: 5})
    wait_until(fn -> SeatLinks.linked?(:question, ctx.user.id, "seat-x") end)
    Room.answer(ctx.session.id, %{"response" => "RED"})
    Task.await(t, 5_000)
    Room.answer(ctx.session.id, %{"response" => "BLUE"})
    assert_receive {:forward_to_sidecar, "remote_answer", %{"response" => "BLUE"}}
  end

  test "a withdraw (answered at the terminal) ends the poll empty and forgets the question", ctx do
    t = ask_polled(ctx, %{wait: 5})
    wait_until(fn -> SeatLinks.linked?(:question, ctx.user.id, "seat-x") end)
    assert Jason.decode!(Task.await(ask_polled(ctx, %{withdraw: true}), 5_000).body) == %{}
    assert Jason.decode!(Task.await(t, 5_000).body) == %{}
    Room.answer(ctx.session.id, %{"response" => "RED"})
    assert_receive {:forward_to_sidecar, "remote_answer", _}
  end

  test "a polled question past the hold ends empty, so the terminal dialog decides", ctx do
    Application.put_env(:claudiverse_server, :question_poll_hold_ms, 300)
    assert Jason.decode!(Task.await(ask_polled(ctx, %{wait: 1}), 5_000).body) == %{}
  end

  # lorem-w6-t1884, 2026-10-08: the single-request hold (59 min) ended a polled
  # question its seat was still polling, and a later cv_answer went nowhere.
  test "a polled question outlives the single-request hold while its seat polls", ctx do
    Application.put_env(:claudiverse_server, :question_hold_ms, 300)
    assert Jason.decode!(Task.await(ask_polled(ctx, %{wait: 1}), 5_000).body) == %{"pending" => true}
    assert Jason.decode!(Task.await(ask_polled(ctx, %{wait: 1}), 5_000).body) == %{"pending" => true}
  end

  test "answer_sync says where an answer went; nothing waiting is :not_waiting", ctx do
    t = ask_polled(ctx, %{wait: 5})
    wait_until(fn -> SeatLinks.linked?(:question, ctx.user.id, "seat-x") end)
    assert Room.answer_sync(ctx.session.id, :answer, %{"response" => "RED"}) == :delivered
    Task.await(t, 5_000)
    # The question is settled; this seat has a sidecar, which gets the next one.
    assert Room.answer_sync(ctx.session.id, :answer, %{"response" => "RED"}) == :sidecar
    assert_receive {:forward_to_sidecar, "remote_answer", _}

    # A mod seat: no sidecar, no question.
    lone = session_fixture(ctx.user, %{title: "seat-lone"})
    {:ok, _} = ClaudiverseServer.Sessions.Supervisor.start_room(lone.id, owner_id: ctx.user.id)
    assert Room.answer_sync(lone.id, :answer, %{"response" => "RED"}) == :not_waiting
    assert Room.answer_sync(lone.id, :decline, %{}) == :not_waiting
  end

  # --- inbox (asyncRewake hook long poll) -----------------------------------

  defp get(ctx, path) do
    {:ok, r} = Finch.build(:get, ctx.base <> path, [{"authorization", "Bearer " <> ctx.token}])
               |> Finch.request(@finch, receive_timeout: 10_000)
    r
  end

  defp poll(ctx, wait \\ 5), do: Task.async(fn -> get(ctx, "/api/seats/seat-x/inbox?wait=#{wait}") end)

  defp idle!(ctx) do
    make_idle(ctx.session)
    wait_until(fn -> Room.get_status(ctx.session.id).idle end)
  end

  test "PATCH PATH: a seat that never polled an inbox still gets cv_send through its sidecar", ctx do
    idle!(ctx)
    assert Room.send_message(ctx.session.id, "patched seat") == :delivered
    assert_receive {:forward_to_sidecar, "remote_input", %{"content" => "patched seat"}}
    refute ClaudiverseServer.SeatInbox.inbox_seat?(ctx.user.id, "seat-x")
  end

  test "a waiting poll is answered with the prompt, and the sidecar is not used", ctx do
    t = poll(ctx)
    wait_until(fn -> SeatLinks.linked?(:inbox, ctx.user.id, "seat-x") end)
    idle!(ctx)

    assert Room.send_message(ctx.session.id, "wake up") == :delivered
    r = Task.await(t, 5_000)
    assert r.status == 200 and r.body == "wake up"
    refute_receive {:forward_to_sidecar, "remote_input", _}, 200
  end

  test "between polls an inbox seat's prompts are queued, then handed to the next poll", ctx do
    first = poll(ctx, 1)
    assert Task.await(first, 5_000).status == 204

    idle!(ctx)
    assert Room.send_message(ctx.session.id, "one") == :delivered
    assert Room.force_message(ctx.session.id, "two") == :delivered
    refute_receive {:forward_to_sidecar, "remote_input", _}, 200

    r = ctx |> poll() |> Task.await(5_000)
    assert r.status == 200 and r.body == "one\n\ntwo"
  end

  test "an inbox whose poller is gone goes back to the live sidecar, queued prompts first", ctx do
    on_exit(fn -> Application.delete_env(:claudiverse_server, :inbox_stale_ms) end)
    first = poll(ctx, 1)
    assert Task.await(first, 5_000).status == 204

    idle!(ctx)
    assert Room.send_message(ctx.session.id, "one") == :delivered
    refute_receive {:forward_to_sidecar, "remote_input", _}, 200

    # The poller never comes back: past the threshold, the sidecar takes over.
    Application.put_env(:claudiverse_server, :inbox_stale_ms, 0)
    Process.sleep(5)
    assert Room.force_message(ctx.session.id, "two") == :delivered
    assert_receive {:forward_to_sidecar, "remote_input", %{"content" => "one"}}, 1_000
    assert_receive {:forward_to_sidecar, "remote_input", %{"content" => "two"}}, 1_000
    refute ClaudiverseServer.SeatInbox.inbox_seat?(ctx.user.id, "seat-x")
  end

  test "a newer poll replaces the older one, which is told to stop (409)", ctx do
    old = poll(ctx, 30)
    wait_until(fn -> SeatLinks.linked?(:inbox, ctx.user.id, "seat-x") end)
    _new = poll(ctx, 30)
    assert Task.await(old, 5_000).status == 409
  end

  test "a poll revives a row the liveness check stopped: the seat is plainly alive", ctx do
    {:ok, _} = ClaudiverseServer.Sessions.update_session(ctx.session, %{status: :stopped})
    t = poll(ctx, 1)
    wait_until(fn -> ClaudiverseServer.Sessions.get_session!(ctx.session.id).status == :running end)
    Task.await(t, 5_000)
  end

  # --- interrupt through the inbox ------------------------------------------

  test "interrupting a busy inbox seat answers its poll 205 (press Escape); the sidecar is still told", ctx do
    t = poll(ctx, 5)
    wait_until(fn -> SeatLinks.linked?(:inbox, ctx.user.id, "seat-x") end)
    refute Room.get_status(ctx.session.id).idle

    Room.interrupt(ctx.session.id)
    assert Task.await(t, 5_000).status == 205
    assert_receive {:forward_to_sidecar, "remote_interrupt", _}
  end

  test "an idle seat is not sent Escape (it would clear the operator's draft)", ctx do
    idle!(ctx)
    t = poll(ctx, 1)
    wait_until(fn -> SeatLinks.linked?(:inbox, ctx.user.id, "seat-x") end)
    Room.interrupt(ctx.session.id)
    assert Task.await(t, 5_000).status == 204
  end

  test "an interrupt with no poll open is dropped, not queued for a later turn", ctx do
    ctx |> poll(1) |> Task.await(5_000)
    Room.interrupt(ctx.session.id)
    _ = Room.get_status(ctx.session.id)
    assert ctx |> poll(1) |> Task.await(5_000) |> Map.get(:status) == 204
  end

  # --- permission prompts (PermissionRequest hook) ---------------------------

  @perm_input %{hook_event_name: "PermissionRequest", tool_name: "Bash",
                tool_input: %{command: "touch x", description: "Create x"},
                permission_suggestions: [%{type: "setMode", mode: "acceptEdits", destination: "session"}]}

  defp ask_permission(ctx, seat \\ "seat-x"),
    do: Task.async(fn -> post(ctx, "/api/hooks/seat/#{seat}/permissionrequest", @perm_input) end)

  defp pending(ctx) do
    [{pid, _}] = Registry.lookup(ClaudiverseServer.Sessions.Registry, ctx.session.id)
    :sys.get_state(pid).pending_permissions
  end

  defp held_request_id(ctx) do
    wait_until(fn -> map_size(pending(ctx)) == 1 end)
    [{rid, req}] = Map.to_list(pending(ctx))
    assert req["hook"] == true and req["request"]["tool_name"] == "Bash"
    assert req["request"]["input"]["command"] == "touch x"
    rid
  end

  defp decision(r), do: r.body |> String.trim() |> Jason.decode!()

  # --- polled permission prompts (the claudiverse-seat mod, 0.8.6+) ----------

  defp poll_permission(ctx, extra) do
    Task.async(fn -> post(ctx, "/api/hooks/seat/seat-x/permissionrequest", Map.merge(@perm_input, extra)) end)
  end

  @allow %{"hookSpecificOutput" => %{"hookEventName" => "PermissionRequest", "decision" => %{"behavior" => "allow"}}}

  test "a polled prompt shows in the Room; a poll with no answer ends pending with its request id", ctx do
    t = poll_permission(ctx, %{wait: 1})
    rid = held_request_id(ctx)
    assert %{"pending" => true, "request_id" => ^rid} = decision(Task.await(t, 5_000))
    assert Map.has_key?(pending(ctx), rid), "still offered to the apps between polls"
  end

  test "an answer between two polls is kept for the next one, and handed over once", ctx do
    %{"request_id" => rid} = decision(Task.await(poll_permission(ctx, %{wait: 1}), 5_000))
    Room.send_permission_response(ctx.session.id, rid, "allow")
    refute_receive {:forward_to_sidecar, "remote_permission_response", _}, 200

    {us, r} = :timer.tc(fn -> decision(Task.await(poll_permission(ctx, %{wait: 5, request_id: rid}), 7_000)) end)
    assert r == @allow
    assert us < 1_000_000, "a kept answer is handed over at once"
    assert decision(Task.await(poll_permission(ctx, %{wait: 1, request_id: rid}), 5_000)) == %{}, "then it is gone"
  end

  test "an answer during a poll ends it; a deny denies", ctx do
    t = poll_permission(ctx, %{wait: 5})
    rid = held_request_id(ctx)
    Room.send_permission_response(ctx.session.id, rid, "deny")
    assert %{"hookSpecificOutput" => %{"decision" => %{"behavior" => "deny"}}} = decision(Task.await(t, 5_000))
    assert pending(ctx) == %{}
  end

  test "answered at the terminal: withdraw ends the waiting poll and takes it off the panel", ctx do
    %{"request_id" => rid} = decision(Task.await(poll_permission(ctx, %{wait: 1}), 5_000))
    t = poll_permission(ctx, %{wait: 5, request_id: rid})
    Process.sleep(200)
    assert decision(Task.await(poll_permission(ctx, %{withdraw: true, request_id: rid}), 5_000)) == %{}
    assert decision(Task.await(t, 5_000)) == %{}
    assert pending(ctx) == %{}
  end

  test "a permission prompt is held, shown in the Room, and allowed from the panel", ctx do
    t = ask_permission(ctx)
    rid = held_request_id(ctx)
    Room.send_permission_response(ctx.session.id, rid, "allow")

    assert decision(Task.await(t, 5_000)) ==
             %{"hookSpecificOutput" => %{"hookEventName" => "PermissionRequest", "decision" => %{"behavior" => "allow"}}}

    assert pending(ctx) == %{}
    refute_receive {:forward_to_sidecar, "remote_permission_response", _}, 200
  end

  test "a deny from the panel denies, with a message", ctx do
    t = ask_permission(ctx)
    Room.send_permission_response(ctx.session.id, held_request_id(ctx), "deny")
    assert %{"behavior" => "deny", "message" => _} = decision(Task.await(t, 5_000))["hookSpecificOutput"]["decision"]
  end

  test "a hold that times out answers {} (the terminal dialog decides) and leaves the panel", ctx do
    Application.put_env(:claudiverse_server, :permission_hold_ms, 300)
    Application.put_env(:claudiverse_server, :permission_keepalive_ms, 100)
    on_exit(fn -> Enum.each([:permission_hold_ms, :permission_keepalive_ms], &Application.delete_env(:claudiverse_server, &1)) end)

    r = ctx |> ask_permission() |> Task.await(5_000)
    assert decision(r) == %{}
    wait_until(fn -> pending(ctx) == %{} end)
  end

  # Claude Code keeps the hook open after a LOCAL answer (measured: still held
  # four minutes later), so the Room settles it from what the proxy mirrors.
  defp mirror_call(ctx, id, input) do
    Room.mirror_messages(ctx.session.id, [
      %{"type" => "assistant", "message" => %{"content" => [%{"type" => "tool_use", "id" => id, "name" => "Bash", "input" => input}]}}
    ])
  end

  defp mirror_result(ctx, id) do
    Room.mirror_messages(ctx.session.id, [
      %{"type" => "user", "message" => %{"content" => [%{"type" => "tool_result", "tool_use_id" => id, "content" => ""}]}}
    ])
  end

  @asked %{"command" => "touch x", "description" => "Create x"}

  test "answered at the terminal: the tool's mirrored result settles the held prompt", ctx do
    mirror_call(ctx, "toolu_A", @asked)
    t = ask_permission(ctx)
    held_request_id(ctx)

    mirror_result(ctx, "toolu_A")
    assert decision(Task.await(t, 5_000)) == %{}
    assert pending(ctx) == %{}
  end

  test "another tool call's result does not settle it", ctx do
    mirror_call(ctx, "toolu_A", @asked)
    mirror_call(ctx, "toolu_B", %{"command" => "ls"})
    t = ask_permission(ctx)
    rid = held_request_id(ctx)

    mirror_result(ctx, "toolu_B")
    _ = Room.get_status(ctx.session.id)
    assert Map.keys(pending(ctx)) == [rid]

    Room.send_permission_response(ctx.session.id, rid, "allow")
    assert %{"behavior" => "allow"} = decision(Task.await(t, 5_000))["hookSpecificOutput"]["decision"]
  end

  test "the seat going idle settles a prompt still held (Escape at the dialog)", ctx do
    t = ask_permission(ctx)
    held_request_id(ctx)
    make_idle(ctx.session)
    assert decision(Task.await(t, 5_000)) == %{}
    assert pending(ctx) == %{}
  end

  test "a seat that goes away mid-hold has its prompt withdrawn from the panel", ctx do
    Application.put_env(:claudiverse_server, :permission_keepalive_ms, 100)
    on_exit(fn -> Application.delete_env(:claudiverse_server, :permission_keepalive_ms) end)

    %URI{host: host, port: port} = URI.parse(ctx.base)
    {:ok, sock} = :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false])
    body = Jason.encode!(@perm_input)
    :ok = :gen_tcp.send(sock, "POST /api/hooks/seat/seat-x/permissionrequest HTTP/1.1\r\nhost: x\r\n" <>
      "authorization: Bearer #{ctx.token}\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <> body)

    held_request_id(ctx)
    :gen_tcp.close(sock)
    wait_until(fn -> pending(ctx) == %{} end)
  end

  test "a seat with no running session gets {} at once", ctx do
    r = ctx |> ask_permission("no-such-seat") |> Task.await(5_000)
    assert decision(r) == %{}
  end

  # --- readiness after a restart (inbox hint) --------------------------------

  defp poll_event(ctx, event), do: Task.async(fn -> get(ctx, "/api/seats/seat-x/inbox?wait=1&event=#{event}") end)

  test "a fresh Room (as after a restart) takes readiness from the seat's poll: Stop -> idle", ctx do
    refute Room.get_status(ctx.session.id).idle
    t = poll_event(ctx, "Stop")
    wait_until(fn -> Room.get_status(ctx.session.id).idle end)
    Task.await(t, 5_000)
  end

  test "the idle_prompt Notification poller counts as idle (a turn ended with no Stop, e.g. interrupted)", ctx do
    ctx |> poll_event("Notification") |> Task.await(5_000)
    assert Room.get_status(ctx.session.id).idle
  end

  test "UserPromptSubmit leaves it busy, and settles readiness so a later Stop poll is ignored", ctx do
    ctx |> poll_event("UserPromptSubmit") |> Task.await(5_000)
    ctx |> poll_event("Stop") |> Task.await(5_000)
    refute Room.get_status(ctx.session.id).idle
  end

  test "a Room that already knows its readiness ignores the hint", ctx do
    Room.mirror_messages(ctx.session.id, [%{"type" => "assistant", "message" => %{"content" => []}}])
    ctx |> poll_event("Stop") |> Task.await(5_000)
    refute Room.get_status(ctx.session.id).idle
  end

  test "a seat with no sidecar gets its Room back from its poll, idle, and takes cv_send", ctx do
    stop_room!(ctx)
    assert Room.send_message(ctx.session.id, "x") == {:error, :not_connected}

    ctx |> poll_event("Stop") |> Task.await(5_000)
    wait_until(fn -> Registry.lookup(ClaudiverseServer.Sessions.Registry, ctx.session.id) != [] end)
    assert Room.get_status(ctx.session.id).idle

    t = poll(ctx)
    wait_until(fn -> SeatLinks.linked?(:inbox, ctx.user.id, "seat-x") end)
    assert Room.send_message(ctx.session.id, "after restart") == :delivered
    assert Task.await(t, 5_000).body == "after restart"
  end

  # --- liveness of a seat with no sidecar ------------------------------------

  defp restart_room_without_sidecar(ctx, liveness_ms) do
    Application.put_env(:claudiverse_server, :room_liveness_ms, liveness_ms)
    on_exit(fn -> Application.delete_env(:claudiverse_server, :room_liveness_ms) end)
    stop_room!(ctx)
  end

  defp status(ctx), do: ClaudiverseServer.Sessions.get_session!(ctx.session.id).status

  test "a seat with no sidecar reads as connected while its inbox poll is live", ctx do
    restart_room_without_sidecar(ctx, 60_000)
    t = poll(ctx, 2)
    wait_until(fn -> Registry.lookup(ClaudiverseServer.Sessions.Registry, ctx.session.id) != [] end)
    wait_until(fn -> Room.get_status(ctx.session.id).sidecar_connected end)
    Task.await(t, 5_000)
  end

  test "its session is stopped once the poll has been gone for three liveness checks, not before", ctx do
    restart_room_without_sidecar(ctx, 100)
    t = poll(ctx, 1)
    wait_until(fn -> Registry.lookup(ClaudiverseServer.Sessions.Registry, ctx.session.id) != [] end)

    # Poll held (1 s = ten checks): still running.
    Process.sleep(600)
    assert status(ctx) == :running

    Task.await(t, 5_000)
    wait_until(fn -> status(ctx) == :stopped end)
    refute Room.get_status(ctx.session.id).sidecar_connected
  end

  test "a seat whose poll pauses but which keeps mirroring is not stopped", ctx do
    # MEASURED 2026-10-06: a mod seat stopped polling for a whole turn and was
    # stopped 3 min in while it kept mirroring. The mirror is a heartbeat too.
    restart_room_without_sidecar(ctx, 100)
    ctx |> poll(1) |> Task.await(5_000)

    # No poll for ~1 s (ten checks), but a mirrored frame every 50 ms.
    for _ <- 1..20 do
      Room.mirror_messages(ctx.session.id, [%{"type" => "assistant", "message" => %{"content" => []}}])
      Process.sleep(50)
    end

    assert status(ctx) == :running

    # Control: the same silence WITHOUT mirrors does stop it.
    wait_until(fn -> status(ctx) == :stopped end)
  end

  test "a seat with no sidecar reports its host, fleet and origin on its poll", ctx do
    get(ctx, "/api/seats/seat-x/inbox?wait=1&host=xps&fleet=lorem-fleet&origin=manual")
    s = ClaudiverseServer.Sessions.get_session!(ctx.session.id)
    assert {s.host, s.fleet, s.origin} == {"xps", "lorem-fleet", "manual"}
  end

  test "a long wait is capped, so a client's dead poll cannot keep its seat alive for long", ctx do
    Application.put_env(:claudiverse_server, :inbox_max_wait_s, 1)
    on_exit(fn -> Application.delete_env(:claudiverse_server, :inbox_max_wait_s) end)

    {elapsed_us, r} = :timer.tc(fn -> ctx |> poll(3600) |> Task.await(5_000) end)
    assert r.status == 204
    assert elapsed_us < 3_000_000
  end

  test "a seat WITH a sidecar is never stopped for a missing inbox poll", ctx do
    restart_room_without_sidecar(ctx, 50)
    {:ok, _} = Supervisor.start_room(ctx.session.id, owner_id: ctx.user.id)
    Room.register_sidecar(ctx.session.id, self())

    ctx |> poll(1) |> Task.await(5_000)
    Process.sleep(500)
    assert status(ctx) == :running
    assert Room.get_status(ctx.session.id).sidecar_connected
  end

  test "a poll that arrives before the Room exists is applied when the sidecar joins", ctx do
    stop_room!(ctx)

    ctx |> poll_event("Stop") |> Task.await(5_000)
    {:ok, _} = Supervisor.start_room(ctx.session.id, owner_id: ctx.user.id)
    Room.register_sidecar(ctx.session.id, self())
    assert Room.get_status(ctx.session.id).idle
  end

  test "cv_answer to a seat with no held question still goes to its sidecar", ctx do
    Room.answer(ctx.session.id, %{"response" => "RED"})
    assert_receive {:forward_to_sidecar, "remote_answer", %{"response" => "RED"}}
  end
end
