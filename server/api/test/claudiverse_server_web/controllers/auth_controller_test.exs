defmodule ClaudiverseServerWeb.AuthControllerTest do
  use ClaudiverseServerWeb.ConnCase

  import ClaudiverseServer.Fixtures

  test "login with valid credentials", %{conn: conn} do
    user_fixture(%{email: "login@test.com", password: "password123"})

    conn = post(conn, "/api/auth/login", %{email: "login@test.com", password: "password123"})

    assert %{"token" => token, "user" => %{"email" => "login@test.com"}} = json_response(conn, 200)
    assert is_binary(token)
  end

  test "login with wrong password", %{conn: conn} do
    user_fixture(%{email: "wrong@test.com", password: "password123"})

    conn = post(conn, "/api/auth/login", %{email: "wrong@test.com", password: "wrongpass"})

    assert %{"error" => "Invalid email or password"} = json_response(conn, 401)
  end

  test "me returns current user", %{conn: conn} do
    {_user, token} = user_with_token()

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/me")

    assert %{"user" => %{"email" => _}} = json_response(conn, 200)
  end

  test "me rejects invalid token", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer invalid")
      |> get("/api/me")

    assert json_response(conn, 401)
  end

  test "logout revokes only the token it was called with", %{conn: conn} do
    {user, web} = user_with_token()
    fleet = ClaudiverseServer.Accounts.create_user_api_token(user)
    app = ClaudiverseServer.Accounts.create_user_api_token(user, "app")

    conn |> put_req_header("authorization", "Bearer #{web}") |> delete("/api/auth/logout") |> json_response(200)

    me = fn token -> build_conn() |> put_req_header("authorization", "Bearer #{token}") |> get("/api/me") end
    assert json_response(me.(web), 401)
    assert %{"user" => _} = json_response(me.(fleet), 200)
    assert %{"user" => _} = json_response(me.(app), 200)
  end

  test "logging out with the app token does not revoke it", %{conn: conn} do
    user = user_fixture()
    app = ClaudiverseServer.Accounts.create_user_api_token(user, "app")

    conn |> put_req_header("authorization", "Bearer #{app}") |> delete("/api/auth/logout") |> json_response(200)

    assert build_conn() |> put_req_header("authorization", "Bearer #{app}") |> get("/api/me") |> json_response(200)
  end

  test "logout invalidates tokens", %{conn: conn} do
    {_user, token} = user_with_token()

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> delete("/api/auth/logout")

    assert %{"ok" => true} = json_response(conn, 200)

    # Token should no longer work
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/me")

    assert json_response(conn, 401)
  end
end
