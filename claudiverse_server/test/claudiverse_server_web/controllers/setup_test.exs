defmodule ClaudiverseServerWeb.SetupTest do
  @moduledoc """
  First-run sign-up (ClaudiverseServer.Setup): the first account is created
  with the server's one-time setup code, and then sign-up is closed for good.
  """
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.{LoginThrottle, Repo, Setup}
  alias ClaudiverseServer.Accounts.User

  setup do
    :sys.replace_state(LoginThrottle, fn _ -> %{} end)
    :ok
  end

  defp sign_up(body), do: build_conn() |> post("/api/setup", Map.merge(%{email: "first@test.com", password: "password123"}, body))
  defp setup_needed, do: build_conn() |> get("/api/setup") |> json_response(200) |> Map.fetch!("setup_needed")
  defp users, do: Repo.aggregate(User, :count)

  test "with no account, the right code creates it and signs it in as login does" do
    {:ok, code} = Setup.issue()

    %{"token" => token, "scope" => "app", "user" => %{"email" => "first@test.com"}} =
      sign_up(%{code: code, scope: "app", client: "web"}) |> json_response(200)

    assert users() == 1
    me = build_conn() |> put_req_header("authorization", "Bearer " <> token) |> get("/api/me") |> json_response(200)
    assert %{"user" => %{"email" => "first@test.com"}, "scope" => "app"} = me
  end

  test "the setup flag is true with no account and false after sign-up" do
    {:ok, code} = Setup.issue()
    assert setup_needed() == true
    sign_up(%{code: code}) |> json_response(200)
    assert setup_needed() == false
  end

  test "a wrong code is refused and creates nothing; the right one still works" do
    {:ok, code} = Setup.issue()

    assert %{"error" => "wrong setup code" <> _} = sign_up(%{code: "AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH"}) |> json_response(403)
    assert users() == 0
    sign_up(%{code: code}) |> json_response(200)
  end

  test "the code is accepted without its dashes and in any case" do
    {:ok, code} = Setup.issue()
    sign_up(%{code: code |> String.replace("-", "") |> String.downcase()}) |> json_response(200)
  end

  test "the code cannot be used twice" do
    {:ok, code} = Setup.issue()
    sign_up(%{code: code}) |> json_response(200)

    assert %{"error" => "this server already has an account" <> _} =
             sign_up(%{code: code, email: "second@test.com"}) |> json_response(403)

    assert users() == 1
  end

  test "once any account exists, sign-up is refused even with a code issued before it" do
    {:ok, code} = Setup.issue()
    user_fixture()

    assert setup_needed() == false
    sign_up(%{code: code}) |> json_response(403)
    assert Setup.issue() == {:error, :closed}
    assert users() == 1
  end

  test "a password the account rules refuse is a 422 and leaves the code valid" do
    {:ok, code} = Setup.issue()

    assert %{"errors" => %{"password" => [_]}} = sign_up(%{code: code, password: "short"}) |> json_response(422)
    assert users() == 0
    sign_up(%{code: code}) |> json_response(200)
  end

  test "a new code replaces the old one" do
    {:ok, old} = Setup.issue()
    {:ok, new} = Setup.issue()

    sign_up(%{code: old}) |> json_response(403)
    sign_up(%{code: new}) |> json_response(200)
  end

  test "codes are eight groups of four base32 characters (160 bits)" do
    {:ok, code} = Setup.issue()
    assert code =~ ~r/\A[A-Z2-7]{4}(-[A-Z2-7]{4}){7}\z/
  end

  test "sign-ups racing on an empty server create exactly one account" do
    {:ok, code} = Setup.issue()

    results =
      1..5
      |> Enum.map(fn i -> Task.async(fn -> Setup.sign_up(code, %{email: "racer#{i}@test.com", password: "password123"}) end) end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert users() == 1
  end

  test "wrong codes are throttled like failed sign-ins" do
    Application.put_env(:claudiverse_server, :login_max_failures, 2)
    on_exit(fn -> Application.put_env(:claudiverse_server, :login_max_failures, 1_000_000) end)
    {:ok, code} = Setup.issue()

    sign_up(%{code: "wrong"}) |> json_response(403)
    sign_up(%{code: "wrong"}) |> json_response(403)

    conn = sign_up(%{code: code})
    assert %{"retry_after" => _} = json_response(conn, 429)
    assert users() == 0
  end
end
