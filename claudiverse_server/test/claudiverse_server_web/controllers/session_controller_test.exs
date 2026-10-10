defmodule ClaudiverseServerWeb.SessionControllerTest do
  use ClaudiverseServerWeb.ConnCase

  import ClaudiverseServer.Fixtures

  setup do
    {user, token} = user_with_token()
    %{user: user, token: token}
  end

  defp auth(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  test "list sessions returns empty for new user", %{conn: conn, token: token} do
    conn = conn |> auth(token) |> get("/api/sessions")
    assert %{"sessions" => []} = json_response(conn, 200)
  end

  test "create session", %{conn: conn, token: token} do
    conn =
      conn
      |> auth(token)
      |> post("/api/sessions", %{title: "My Session", model: "opus"})

    assert %{"session" => session} = json_response(conn, 201)
    assert session["title"] == "My Session"
    assert session["type"] == "sidecar"
    assert session["model"] == "opus"
    assert session["status"] == "running"
  end

  test "list sessions after create", %{conn: conn, token: token} do
    conn |> auth(token) |> post("/api/sessions", %{title: "S1"})
    conn = build_conn() |> auth(token) |> get("/api/sessions")

    assert %{"sessions" => [%{"title" => "S1"}]} = json_response(conn, 200)
  end

  test "show session", %{conn: conn, token: token} do
    resp = conn |> auth(token) |> post("/api/sessions", %{title: "Show Me"})
    %{"session" => %{"id" => id}} = json_response(resp, 201)

    conn = build_conn() |> auth(token) |> get("/api/sessions/#{id}")
    assert %{"session" => %{"title" => "Show Me"}} = json_response(conn, 200)
  end

  test "show session not found", %{conn: conn, token: token} do
    conn = conn |> auth(token) |> get("/api/sessions/99999")
    assert json_response(conn, 404)
  end

  test "delete session", %{conn: conn, token: token} do
    resp = conn |> auth(token) |> post("/api/sessions", %{title: "Delete Me"})
    %{"session" => %{"id" => id}} = json_response(resp, 201)

    conn = build_conn() |> auth(token) |> delete("/api/sessions/#{id}")
    assert %{"ok" => true} = json_response(conn, 200)

    conn = build_conn() |> auth(token) |> get("/api/sessions/#{id}")
    assert json_response(conn, 404)
  end

  test "users cannot see each other's sessions", %{conn: conn, token: token} do
    conn |> auth(token) |> post("/api/sessions", %{title: "Private"})

    {_other, other_token} = user_with_token(%{email: "other@test.com"})
    conn = build_conn() |> auth(other_token) |> get("/api/sessions")
    assert %{"sessions" => []} = json_response(conn, 200)
  end

  test "unauthenticated requests rejected", %{conn: conn} do
    conn = get(conn, "/api/sessions")
    assert json_response(conn, 401)
  end
end
