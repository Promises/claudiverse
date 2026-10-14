defmodule ClaudiverseServerWeb.NotifyDirectTest do
  @moduledoc "POST /api/notify/direct: one seat, by title, pinged whether it watches anything or not; only the caller's own."
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.Notifications.Router

  setup do
    {user, api} = user_with_token()
    %{user: user, api: api}
  end

  defp direct(api, body), do: build_conn() |> put_req_header("authorization", "Bearer " <> api) |> post("/api/notify/direct", body)

  test "the seat that wrote a task hears its runner's escalation, though it watches nothing", ctx do
    session_fixture(ctx.user, %{title: "task-author", status: :stopped})
    text = "RUNNER wc3-real needs a human — task #2166: 30m with NO CPU — cv_task_show 2166"
    assert %{"ok" => true} = direct(ctx.api, %{self: "wc3-real", to: "task-author", text: text}) |> json_response(200)
    # Held for a seat not running now: delivered when it is next seen.
    assert [%{kind: "direct", title: "wc3-real", text: ^text}] = Router.peek("task-author")
  end

  test "another user's seat is not pinged; the fields are required", ctx do
    {other, _} = user_with_token(%{email: "other@example.com"})
    session_fixture(other, %{title: "their-seat"})
    assert %{"error" => "no seat titled their-seat"} = direct(ctx.api, %{self: "x", to: "their-seat", text: "hi"}) |> json_response(404)
    assert Router.peek("their-seat") == []
    assert direct(ctx.api, %{self: "x", to: "", text: "hi"}) |> json_response(400)
  end
end
