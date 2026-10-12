defmodule ClaudiverseServerWeb.ReauthorizeAuthTest do
  @moduledoc """
  Re-authorizing a pool account in one step (operator 2026-10-12: "android app
  needs a quick and easy way to reauth"). The account keeps its id, label,
  priority and cooldown; a login of another account is refused unless forced;
  and the pool announces the account going out (`needs_reauth`, once per
  transition) and coming back (`reauthorized`).

  The code exchange itself is Anthropic's (OAuth.exchange_code/3), so the
  account side is exercised through AnthropicAuths.store_reauthorization/5 with
  the tokens an exchange returns, as the enrolment tests do with
  store_enrolment/5; the route is exercised up to the exchange.
  """
  # Not async: SQLite has one writer (see anthropic_auth_last_resort_test).
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.{Accounts, AnthropicAuths, Repo}
  alias ClaudiverseServer.AnthropicAuths.AnthropicAuth

  @tokens %{"access_token" => "new-access", "refresh_token" => "new-refresh", "expires_in" => 3600}
  @personal "personal@example.com"
  @work "work@example.com"
  @personal_uuid "0a1b2c3d-personal"
  @work_uuid "4e5f6a7b-work"
  @rejected "refresh rejected with HTTP 400"

  setup do
    {user, api} = user_with_token()
    app = Accounts.create_user_api_token(user, "app")
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, AnthropicAuths.pool_topic())

    # A re-enrolment nudges the usage poller, which reads the pool: let it into
    # this test's sandbox, and let it finish before the test ends.
    if poller = Process.whereis(ClaudiverseServer.AnthropicAuths.UsagePoller) do
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), poller)
      on_exit(fn -> :sys.get_state(poller) end)
    end

    %{api: api, app: app}
  end

  defp as(token), do: build_conn() |> put_req_header("authorization", "Bearer " <> token)
  defp in_seconds(s), do: DateTime.utc_now() |> DateTime.add(s, :second) |> DateTime.truncate(:second)
  defp reload(a), do: Repo.get!(AnthropicAuth, a.id)

  defp usage(weekly_pct) do
    %{"limits" => [%{"kind" => "weekly_all", "percent" => weekly_pct, "resets_at" => DateTime.to_iso8601(in_seconds(2 * 86_400))}]}
  end

  # Personal as it was at 03:51Z: its refresh token rejected.
  defp personal!(attrs \\ %{}) do
    Repo.insert!(struct(%AnthropicAuth{label: "Personal", priority: 10, status: "needs_reauth", cooldown_reason: @rejected,
                                       account_email: @personal, access_token: "old-access"}, attrs))
  end

  defp login(email, uuid \\ nil), do: %{email: email, uuid: uuid}
  defp row(a), do: %{email: a.account_email, uuid: a.account_uuid}

  # What the token endpoint answers, with the account it names (as Claude Code reads it).
  defp tokens_for(email, uuid), do: Map.put(@tokens, "account", %{"email_address" => email, "uuid" => uuid})

  defp events(change) do
    receive do
      {"pool", %{"change" => ^change} = e} -> [e | events(change)]
    after
      200 -> []
    end
  end

  # --- re-authorization ----------------------------------------------------------

  test "re-authorization keeps id, label and priority, leaves needs_reauth, and says so" do
    p = personal!()
    {:ok, a} = AnthropicAuths.store_reauthorization(p, @tokens, login("PERSONAL@example.com "), usage(40))

    assert {a.id, a.label, a.priority} == {p.id, "Personal", 10}
    assert a.status == "available"
    assert a.cooldown_reason == nil, "the re-auth reason does not linger on an available account"
    assert AnthropicAuth.decrypt_access_token(a) == "new-access"
    assert AnthropicAuths.pick().id == p.id

    assert [%{"auth_id" => id, "label" => "Personal", "was" => "needs_reauth", "status" => "available",
              "account_changed" => false, "text" => "POOL re-authorized: Personal (available)"}] = events("reauthorized")
    assert id == p.id
  end

  test "a login of another account is refused, naming both, and nothing is stored" do
    p = personal!()

    assert AnthropicAuths.store_reauthorization(p, @tokens, login(@work), usage(40)) == {:error, {:account_mismatch, row(p), login(@work)}}
    assert AnthropicAuths.store_reauthorization(p, @tokens, login(nil), usage(40)) == {:error, {:email_unknown, row(p)}}

    assert reload(p) == p
    assert events("reauthorized") == []
  end

  test "force takes the other account into the same row, on purpose" do
    p = personal!()
    {:ok, a} = AnthropicAuths.store_reauthorization(p, @tokens, login(@work, @work_uuid), usage(40), force: true)

    assert {a.id, a.label, a.priority, a.account_email, a.account_uuid} == {p.id, "Personal", 10, @work, @work_uuid}
    assert [%{"account_changed" => true, "text" => "POOL re-authorized: Personal (available; now a different account)"}] = events("reauthorized")
  end

  test "a row with no identity on record skips the check and takes the login's" do
    p = personal!(%{account_email: nil})
    assert {:ok, %{account_email: @work, account_uuid: @work_uuid}} = AnthropicAuths.store_reauthorization(p, @tokens, login(@work, @work_uuid), nil)
  end

  # --- which account a login is -----------------------------------------------------

  test "the login's identity is the token response's own account, no profile call needed" do
    assert AnthropicAuths.login_identity(tokens_for(@personal, @personal_uuid)) == login(@personal, @personal_uuid)
    assert AnthropicAuths.account_of(@tokens) == login(nil, nil)
    assert AnthropicAuths.account_of(tokens_for("", nil)) == login(nil, nil), "an empty email is no email"
  end

  test "the account uuid decides when both sides have one; the email when not" do
    p = personal!(%{account_uuid: @personal_uuid})

    assert {:error, {:account_mismatch, _, _}} = AnthropicAuths.store_reauthorization(p, @tokens, login(@personal, @work_uuid), nil),
           "the same email on another account is another account"
    assert {:error, {:email_unknown, _}} = AnthropicAuths.store_reauthorization(personal!(%{label: "P2", account_email: nil, account_uuid: @personal_uuid}), @tokens, login(@personal), nil),
           "a uuid on record and none from the login: nothing to compare"
    assert {:ok, %{account_email: "renamed@example.com", account_uuid: @personal_uuid}} =
             AnthropicAuths.store_reauthorization(p, @tokens, login("renamed@example.com", @personal_uuid), nil),
           "the same account under a changed email is the same account"
  end

  test "a refresh fills in the identity of a row that had none, and leaves it when the response names none" do
    w = Repo.insert!(%AnthropicAuth{label: "Work", priority: 20, status: "available"})

    {:ok, _} = AnthropicAuths.apply_refresh(w, @tokens)
    assert %{account_email: nil, account_uuid: nil} = reload(w)

    {:ok, _} = AnthropicAuths.apply_refresh(reload(w), tokens_for(@work, @work_uuid))
    assert %{account_email: @work, account_uuid: @work_uuid} = reload(w)

    {:ok, _} = AnthropicAuths.apply_refresh(reload(w), @tokens)
    assert %{account_email: @work, account_uuid: @work_uuid} = reload(w)
  end

  test "a cooldown survives re-authorization" do
    until = in_seconds(6 * 3600)
    p = personal!(%{cooldown_until: until})
    {:ok, a} = AnthropicAuths.store_reauthorization(p, @tokens, login(@personal), nil)

    assert a.status == "cooling_down"
    assert DateTime.compare(a.cooldown_until, until) == :eq
    assert a.cooldown_reason == "cooldown kept through re-authorization"
    refute AnthropicAuth.leasable?(a)
    assert [%{"status" => "cooling_down"}] = events("reauthorized")
  end

  test "re-enrolment without a priority keeps the account's own; a new account gets 100" do
    p = personal!()
    {:ok, again} = AnthropicAuths.store_enrolment("Personal", @tokens, @personal, nil, %{priority: nil})
    assert {again.id, again.priority} == {p.id, 10}

    {:ok, moved} = AnthropicAuths.store_enrolment("Personal", @tokens, @personal, nil, %{priority: 30})
    assert moved.priority == 30

    {:ok, fresh} = AnthropicAuths.store_enrolment("Spare", @tokens, nil, nil, %{priority: nil})
    assert fresh.priority == 100
    assert events("reauthorized") |> Enum.map(& &1["label"]) == ["Personal", "Personal"], "a new account is no re-authorization"
  end

  # --- needs_reauth --------------------------------------------------------------

  # An expired token with no refresh token stored: valid_token/1 marks it, with
  # no call to Anthropic.
  defp dead!(a), do: a |> Ecto.Changeset.change(expires_at: in_seconds(-60), refresh_token: nil) |> Repo.update!()

  test "needs_reauth fires once per transition: not on a repeat, not for a stored status, again after a re-auth" do
    work = Repo.insert!(%AnthropicAuth{label: "Work", priority: 20, status: "available", account_email: @work, access_token: "w"}) |> dead!()

    assert AnthropicAuths.valid_token(work) == {:error, :needs_reauth}
    assert [%{"auth_id" => id, "label" => "Work", "reason" => "no refresh token stored",
              "text" => "POOL needs re-auth: Work (no refresh token stored) — re-authorize in the app"}] = events("needs_reauth")
    assert id == work.id
    assert %{status: "needs_reauth", cooldown_reason: "no refresh token stored"} = reload(work)

    # A Check usage, a 401 report, a poll after a restart: the status is already stored.
    assert AnthropicAuths.valid_token(reload(work)) == {:error, :needs_reauth}
    assert AnthropicAuths.report_unauthorized(reload(work)) == {:error, :needs_reauth}
    assert events("needs_reauth") == []

    {:ok, back} = AnthropicAuths.store_reauthorization(reload(work), @tokens, login(@work), nil)
    assert [_] = events("reauthorized")
    assert AnthropicAuths.valid_token(dead!(back)) == {:error, :needs_reauth}
    assert [_] = events("needs_reauth")
  end

  # --- the routes ----------------------------------------------------------------

  test "the list says who needs re-auth, why, and which account it is", ctx do
    p = personal!()
    Repo.insert!(%AnthropicAuth{label: "Work", priority: 20, status: "cooling_down", cooldown_until: in_seconds(600), cooldown_reason: "rate limited"})

    %{"auths" => auths} = as(ctx.api) |> get("/api/anthropic_auths") |> json_response(200)
    assert %{"status" => "needs_reauth", "reauth_reason" => @rejected, "account_email" => @personal, "id" => id} =
             Enum.find(auths, &(&1["label"] == "Personal"))
    assert id == p.id
    assert %{"reauth_reason" => nil, "cooldown_reason" => "rate limited"} = Enum.find(auths, &(&1["label"] == "Work"))
  end

  test "the route: app-only, a known id, the code checked against its attempt", ctx do
    p = personal!()
    body = %{code: "the-code#other-state", verifier: "v", state: "this-state"}

    assert %{"error" => "forbidden"} = as(ctx.api) |> post("/api/anthropic_auths/#{p.id}/reauthorize/complete", body) |> json_response(403)
    assert %{"error" => "unknown auth"} = as(ctx.app) |> post("/api/anthropic_auths/999999/reauthorize/complete", body) |> json_response(404)
    assert %{"error" => "bad_request"} = as(ctx.app) |> post("/api/anthropic_auths/#{p.id}/reauthorize/complete", %{verifier: "v"}) |> json_response(400)
    assert %{"error" => "state_mismatch"} = as(ctx.app) |> post("/api/anthropic_auths/#{p.id}/reauthorize/complete", body) |> json_response(400)
    assert reload(p) == p
  end
end
