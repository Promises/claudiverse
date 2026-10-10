defmodule ClaudiverseServerWeb.AppBuildTest do
  @moduledoc """
  The app's self-update store: app-only publish, one build kept (replaced only
  on success), latest + download with a matching sha256.
  """
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures
  import Ecto.Query

  alias ClaudiverseServer.{Accounts, Repo}
  alias ClaudiverseServer.AppBuilds.AppBuild

  setup do
    dir = Path.join(System.tmp_dir!(), "app-builds-#{System.unique_integer([:positive])}")
    Application.put_env(:claudiverse_server, :app_builds_dir, dir)

    on_exit(fn ->
      Application.delete_env(:claudiverse_server, :app_builds_dir)
      Application.delete_env(:claudiverse_server, :app_builds_max_bytes)
      File.rm_rf(dir)
    end)

    {user, api} = user_with_token()
    app = Accounts.create_user_api_token(user, "app")
    %{dir: dir, api: api, app: app}
  end

  defp apk_file(bytes) do
    p = Path.join(System.tmp_dir!(), "apk-#{System.unique_integer([:positive])}.apk")
    File.write!(p, bytes)
    on_exit(fn -> File.rm(p) end)
    p
  end

  defp publish(token, bytes, attrs) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> post("/api/app/builds", Map.put(attrs, "apk", %Plug.Upload{path: apk_file(bytes), filename: "app.apk"}))
  end

  defp as(token), do: build_conn() |> put_req_header("authorization", "Bearer " <> token)
  defp sha(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
  defp stored(dir), do: if(File.dir?(dir), do: File.ls!(dir), else: [])
  defp rows, do: Repo.aggregate(from(b in AppBuild), :count)

  @v1 %{"version_code" => "2057", "version_name" => "1.0.2057", "commit" => "abc123"}
  @v2 %{"version_code" => "2058", "version_name" => "1.0.2058", "commit" => "def456", "notes" => "fixes"}

  test "publishing with the shared token is 403 and stores nothing", ctx do
    assert publish(ctx.api, "PK-apk-1", @v1) |> json_response(403) == %{"error" => "publishing app builds is app-only"}
    assert stored(ctx.dir) == [] and rows() == 0
  end

  test "publish, then latest and the download match: sha256, type, bytes", ctx do
    bytes = :crypto.strong_rand_bytes(4096)
    b = publish(ctx.app, bytes, @v1) |> json_response(200)
    assert b["sha256"] == sha(bytes) and b["size"] == 4096 and b["version_code"] == 2057

    latest = as(ctx.api) |> get("/api/app/builds/latest") |> json_response(200)
    assert latest["id"] == b["id"] and latest["url"] == "/api/app/builds/#{b["id"]}/apk"

    r = as(ctx.api) |> get(latest["url"])
    assert r.status == 200
    assert get_resp_header(r, "content-type") == ["application/vnd.android.package-archive"]
    assert sha(r.resp_body) == latest["sha256"]
  end

  test "a second publish replaces the first: one build kept, the old id is gone", ctx do
    b1 = publish(ctx.app, "first", @v1) |> json_response(200)
    b2 = publish(ctx.app, "second", @v2) |> json_response(200)

    assert as(ctx.api) |> get("/api/app/builds/latest") |> json_response(200) |> Map.fetch!("version_code") == 2058
    assert rows() == 1 and length(stored(ctx.dir)) == 1
    assert as(ctx.api) |> get("/api/app/builds/#{b1["id"]}/apk") |> json_response(404)
    assert as(ctx.api) |> get("/api/app/builds/#{b2["id"]}/apk") |> response(200) == "second"
  end

  test "a failed publish leaves the stored build untouched", ctx do
    b1 = publish(ctx.app, "keep me", @v1) |> json_response(200)
    assert publish(ctx.app, "bad", %{"version_name" => "x"}) |> json_response(422)

    assert as(ctx.api) |> get("/api/app/builds/latest") |> json_response(200) |> Map.fetch!("id") == b1["id"]
    assert rows() == 1 and length(stored(ctx.dir)) == 1
  end

  test "over the cap is 413 and the stored build stays", ctx do
    publish(ctx.app, "small", @v1) |> json_response(200)
    Application.put_env(:claudiverse_server, :app_builds_max_bytes, 10)
    assert publish(ctx.app, "this is more than ten bytes", @v2) |> json_response(413)
    assert rows() == 1 and length(stored(ctx.dir)) == 1
  end

  test "latest with no builds is 404", ctx do
    assert as(ctx.api) |> get("/api/app/builds/latest") |> json_response(404) == %{"error" => "no builds"}
  end
end
