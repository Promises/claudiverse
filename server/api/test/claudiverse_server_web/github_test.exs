defmodule ClaudiverseServerWeb.GitHubTest.MockGitHub do
  @moduledoc false
  # A stand-in for api.github.com: answers by the token it is given. Shapes as
  # GitHub's REST API returns them (GET /user, GET /user/repos with a Link
  # header, the token-expiration and scopes headers).
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    "Bearer " <> token = conn |> get_req_header("authorization") |> List.first()
    conn = put_resp_content_type(conn, "application/json")

    case {conn.request_path, token} do
      {_, "github_pat_REVOKED" <> _} ->
        send_resp(conn, 401, ~s({"message":"Bad credentials","documentation_url":"https://docs.github.com/rest"}))

      {"/user", token} ->
        conn
        |> headers_for(token)
        |> send_resp(200, ~s({"login":"example-user","id":1,"type":"User"}))

      {"/user/repos", _} ->
        if conn.query_string =~ "page=2" do
          send_resp(conn, 200, Jason.encode!(for i <- 1..50, do: %{"full_name" => "example-org/repo-#{i + 100}"}))
        else
          next = "http://#{conn.host}:#{conn.port}/user/repos?per_page=100&page=2"

          conn
          |> put_resp_header("link", ~s(<#{next}>; rel="next", <#{next}>; rel="last"))
          |> send_resp(200, Jason.encode!(for i <- 1..100, do: %{"full_name" => "example-org/repo-#{i}"}))
        end
    end
  end

  defp headers_for(conn, "ghp_" <> _), do: put_resp_header(conn, "x-oauth-scopes", "repo, read:org")
  # Expires in 3 days: inside the 7-day warning.
  defp headers_for(conn, "github_pat_SOON" <> _),
    do: put_resp_header(conn, "github-authentication-token-expiration", stamp(DateTime.add(DateTime.utc_now(), 3 * 86_400)))
  # What GitHub was seen to send for a fine-grained token: the current time.
  defp headers_for(conn, "github_pat_NOW" <> _),
    do: put_resp_header(conn, "github-authentication-token-expiration", stamp(DateTime.utc_now()))
  defp headers_for(conn, "github_pat_NEVER" <> _), do: conn
  defp headers_for(conn, "github_pat_" <> _), do: put_resp_header(conn, "github-authentication-token-expiration", "2027-01-10 16:20:42 +0500")

  defp stamp(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")
end

defmodule ClaudiverseServerWeb.GitHubTest do
  use ClaudiverseServerWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.AnthropicAuths.Vault
  alias ClaudiverseServer.GitHub
  alias ClaudiverseServer.{Accounts, Repo}

  @fine "github_pat_11AAAAAAA0exampleFineGrainedSecretValue0123456789"
  # Built, not written out: no literal here has a real token's shape.
  @classic "ghp" <> "_exampleClassicSecretValue0123456789abcd"

  setup do
    {:ok, gh} = Bandit.start_link(plug: __MODULE__.MockGitHub, port: 0, ip: :loopback, startup_log: false)
    {:ok, {_, port}} = ThousandIsland.listener_info(gh)
    prev = Application.get_env(:claudiverse_server, :github_api_url)
    Application.put_env(:claudiverse_server, :github_api_url, "http://127.0.0.1:#{port}")

    on_exit(fn ->
      if prev, do: Application.put_env(:claudiverse_server, :github_api_url, prev), else: Application.delete_env(:claudiverse_server, :github_api_url)
    end)

    {user, api} = user_with_token()
    %{user: user, api: api, app: Accounts.create_user_api_token(user, "app")}
  end

  defp as(token), do: build_conn() |> put_req_header("authorization", "Bearer " <> token)
  defp add(ctx, label, secret), do: as(ctx.app) |> post("/api/github/tokens", %{label: label, token: secret})

  test "a fine-grained token: checked, stored encrypted, shown by what GitHub said, never itself", ctx do
    body = add(ctx, "personal", @fine) |> json_response(201)

    assert %{"token" => %{"label" => "personal", "kind" => "fine_grained", "login" => "example-user", "scopes" => nil,
                          "expires_at" => "2027-01-10T11:20:42Z", "expiring" => false, "repos_count" => 150, "status" => "ok"}} = body
    listed = as(ctx.app) |> get("/api/github/tokens") |> json_response(200)
    refute Jason.encode!([body, listed]) =~ "SecretValue"

    # In the database: ciphertext, readable only as a GitHub token.
    [row] = Repo.all(GitHub.Token)
    refute row.token =~ "SecretValue"
    assert GitHub.secret(row) == @fine
    assert Vault.decrypt(row.token) == nil, "the pool's label must not open it"
  end

  test "a classic token's scopes; one that never expires has no expiry; one within 7 days is flagged", ctx do
    assert %{"token" => %{"kind" => "classic", "scopes" => ["repo", "read:org"], "expires_at" => nil}} =
             add(ctx, "classic", @classic) |> json_response(201)
    assert %{"token" => %{"expires_at" => nil, "expiring" => false}} =
             add(ctx, "forever", "github_pat_NEVERexampleSecretValue0123456789") |> json_response(201)
    assert %{"token" => %{"expiring" => true}} = add(ctx, "soon", "github_pat_SOONexampleSecretValue0123456789") |> json_response(201)
  end

  test "an expiry of 'now' on an answer GitHub served is GitHub misreporting, not an expired token", ctx do
    assert %{"token" => %{"expires_at" => nil, "status" => "ok"}} =
             add(ctx, "org", "github_pat_NOWexampleSecretValue0123456789") |> json_response(201)
  end

  test "an expiry the operator enters is used when GitHub reports none, and only then", ctx do
    %{"token" => %{"id" => id}} = add(ctx, "forever", "github_pat_NEVERexampleSecretValue0123456789") |> json_response(201)
    soon = Date.utc_today() |> Date.add(3) |> Date.to_iso8601()

    assert %{"token" => %{"expires_on" => ^soon, "expiry_source" => "manual", "expiring" => true}} =
             as(ctx.app) |> patch("/api/github/tokens/#{id}", %{expires_on: soon}) |> json_response(200)
    assert %{"token" => %{"expires_at" => nil, "expiry_source" => nil, "expiring" => false}} =
             as(ctx.app) |> patch("/api/github/tokens/#{id}", %{expires_on: nil}) |> json_response(200)
    assert as(ctx.app) |> patch("/api/github/tokens/#{id}", %{expires_on: "soon"}) |> json_response(400)

    # GitHub's own expiry wins over one entered.
    %{"token" => %{"id" => fid}} = add(ctx, "personal", @fine) |> json_response(201)
    assert %{"token" => %{"expires_at" => "2027-01-10T11:20:42Z", "expiry_source" => "github"}} =
             as(ctx.app) |> patch("/api/github/tokens/#{fid}", %{expires_on: soon}) |> json_response(200)
  end

  test "the repositories a token reaches are kept, for reading each repo with a token that sees it", ctx do
    add(ctx, "personal", @fine) |> json_response(201)
    [row] = Repo.all(GitHub.Token)
    assert length(row.repos) == 150 and "example-org/repo-150" in row.repos
  end

  test "a token GitHub refuses is not stored; a stored one that is revoked later says so when checked", ctx do
    assert %{"error" => "GitHub refused the token (401)" <> _} =
             add(ctx, "bad", "github_pat_REVOKEDexampleSecretValue0123456789") |> json_response(422)
    assert Repo.all(GitHub.Token) == []

    %{"token" => %{"id" => id}} = add(ctx, "personal", @fine) |> json_response(201)
    Repo.update_all(GitHub.Token, set: [token: Vault.encrypt("github_pat_REVOKEDexampleSecretValue0123456789", "github_tokens.v1")])
    assert %{"token" => %{"status" => "unauthorized", "last_error" => "GitHub refused the token (401)" <> _}} =
             as(ctx.app) |> post("/api/github/tokens/#{id}/check") |> json_response(200)
  end

  test "the token never reaches the log, even at debug level with every request's parameters", ctx do
    prev = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: prev) end)

    log =
      capture_log([level: :debug], fn ->
        %{"token" => %{"id" => id}} = add(ctx, "personal", @fine) |> json_response(201)
        as(ctx.app) |> post("/api/github/tokens/#{id}/check") |> json_response(200)
      end)

    assert log =~ "/api/github/tokens", "the requests were logged"
    refute log =~ "SecretValue"
  end

  test "which token reads each subscription, and which subscriptions each token serves", ctx do
    fine = insert_token!(ctx.user, "personal", "fine_grained", ["example-org/example-repo"])
    classic = insert_token!(ctx.user, "collab", "classic", ["example-org/example-repo", "someone-else/their-repo"])
    watch!(ctx.user, "seat-a", ["gh:example-org/example-repo:prs", "gh:someone-else/their-repo", "gh:@me", "other-seat"])
    watch!(ctx.user, "seat-b", ["gh:nobody/unreached", "gh:example-org/example-repo#7", "@github"])
    {other, _} = user_with_token(%{email: "other@example.com"})
    watch!(other, "their-seat", ["gh:their-org/secret-repo"])

    # A seat's own token may read these two (cv_gh_subscriptions, cv_gh_repos).
    subs = as(ctx.api) |> get("/api/github/subscriptions") |> json_response(200) |> Map.fetch!("subscriptions")
    by = Map.new(subs, &{&1["title"], &1})

    assert Map.keys(by) == ["@github", "gh:@me", "gh:example-org/example-repo#7", "gh:example-org/example-repo:prs", "gh:nobody/unreached", "gh:someone-else/their-repo"]
    assert %{"seats" => ["seat-a"], "repo" => "example-org/example-repo", "token" => %{"label" => "personal"}, "reached" => true} = by["gh:example-org/example-repo:prs"]
    assert %{"token" => %{"label" => "collab", "kind" => "classic"}} = by["gh:someone-else/their-repo"]
    assert %{"token" => nil, "reached" => false, "unreached" => "no_token"} = by["gh:nobody/unreached"]
    assert %{"unreached" => nil} = by["gh:example-org/example-repo:prs"]

    # A token whose list was never loaded: that, not "no token reaches it".
    insert_token!(ctx.user, "unloaded", "fine_grained", nil)
    subs = as(ctx.api) |> get("/api/github/subscriptions") |> json_response(200) |> Map.fetch!("subscriptions")
    assert %{"unreached" => "repos_not_loaded"} = Enum.find(subs, &(&1["title"] == "gh:nobody/unreached"))
    assert %{"repo" => nil, "reached" => true, "seats" => ["seat-a"]} = by["gh:@me"]

    tokens = as(ctx.app) |> get("/api/github/tokens") |> json_response(200) |> Map.fetch!("tokens") |> Map.new(&{&1["label"], &1})
    assert tokens["personal"]["serving"] == ["example-org/example-repo"]
    assert tokens["collab"]["serving"] == ["someone-else/their-repo"]

    assert [%{"repo" => "example-org/example-repo", "token" => %{"id" => fid}}, %{"repo" => "someone-else/their-repo", "token" => %{"id" => cid}}] =
             as(ctx.api) |> get("/api/github/repos") |> json_response(200) |> Map.fetch!("repos")
    assert {fid, cid} == {fine.id, classic.id}
  end

  defp insert_token!(user, label, kind, repos) do
    Repo.insert!(%GitHub.Token{user_id: user.id, label: label, kind: kind, token: Vault.encrypt("x", "github_tokens.v1"), repos: repos, status: "ok"})
  end

  defp watch!(user, title, watch) do
    s = session_fixture(user, %{title: title, status: :running})
    {:ok, _} = ClaudiverseServer.Notifications.Router.subscribe(title, s.id, watch)
  end

  test "app or super only; a malformed token or label is refused before GitHub is asked", ctx do
    assert %{"error" => "GitHub tokens are app-only"} = as(ctx.api) |> get("/api/github/tokens") |> json_response(403)
    assert as(ctx.api) |> post("/api/github/tokens", %{label: "x", token: @fine}) |> json_response(403)
    assert %{"error" => "that is not a GitHub token" <> _} = add(ctx, "x", "not a token") |> json_response(400)
    assert %{"error" => "label must be" <> _} = add(ctx, "", @fine) |> json_response(400)
    add(ctx, "personal", @fine) |> json_response(201)
    assert add(ctx, "personal", @classic) |> json_response(409)
  end
end
