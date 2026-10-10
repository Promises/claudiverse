defmodule ClaudiverseServerWeb.MirrorTest do
  @moduledoc "POST /api/sessions/:id/mirror: a WebSocket-less seat (the claudiverse mod) mirrors over HTTP."
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.Sessions.Room

  setup do
    {user, api} = user_with_token()
    session = session_fixture(user, %{title: "mod-seat"})

    with [{old, _}] <- Registry.lookup(ClaudiverseServer.Sessions.Registry, session.id) do
      ClaudiverseServer.Sessions.Supervisor.stop_room(old)
      Enum.find(1..100, fn _ -> Registry.lookup(ClaudiverseServer.Sessions.Registry, session.id) == [] or (Process.sleep(10) && false) end)
    end

    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, "session:#{session.id}")
    %{user: user, api: api, session: session}
  end

  defp mirror(ctx, id, messages),
    do: build_conn() |> put_req_header("authorization", "Bearer " <> ctx.api) |> post("/api/sessions/#{id}/mirror", %{messages: messages})

  test "mirrored messages reach viewers and are stored, as a sidecar's are; the idle frame reads idle", ctx do
    row = %{"type" => "assistant", "uuid" => "u-1", "timestamp" => "2026-10-09T07:30:24.437Z", "message" => %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "hi"}]}}
    assert mirror(ctx, ctx.session.id, [row]) |> json_response(202) == %{"ok" => true, "count" => 1}
    assert_receive {"message", ^row}, 1_000
    refute Room.get_status(ctx.session.id).idle

    mirror(ctx, ctx.session.id, [%{"type" => "idle"}]) |> json_response(202)
    assert_receive {"message", %{"type" => "idle"}}, 1_000
    assert Room.get_status(ctx.session.id).idle
    assert ClaudiverseServer.Sessions.list_messages(ctx.session.id) |> Enum.map(& &1.type) == ["assistant", "idle"]
  end

  test "a seat's session_ended ends its row at once and tells viewers", ctx do
    mirror(ctx, ctx.session.id, [%{"type" => "idle"}]) |> json_response(202)
    mirror(ctx, ctx.session.id, [%{"type" => "session_ended", "reason" => "prompt_input_exit"}]) |> json_response(202)
    assert_receive {"session_ended", %{"exit_code" => 0}}, 1_000
    assert %{status: :stopped} = ClaudiverseServer.Repo.reload!(ctx.session)
    # A control frame, not a message: nothing stored for it.
    assert ClaudiverseServer.Sessions.list_messages(ctx.session.id) |> Enum.map(& &1.type) == ["idle"]
  end

  test "a non-zero exit code marks the row crashed", ctx do
    mirror(ctx, ctx.session.id, [%{"type" => "session_ended", "exit_code" => 1}]) |> json_response(202)
    assert_receive {"session_ended", %{"exit_code" => 1}}, 1_000
    assert %{status: :crashed} = ClaudiverseServer.Repo.reload!(ctx.session)
  end

  test "live-only frames reach viewers but are not stored; real messages are", ctx do
    live = for t <- ~w(stream_event progress set_in_progress_tool_use_ids interruptible_tool_in_progress stream_request_start),
               do: %{"type" => t, "event" => %{"type" => "content_block_delta"}}
    msg = %{"type" => "assistant", "uuid" => "u-9", "timestamp" => "2026-10-09T07:30:24.437Z", "message" => %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "done"}]}}

    mirror(ctx, ctx.session.id, live ++ [msg]) |> json_response(202)
    for f <- live, do: assert_receive({"message", ^f}, 1_000)
    assert_receive {"message", ^msg}, 1_000

    assert ClaudiverseServer.Sessions.list_messages(ctx.session.id) |> Enum.map(& &1.type) == ["assistant"]
  end

  describe "images" do
    setup do
      dir = Path.join(System.tmp_dir!(), "cv-seat-files-#{System.unique_integer([:positive])}")
      Application.put_env(:claudiverse_server, :seat_files_dir, dir)
      on_exit(fn -> Application.delete_env(:claudiverse_server, :seat_files_dir); File.rm_rf(dir) end)
      %{dir: dir}
    end

    # A 1x1 PNG.
    @png Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")

    defp image(data \\ nil, mt \\ "image/png"),
      do: %{"type" => "image", "source" => %{"type" => "base64", "media_type" => mt, "data" => data || Base.encode64(@png)}}

    test "a pasted image is stored once and the message carries a reference the apps fetch", ctx do
      prompt = %{"type" => "user", "uuid" => "u-1",
                 "message" => %{"role" => "user", "content" => [%{"type" => "text", "text" => "[Image #3] look"}, image()]}}

      mirror(ctx, ctx.session.id, [prompt, Map.put(prompt, "uuid", "u-2")]) |> json_response(202)
      assert_receive {"message", %{"uuid" => "u-1", "message" => %{"content" => [_, ref]}}}, 1_000
      assert %{"type" => "image", "size" => size, "source" => %{"type" => "url", "url" => "/api/files/" <> id, "media_type" => "image/png"}} = ref
      assert size == byte_size(@png)
      # The second copy points at the same file: stored once.
      assert_receive {"message", %{"uuid" => "u-2", "message" => %{"content" => [_, ^ref]}}}, 1_000
      assert [_] = File.ls!(ctx.dir)

      # Stored rows hold the reference, not the base64.
      [row | _] = ClaudiverseServer.Sessions.list_messages(ctx.session.id)
      refute Jason.encode!(row.payload) =~ Base.encode64(@png)

      conn = build_conn() |> put_req_header("authorization", "Bearer " <> ctx.api) |> get("/api/files/" <> id)
      assert response(conn, 200) == @png
      assert ["image/png" <> _] = get_resp_header(conn, "content-type")
    end

    test "an image inside a tool result is moved too", ctx do
      result = %{"type" => "user", "message" => %{"role" => "user", "content" => [
                 %{"type" => "tool_result", "tool_use_id" => "t1", "content" => [image()]}]}}
      mirror(ctx, ctx.session.id, [result]) |> json_response(202)
      assert_receive {"message", %{"message" => %{"content" => [%{"content" => [%{"source" => %{"type" => "url"}}]}]}}}, 1_000
    end

    test "bad base64 or a type that is not an image is left as it was", ctx do
      odd = %{"type" => "user", "timestamp" => "2026-10-09T07:30:24.437Z", "message" => %{"role" => "user", "content" => [image("not base64!!"), image(nil, "application/pdf")]}}
      mirror(ctx, ctx.session.id, [odd]) |> json_response(202)
      assert_receive {"message", ^odd}, 1_000
      refute File.exists?(ctx.dir)
    end
  end

  test "another user's seat, a bad id, a typeless message or an oversized batch is refused", ctx do
    {other, _} = user_with_token(%{email: "other@test.com"})
    theirs = session_fixture(other, %{title: "theirs"})

    assert mirror(ctx, theirs.id, [%{"type" => "idle"}]) |> json_response(404)
    assert mirror(ctx, "x", [%{"type" => "idle"}]) |> json_response(404)
    assert mirror(ctx, ctx.session.id, [%{"no" => "type"}]) |> json_response(400)
    assert mirror(ctx, ctx.session.id, List.duplicate(%{"type" => "idle"}, 201)) |> json_response(400)
    refute_receive {"message", _}, 100
  end
end
