defmodule ClaudiverseServerWeb.TaskDonePingTest do
  @moduledoc """
  A task's DONE pings `tasks:<lane>` from the server itself. MEASURED
  2026-10-14: #2167's DONE pinged nobody: the worker's MCP sent the ping only
  with CV_TASK_REPORT=notify in its config, which the wc3 fleet's lacked, and
  its forum copy went to a channel that did not exist.
  """
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.Notifications.Router
  alias ClaudiverseServer.Tasks

  setup do
    {user, api} = user_with_token()
    %{user: user, api: api}
  end

  defp as(api), do: build_conn() |> put_req_header("authorization", "Bearer " <> api)

  test "the lane's watcher hears of the DONE, though it restarted and re-added its watches since", ctx do
    first = session_fixture(ctx.user, %{title: "lane-manager"})
    as(ctx.api) |> post("/api/notify/subscribe", %{self: "lane-manager", watch: ["tasks:wc3-sim", "other"]}) |> json_response(200)

    # The seat restarts: a new session, seen, and its watches added again.
    again = session_fixture(ctx.user, %{title: "lane-manager"})
    Router.seat_seen("lane-manager", again.id)
    assert %{"watch" => watch} =
             as(ctx.api) |> post("/api/notify/subscribe", %{self: "lane-manager", watch: ["tasks:wc3-sim"], mode: "add"}) |> json_response(200)
    assert Enum.sort(watch) == ["other", "tasks:wc3-sim"]
    refute first.id == again.id

    {:ok, t} = Tasks.create(%{fleet: "wc3", lane: "wc3-sim", title: "sim run 4", created_by: "lane-manager", state: "READY"})
    {:ok, _} = Tasks.claim("wc3", "wc3-sim", "wc3-sim")
    {:ok, _} = Tasks.start(t.id, "wc3-sim")

    assert %{"announced" => "tasks:wc3-sim"} =
             as(ctx.api) |> post("/api/tasks/#{t.id}/complete", %{worker: "wc3-sim-t2167", outcome: "39/39 pass\non 70eff7b"}) |> json_response(200)

    assert [%{kind: "report", title: "tasks:wc3-sim", text: text}] = Router.peek("lane-manager")
    assert text == "DONE task ##{t.id} (wc3-sim-t2167): 39/39 pass on 70eff7b — cv_task_show #{t.id}"
  end
end
