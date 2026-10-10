defmodule ClaudiverseServerWeb.SeatAccessTest do
  @moduledoc """
  Seat access levels (Sessions.Access): set from the apps, read by cv-mcp via
  whoami, enforced for paging by HumanRequests. Without a level, every seat
  that existed before derives exactly as it did; only a PLAIN session (origin
  "plain") defaults to basic.
  """
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.{Accounts, HumanRequests, Repo}

  setup do
    {user, api} = user_with_token()
    app = Accounts.create_user_api_token(user, "app")
    %{user: user, api: api, app: app}
  end

  defp as(token), do: build_conn() |> put_req_header("authorization", "Bearer " <> token)
  defp whoami(ctx, id), do: as(ctx.api) |> get("/api/seats/whoami?claude_session_id=#{id}") |> json_response(200)

  test "without a level, existing seats derive as before; a plain session is basic", ctx do
    session_fixture(ctx.user, %{title: "orch", claude_session_id: "c-orch", origin: "manual", can_notify: true})
    session_fixture(ctx.user, %{title: "nul", claude_session_id: "c-nul"})
    session_fixture(ctx.user, %{title: "w", claude_session_id: "c-w", origin: "runner"})
    session_fixture(ctx.user, %{title: "p", claude_session_id: "c-p", origin: "plain"})

    assert %{"role" => "orchestrator", "can_notify" => true, "access" => "full"} = whoami(ctx, "c-orch")
    assert %{"role" => "orchestrator", "can_notify" => false} = whoami(ctx, "c-nul")
    assert %{"role" => "worker", "access" => "basic"} = whoami(ctx, "c-w")
    assert %{"role" => "worker", "can_notify" => false, "access" => "basic"} = whoami(ctx, "c-p")
  end

  test "the app sets a level; whoami and paging follow it; null returns to the default", ctx do
    s = session_fixture(ctx.user, %{title: "p", claude_session_id: "c-p", origin: "plain"})
    path = "/api/sessions/#{s.id}/access"

    # A plain session does not page until the operator switches it on.
    assert {:error, :not_allowed} = HumanRequests.request(Repo.reload!(s), "help", nil)

    # The first API's "notify" level still works: basic tools with paging on.
    assert %{"session" => %{"access" => "basic", "access_explicit" => true, "can_notify" => true}} =
             as(ctx.app) |> post(path, %{level: "notify"}) |> json_response(200)
    assert %{"role" => "worker", "can_notify" => true} = whoami(ctx, "c-p")
    assert {:ok, _} = HumanRequests.request(Repo.reload!(s), "help", nil)

    # The tool level never changes paging: a plain session keeps its default (off).
    as(ctx.app) |> post(path, %{level: "full"}) |> json_response(200)
    assert %{"role" => "orchestrator", "can_notify" => false, "access" => "full"} = whoami(ctx, "c-p")

    as(ctx.app) |> post(path, %{level: nil}) |> json_response(200)
    assert %{"role" => "worker", "can_notify" => false, "access" => "basic"} = whoami(ctx, "c-p")
  end

  test "tools and paging are independent: Basic keeps paging, Full does not add it", ctx do
    s = session_fixture(ctx.user, %{title: "orch", claude_session_id: "c-o", origin: "manual", can_notify: true})
    as(ctx.app) |> post("/api/sessions/#{s.id}/access", %{level: "basic"}) |> json_response(200)
    assert %{"role" => "worker", "can_notify" => true} = whoami(ctx, "c-o")
    assert {:ok, _} = HumanRequests.request(Repo.reload!(s), "help", nil)

    q = session_fixture(ctx.user, %{title: "q", claude_session_id: "c-q", origin: "manual", can_notify: false})
    as(ctx.app) |> post("/api/sessions/#{q.id}/access", %{level: "full"}) |> json_response(200)
    assert %{"role" => "orchestrator", "can_notify" => false} = whoami(ctx, "c-q")
  end

  test "only the app sets a level; bad levels, unknown and other users' seats are refused", ctx do
    s = session_fixture(ctx.user, %{title: "p", origin: "plain"})
    assert as(ctx.api) |> post("/api/sessions/#{s.id}/access", %{level: "full"}) |> json_response(403)
    assert as(ctx.app) |> post("/api/sessions/#{s.id}/access", %{level: "root"}) |> json_response(400)
    assert as(ctx.app) |> post("/api/sessions/999999/access", %{level: "full"}) |> json_response(404)

    {other, _} = user_with_token(%{email: "other@test.com"})
    theirs = session_fixture(other, %{title: "t"})
    assert as(ctx.app) |> post("/api/sessions/#{theirs.id}/access", %{level: "full"}) |> json_response(404)
    assert Repo.reload!(s).access == nil
  end

  test "a runner's worker never pages, whatever its level", ctx do
    s = session_fixture(ctx.user, %{title: "w", origin: "runner"})
    as(ctx.app) |> post("/api/sessions/#{s.id}/access", %{level: "full"}) |> json_response(200)
    assert {:error, :runner} = HumanRequests.request(Repo.reload!(s), "help", nil)
  end

  describe "the paging switch" do
    test "on, off and clear, independent of the tool level", ctx do
      s = session_fixture(ctx.user, %{title: "p", claude_session_id: "c-p", origin: "plain"})
      path = "/api/sessions/#{s.id}/notify"

      assert %{"session" => %{"can_notify" => true, "notify_grant" => true, "notify_until" => nil, "access" => "basic"}} =
               as(ctx.app) |> post(path, %{allow: true}) |> json_response(200)
      assert %{"role" => "worker", "can_notify" => true} = whoami(ctx, "c-p")
      assert {:ok, _} = HumanRequests.request(Repo.reload!(s), "help", nil)

      # Off overrides a seat whose own flag says it may page.
      o = session_fixture(ctx.user, %{title: "o", claude_session_id: "c-o", origin: "manual", can_notify: true})
      as(ctx.app) |> post("/api/sessions/#{o.id}/notify", %{allow: false}) |> json_response(200)
      assert %{"role" => "orchestrator", "can_notify" => false} = whoami(ctx, "c-o")

      as(ctx.app) |> post("/api/sessions/#{o.id}/notify", %{allow: nil}) |> json_response(200)
      assert %{"can_notify" => true} = whoami(ctx, "c-o")
    end

    test "a timed switch lapses back to the default", ctx do
      s = session_fixture(ctx.user, %{title: "p", claude_session_id: "c-p", origin: "plain"})
      # Paging on for two hours on a plain session (off by default).
      %{"session" => %{"notify_until" => until, "can_notify" => true}} =
        as(ctx.app) |> post("/api/sessions/#{s.id}/notify", %{allow: true, minutes: 120}) |> json_response(200)
      {:ok, u, _} = DateTime.from_iso8601(until)
      assert_in_delta DateTime.diff(u, DateTime.utc_now()), 7200, 5

      # Lapsed: in the past, the derived value (plain: no paging) applies again.
      Repo.reload!(s) |> Ecto.Changeset.change(notify_until: DateTime.utc_now() |> DateTime.add(-1) |> DateTime.truncate(:second)) |> Repo.update!()
      assert %{"can_notify" => false} = whoami(ctx, "c-p")
      assert %{"session" => %{"notify_grant" => nil, "notify_until" => nil}} =
               as(ctx.api) |> get("/api/sessions/#{s.id}") |> json_response(200)
    end

    test "app-only; bad values refused", ctx do
      s = session_fixture(ctx.user, %{title: "p", origin: "plain"})
      assert as(ctx.api) |> post("/api/sessions/#{s.id}/notify", %{allow: true}) |> json_response(403)
      assert as(ctx.app) |> post("/api/sessions/#{s.id}/notify", %{allow: "yes"}) |> json_response(400)
      assert as(ctx.app) |> post("/api/sessions/#{s.id}/notify", %{allow: true, minutes: 0}) |> json_response(400)
      assert Repo.reload!(s).notify_grant == nil
    end
  end
end
