defmodule ClaudiverseServerWeb.FileControllerTest do
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.{Accounts, SeatFiles}

  setup do
    dir = Path.join(System.tmp_dir!(), "seat-files-#{System.unique_integer([:positive])}")
    Application.put_env(:claudiverse_server, :seat_files_dir, dir)

    on_exit(fn ->
      Application.delete_env(:claudiverse_server, :seat_files_dir)
      File.rm_rf(dir)
    end)

    {user, api} = user_with_token()
    app = Accounts.create_user_api_token(user, "app")
    session = session_fixture(user, %{title: "file-seat"})
    src = Path.join(System.tmp_dir!(), "upload-#{System.unique_integer([:positive])}")
    File.write!(src, "hello seat\n")
    on_exit(fn -> File.rm(src) end)

    %{dir: dir, api: api, app: app, session: session, src: src}
  end

  defp upload(ctx, token, name \\ "notes.txt", session_id \\ nil) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> post("/api/sessions/#{session_id || ctx.session.id}/files",
      %{"file" => %Plug.Upload{path: ctx.src, filename: name, content_type: "text/plain"}})
  end

  defp stored(dir), do: if(File.dir?(dir), do: File.ls!(dir), else: [])

  test "the app uploads, and a seat downloads with the shared token", ctx do
    body = upload(ctx, ctx.app) |> json_response(200)
    assert %{"file_id" => id, "name" => "notes.txt", "size" => 11, "url" => url} = body
    assert url == "/api/files/" <> id
    assert stored(ctx.dir) == [id]

    r = build_conn() |> put_req_header("authorization", "Bearer " <> ctx.api) |> get(url)
    assert r.status == 200
    assert r.resp_body == "hello seat\n"
    assert get_resp_header(r, "content-disposition") |> hd() =~ ~s(filename="notes.txt")
  end

  test "an upload with the shared token is 403 and stores nothing", ctx do
    assert upload(ctx, ctx.api) |> json_response(403) == %{"error" => "file send is app-only"}
    assert stored(ctx.dir) == []
  end

  test "an upload to another user's or a missing session is 404 and stores nothing", ctx do
    assert upload(ctx, ctx.app, "x", 999_999) |> json_response(404)
    assert stored(ctx.dir) == []
  end

  test "a name cannot place the file outside its directory", ctx do
    body = upload(ctx, ctx.app, "../../etc/passwd") |> json_response(200)
    assert body["name"] == "passwd"
    assert stored(ctx.dir) == [body["file_id"]]
  end

  test "a download needs a token, and an id of the wrong shape is not found", ctx do
    id = (upload(ctx, ctx.app) |> json_response(200))["file_id"]
    assert build_conn() |> get("/api/files/" <> id) |> json_response(401)

    for bad <- ["..%2Fmeta.json", "nope", id <> "x"] do
      r = build_conn() |> put_req_header("authorization", "Bearer " <> ctx.api) |> get("/api/files/" <> bad)
      assert r.status == 404, "#{bad} should be 404"
    end
  end

  test "a file over the cap is refused and leaves nothing behind", ctx do
    big = ctx.src <> ".big"
    File.write!(big, :binary.copy(<<0>>, SeatFiles.max_bytes() + 1))
    on_exit(fn -> File.rm(big) end)

    assert SeatFiles.store(big, "big.bin", ctx.session.id) == {:error, :too_large}
    assert stored(ctx.dir) == []
  end
end
