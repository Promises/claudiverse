defmodule ClaudiverseServerWeb.PreferredAuthTest do
  @moduledoc """
  POST /api/anthropic_auths/:id/preferred: the operator chooses which pool
  account ranks first (operator 2026-10-06: "so we can switch which one is
  prioritized"). App or super token only.
  """
  # Not async: SQLite has one writer (see anthropic_auth_last_resort_test).
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.{Accounts, AnthropicAuths, Repo}
  alias ClaudiverseServer.AnthropicAuths.AnthropicAuth

  setup do
    {user, api} = user_with_token()
    app = Accounts.create_user_api_token(user, "app")
    personal = Repo.insert!(%AnthropicAuth{label: "Personal", priority: 10, status: "available"})
    work = Repo.insert!(%AnthropicAuth{label: "Work", priority: 20, status: "available"})
    spare = Repo.insert!(%AnthropicAuth{label: "Spare", priority: 30, status: "available"})

    # make_preferred/1 nudges the usage poller, which then reads the pool: let
    # it into this test's sandbox, and wait for it to finish before the test
    # ends (it must not crash on the nudge either).
    if poller = Process.whereis(ClaudiverseServer.AnthropicAuths.UsagePoller) do
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), poller)
      on_exit(fn -> :sys.get_state(poller) end)
    end

    %{api: api, app: app, personal: personal, work: work, spare: spare}
  end

  defp as(token), do: build_conn() |> put_req_header("authorization", "Bearer " <> token)

  test "the chosen account leases first; the rest keep their order", ctx do
    assert AnthropicAuths.pick().id == ctx.personal.id

    %{"auths" => auths} = as(ctx.app) |> post("/api/anthropic_auths/#{ctx.work.id}/preferred") |> json_response(200)
    assert Enum.map(auths, &{&1["label"], &1["priority"]}) == [{"Work", 10}, {"Personal", 20}, {"Spare", 30}]
    assert AnthropicAuths.pick().id == ctx.work.id

    # And back again.
    as(ctx.app) |> post("/api/anthropic_auths/#{ctx.personal.id}/preferred") |> json_response(200)
    assert AnthropicAuths.pick().id == ctx.personal.id
  end

  test "preferred is first choice, not forced: a cooling preferred account is skipped", ctx do
    as(ctx.app) |> post("/api/anthropic_auths/#{ctx.spare.id}/preferred") |> json_response(200)
    until = DateTime.utc_now() |> DateTime.add(600) |> DateTime.truncate(:second)
    ctx.spare |> Ecto.Changeset.change(cooldown_until: until, status: "cooling_down", cooldown_reason: "rate limited (429)") |> Repo.update!()
    assert AnthropicAuths.pick().id == ctx.personal.id
  end

  test "a seat token cannot change the preference; an unknown id is 404", ctx do
    assert as(ctx.api) |> post("/api/anthropic_auths/#{ctx.work.id}/preferred") |> json_response(403)
    assert AnthropicAuths.pick().id == ctx.personal.id
    assert as(ctx.app) |> post("/api/anthropic_auths/999999/preferred") |> json_response(404)
  end

  test "the list says which account is in use; a change is pushed as a pool event with who and current", ctx do
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, AnthropicAuths.pool_topic())
    assert %{"current_id" => cur} = as(ctx.api) |> get("/api/anthropic_auths") |> json_response(200)
    assert cur == ctx.personal.id

    %{"current_id" => now} = as(ctx.app) |> post("/api/anthropic_auths/#{ctx.work.id}/preferred") |> json_response(200)
    assert now == ctx.work.id
    work_id = ctx.work.id
    assert_receive {"pool", %{"change" => "preferred", "by" => by, "current_id" => ^work_id, "preferred_id" => ^work_id}}
    assert by =~ "@"

    # Re-preferring the same account is idempotent.
    as(ctx.app) |> post("/api/anthropic_auths/#{ctx.work.id}/preferred") |> json_response(200)
    assert Enum.map(AnthropicAuths.list_auths(), &{&1.label, &1.priority}) == [{"Work", 10}, {"Personal", 20}, {"Spare", 30}]
  end

  test "current_id differs from the preferred account while that one is cooling", ctx do
    until = DateTime.utc_now() |> DateTime.add(600) |> DateTime.truncate(:second)
    ctx.personal |> Ecto.Changeset.change(cooldown_until: until, status: "cooling_down", cooldown_reason: "x") |> Repo.update!()
    assert %{"current_id" => cur, "auths" => [%{"id" => pref} | _]} = as(ctx.api) |> get("/api/anthropic_auths") |> json_response(200)
    assert pref == ctx.personal.id
    assert cur == ctx.work.id
  end
end
