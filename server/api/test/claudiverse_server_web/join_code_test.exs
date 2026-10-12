defmodule ClaudiverseServerWeb.JoinCodeTest do
  @moduledoc """
  One-time join codes (ClaudiverseServer.JoinCodes): the panel's "Add a
  machine" mints one with an app token; the machine's installer redeems it,
  once, within its time, for the machine's seat and host tokens. A wrong,
  used or expired code gets one answer, and failed tries are throttled.
  """
  # Not async: LoginThrottle is one process, keyed by address.
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.{Accounts, JoinCodes, Repo}
  alias ClaudiverseServer.JoinCodes.JoinCode

  setup do
    {user, api} = user_with_token()
    app = Accounts.create_user_api_token(user, "app")
    # Each test from its own address, so the throttle of one never reaches another.
    ip = {10, 99, rem(System.unique_integer([:positive]), 250), 1}
    %{user: user, api: api, app: app, ip: ip}
  end

  defp as(token), do: build_conn() |> put_req_header("authorization", "Bearer " <> token)
  defp from(ip), do: %{build_conn() | remote_ip: ip}
  defp mint(ctx, body \\ %{}), do: as(ctx.app) |> post("/api/join_codes", body) |> json_response(201)
  defp redeem(ctx, body), do: from(ctx.ip) |> post("/api/join", body)

  test "Add a machine mints a code and the one-liner that uses it; app tokens only", ctx do
    assert %{"error" => _} = as(ctx.api) |> post("/api/join_codes", %{}) |> json_response(403)

    %{"code" => code, "expires_at" => exp, "server" => server, "command" => cmd, "machine" => nil} = mint(ctx)
    assert code =~ ~r/\A[A-Z2-9]{4}-[A-Z2-9]{4}\z/
    assert server == "http://www.example.com"
    assert cmd == "curl -fsSL https://raw.githubusercontent.com/Promises/claudiverse/main/install/install.sh | sh -s -- --machine --url #{server} --join #{code}"
    {:ok, exp, _} = DateTime.from_iso8601(exp)
    assert_in_delta DateTime.diff(exp, DateTime.utc_now()), 15 * 60, 5
    assert Repo.get_by(JoinCode, code_hash: code) == nil, "the code itself is never stored"
  end

  test "a code is redeemed once, for both tokens; they work, and the second try is refused", ctx do
    %{"code" => code} = mint(ctx)

    %{"machine" => "my-laptop", "seat_token" => seat, "host_token" => host} =
      redeem(ctx, %{code: String.downcase(code), machine: "my-laptop"}) |> json_response(200)
    assert {:ok, user, "api"} = Accounts.fetch_api_token(seat)
    assert user.id == ctx.user.id
    assert {:ok, _, "host:my-laptop"} = Accounts.fetch_api_token(host) |> then(fn _ -> host_context(host) end)

    assert %{"error" => "this join code is unknown, used or expired" <> _} = redeem(ctx, %{code: code, machine: "my-laptop"}) |> json_response(403)
  end

  test "a code minted for a machine names it; the installer's name does not win", ctx do
    %{"code" => code, "machine" => "studio"} = mint(ctx, %{machine: "studio"})
    assert %{"machine" => "studio"} = redeem(ctx, %{code: code, machine: "something-else"}) |> json_response(200)
  end

  test "a wrong, an expired and an unnamed code: clean refusals that give nothing away", ctx do
    assert %{"error" => "this join code is unknown" <> _} = redeem(ctx, %{code: "ABCD-EFGH", machine: "m"}) |> json_response(403)
    assert %{"error" => "this join code is unknown" <> _} = redeem(ctx, %{machine: "m"}) |> json_response(403)

    {:ok, old, _} = JoinCodes.mint(ctx.user, nil, DateTime.add(DateTime.utc_now(), -16 * 60, :second))
    assert %{"error" => "this join code is unknown" <> _} = redeem(ctx, %{code: old, machine: "m"}) |> json_response(403)

    %{"code" => live} = mint(ctx)
    assert %{"error" => "machine is required" <> _} = redeem(ctx, %{code: live}) |> json_response(422)
    assert %{"error" => "machine must be" <> _} = redeem(ctx, %{code: live, machine: "a b"}) |> json_response(422)
    assert %{"machine" => "ok-now"} = redeem(ctx, %{code: live, machine: "ok-now"}) |> json_response(200), "a name error does not spend the code"
  end

  test "failed redeems from one address are throttled", ctx do
    # The test config lifts the sign-in limit; put the production one back.
    prev = Application.get_env(:claudiverse_server, :login_max_failures)
    Application.put_env(:claudiverse_server, :login_max_failures, 5)
    on_exit(fn -> Application.put_env(:claudiverse_server, :login_max_failures, prev) end)

    statuses = for _ <- 1..6, do: redeem(ctx, %{code: "ZZZZ-ZZZZ", machine: "m"}).status
    :sys.get_state(ClaudiverseServer.LoginThrottle)
    assert statuses == [403, 403, 403, 403, 403, 429]
  end

  defp host_context(token) do
    {:ok, decoded} = Base.url_decode64(token)
    {user, ctx} = Repo.one(ClaudiverseServer.Accounts.UserToken.by_token_and_contexts_query(decoded, ["host:my-laptop"]))
    {:ok, user, ctx}
  end
end
