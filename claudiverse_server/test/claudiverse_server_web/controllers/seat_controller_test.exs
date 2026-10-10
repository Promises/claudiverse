defmodule ClaudiverseServerWeb.SeatControllerTest do
  @moduledoc "GET /api/seats/whoami: a global MCP config learns its seat and its tool policy."
  use ClaudiverseServerWeb.ConnCase, async: true

  import ClaudiverseServer.Fixtures

  setup do
    {user, api} = user_with_token()
    %{user: user, api: api}
  end

  defp whoami(ctx, q), do: build_conn() |> put_req_header("authorization", "Bearer " <> ctx.api) |> get("/api/seats/whoami?" <> q)

  test "by Claude session id: the seat, and orchestrator policy for a manual seat with notify", ctx do
    s = session_fixture(ctx.user, %{title: "ipsum-admin", claude_session_id: "cs-1", origin: "manual", fleet: "ipsum-fleet", can_notify: true})
    assert whoami(ctx, "claude_session_id=cs-1") |> json_response(200) ==
             %{"session_id" => s.id, "title" => "ipsum-admin", "role" => "orchestrator", "can_notify" => true, "fleet" => "ipsum-fleet", "origin" => "manual",
               "profile_id" => nil, "access" => "full"}
  end

  test "a runner's worker gets the worker policy; by title works too", ctx do
    session_fixture(ctx.user, %{title: "ipsum-w4-t1", claude_session_id: "cs-2", origin: "runner"})
    assert %{"role" => "worker", "can_notify" => false} = whoami(ctx, "title=ipsum-w4-t1") |> json_response(200)
  end

  test "not registered yet is 404 (the caller retries); no key is 400; another user's seat is not found", ctx do
    {other, _} = user_with_token(%{email: "other@test.com"})
    session_fixture(other, %{title: "theirs", claude_session_id: "cs-9"})
    assert whoami(ctx, "claude_session_id=nope") |> json_response(404)
    assert whoami(ctx, "claude_session_id=cs-9") |> json_response(404)
    assert whoami(ctx, "") |> json_response(400)
  end

  test "a running row answers before a newer stopped row of the same title", ctx do
    live = session_fixture(ctx.user, %{title: "seat-a", claude_session_id: "cs-live", status: :running})
    session_fixture(ctx.user, %{title: "seat-a", claude_session_id: "cs-stale", status: :stopped})
    live_id = live.id
    assert %{"session_id" => ^live_id} = whoami(ctx, "title=seat-a") |> json_response(200)
  end

  test "a proxy row never answers for the seat", ctx do
    session_fixture(ctx.user, %{title: "proxy:x", claude_session_id: "proxy:cs-3", type: :proxy})
    assert whoami(ctx, "claude_session_id=proxy:cs-3") |> json_response(404)
  end
end
