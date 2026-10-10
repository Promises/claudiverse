defmodule ClaudiverseServerWeb.SuperTokenTest do
  @moduledoc """
  Sign-in scopes (api / app / super), the sign-in throttle, and what only a
  super (desktop) token may do: the token list, host tokens, and changing a
  machine's whitelist through its agent.
  """
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures
  import Phoenix.ChannelTest, except: [connect: 2, connect: 3]

  @endpoint ClaudiverseServerWeb.Endpoint

  alias ClaudiverseServer.{Accounts, LoginThrottle}
  alias ClaudiverseServerWeb.{HostChannel, UserSocket}

  setup do
    user = user_fixture(%{email: "op@test.com", password: "password123"})
    :sys.replace_state(LoginThrottle, fn _ -> %{} end)
    %{user: user}
  end

  defp login(body), do: build_conn() |> post("/api/auth/login", Map.merge(%{email: "op@test.com", password: "password123"}, body))
  defp token!(scope, client \\ nil), do: login(%{scope: scope, client: client}) |> json_response(200) |> Map.fetch!("token")
  defp as(token), do: build_conn() |> put_req_header("authorization", "Bearer " <> token)

  defp agent!(user, name, payload) do
    {:ok, host} = Accounts.create_host_token(user, name)
    {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{"token" => host})
    {:ok, _, chan} = subscribe_and_join(socket, HostChannel, "host:" <> name, payload)
    chan
  end

  # --- sign-in -----------------------------------------------------------------------

  test "sign-in gives the scope asked for, labelled with the client" do
    for {scope, client} <- [{nil, nil}, {"app", "pixel-10"}, {"super", "desktop"}] do
      body = %{scope: scope, client: client} |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
      %{"token" => t, "scope" => got} = login(body) |> json_response(200)
      assert got == (scope || "api")
      assert %{"scope" => ^got} = as(t) |> get("/api/me") |> json_response(200)
    end

    labels = for t <- Accounts.list_tokens(Accounts.get_user_by_email("op@test.com")), do: {t.context, t.label}
    assert {"super", "desktop"} in labels and {"app", "pixel-10"} in labels and {"api", "api"} in labels
  end

  test "sign-in refuses an unknown scope or a bad client name, and a host scope" do
    for body <- [%{scope: "admin"}, %{scope: "host:m5"}, %{client: "bad\nname"}, %{client: String.duplicate("x", 65)}] do
      assert login(body) |> json_response(400), inspect(body)
    end
  end

  test "a super token has the app's powers; an api token has neither", %{user: user} do
    super = token!("super", "desktop")
    api = token!(nil)
    s = session_fixture(user, %{title: "seat", host: "m9", working_directory: "/w", claude_session_id: "6d9b917b-1779-49d0-b95b-ad36f8a84f8b", status: :stopped})

    # past the app-only check: the machine is offline
    assert as(super) |> post("/api/sessions/#{s.id}/resume") |> json_response(504)
    assert as(api) |> post("/api/sessions/#{s.id}/resume") |> json_response(403)
  end

  # --- throttle ----------------------------------------------------------------------

  test "failed sign-ins are throttled, even for the right password, and a success clears them" do
    Application.put_env(:claudiverse_server, :login_max_failures, 2)
    on_exit(fn -> Application.put_env(:claudiverse_server, :login_max_failures, 1_000_000) end)

    assert login(%{password: "wrong"}) |> json_response(401)
    assert login(%{}) |> json_response(200), "one failure, then a success, clears the address"
    assert login(%{password: "wrong"}) |> json_response(401)
    assert login(%{password: "wrong"}) |> json_response(401)

    conn = login(%{})
    assert %{"retry_after" => retry} = json_response(conn, 429)
    assert retry > 0 and get_resp_header(conn, "retry-after") == [Integer.to_string(retry)]
  end

  # --- logout --------------------------------------------------------------------------

  test "logout revokes a signed-in super token, but never a server-minted app token", %{user: user} do
    super = token!("super", "desktop")
    minted = Accounts.create_user_api_token(user, "app")

    for t <- [super, minted], do: as(t) |> delete("/api/auth/logout") |> json_response(200)

    assert as(super) |> get("/api/me") |> json_response(401)
    assert as(minted) |> get("/api/me") |> json_response(200)
  end

  # --- the token list --------------------------------------------------------------------

  test "only a super token may list or revoke tokens", %{user: user} do
    app = Accounts.create_user_api_token(user, "app")
    for t <- [app, token!(nil)] do
      assert as(t) |> get("/api/tokens") |> json_response(403)
      assert as(t) |> delete("/api/tokens/1") |> json_response(403)
    end
  end

  test "the list shows every token without its value and marks the caller's", %{user: user} do
    super = token!("super", "desktop")
    _fleet = Accounts.create_user_api_token(user)

    %{"tokens" => tokens} = as(super) |> get("/api/tokens") |> json_response(200)
    assert Enum.all?(tokens, &(Map.keys(&1) |> Enum.sort() == ~w(context current id inserted_at label)))
    assert [%{"label" => "desktop", "context" => "super"}] = Enum.filter(tokens, & &1["current"])
    refute inspect(tokens) =~ super
  end

  test "revoke: a lost phone's app token and a sign-in go; the fleet's seat token is protected; others' are not found", %{user: user} do
    super = token!("super", "desktop")
    phone = Accounts.create_user_api_token(user, "app")
    fleet = Accounts.create_user_api_token(user)
    {other, _} = user_with_token(%{email: "other@test.com"})
    theirs = Accounts.create_user_api_token(other, "app")

    id = fn token -> {:ok, id} = Accounts.token_id(token); id end

    assert as(super) |> delete("/api/tokens/#{id.(phone)}") |> json_response(200)
    assert as(phone) |> get("/api/me") |> json_response(401)

    assert as(super) |> delete("/api/tokens/#{id.(fleet)}") |> json_response(409)
    assert as(fleet) |> get("/api/me") |> json_response(200)

    assert as(super) |> delete("/api/tokens/#{id.(theirs)}") |> json_response(404)
    assert as(theirs) |> get("/api/me") |> json_response(200)
  end

  # --- machines ----------------------------------------------------------------------------

  test "a super token mints a host token that joins only that machine's channel", %{user: user} do
    assert as(Accounts.create_user_api_token(user, "app")) |> post("/api/hosts/new-box/token") |> json_response(403)
    assert as(token!("super")) |> post("/api/hosts/bad%20name/token") |> json_response(400)

    %{"name" => "new-box", "token" => host} = as(token!("super")) |> post("/api/hosts/new-box/token") |> json_response(201)
    {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{"token" => host})
    assert {:ok, _, _} = subscribe_and_join(socket, HostChannel, "host:new-box", %{})
    assert {:error, _} = subscribe_and_join(socket, HostChannel, "host:m5", %{})
  end

  test "connect_machine mints a working seat token labelled with the machine, and its host token", %{user: user} do
    {:ok, %{seat_token: seat, host_token: host}} = Accounts.connect_machine(user, "new-box")

    assert %{"scope" => "api"} = as(seat) |> get("/api/me") |> json_response(200)
    assert %{context: "api", label: "new-box"} = Enum.find(Accounts.list_tokens(user), &(&1.label == "new-box"))
    {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{"token" => host})
    assert {:ok, _, _} = subscribe_and_join(socket, HostChannel, "host:new-box", %{})

    assert Accounts.connect_machine(user, "bad name") == {:error, :bad_host_name}
  end

  test "hosts shows whether a machine accepts remote folders", %{user: user} do
    agent!(user, "m5", %{"roots" => ["/srv"], "remote_roots" => true})
    agent!(user, "m1", %{"roots" => []})

    hosts = as(token!(nil)) |> get("/api/hosts") |> json_response(200) |> Map.fetch!("hosts")
    assert %{"remote_roots" => true} = Enum.find(hosts, &(&1["name"] == "m5"))
    assert %{"remote_roots" => false} = Enum.find(hosts, &(&1["name"] == "m1"))
  end

  test "folder changes are super-only, relayed to the agent, and its refusal passed on", %{user: user} do
    chan = agent!(user, "m5", %{"roots" => ["/srv"]})
    app = Accounts.create_user_api_token(user, "app")
    super = token!("super", "desktop")

    assert as(app) |> post("/api/hosts/m5/roots", %{path: "/srv/new"}) |> json_response(403)
    assert as(super) |> post("/api/hosts/m5/roots", %{path: "relative"}) |> json_response(400)
    refute_push "request", _

    t = Task.async(fn -> as(super) |> post("/api/hosts/m5/roots", %{path: "/srv/new"}) end)
    assert_push "request", %{"request_id" => rid, "op" => "add_root", "args" => %{"path" => "/srv/new"}}
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => false, "code" => "not_allowed", "error" => "this machine does not accept remote folders"})
    assert Task.await(t) |> json_response(403) == %{"error" => "this machine does not accept remote folders", "code" => "not_allowed"}

    t = Task.async(fn -> as(super) |> delete("/api/hosts/m5/roots", %{path: "/srv"}) end)
    assert_push "request", %{"request_id" => rid, "op" => "remove_root", "args" => %{"path" => "/srv"}}
    Phoenix.ChannelTest.push(chan, "reply", %{"request_id" => rid, "ok" => true, "result" => %{"roots" => []}})
    assert Task.await(t) |> json_response(200) == %{"roots" => []}
  end
end
