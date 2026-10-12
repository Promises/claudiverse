defmodule ClaudiverseServerWeb.NotifySubscribeTest do
  @moduledoc "cv_subscribe: replace (default), add and remove, and the reply naming what was dropped."
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.Notifications.Router

  setup do
    {user, api} = user_with_token()
    title = "sub-#{System.unique_integer([:positive])}"
    session = session_fixture(user, %{title: title})
    on_exit(fn -> Router.unsubscribe(title) end)
    %{api: api, title: title, session: session}
  end

  defp sub(ctx, body),
    do: build_conn() |> put_req_header("authorization", "Bearer " <> ctx.api) |> post("/api/notify/subscribe", Map.put(body, "self", ctx.title)) |> json_response(200)

  test "replace names the previous list and what it dropped; add and remove change it by the titles given", ctx do
    assert %{"watch" => ["a", "tasks:x"], "previous" => [], "dropped" => []} = sub(ctx, %{"watch" => ["a", "tasks:x"]})

    assert %{"watch" => w, "dropped" => []} = sub(ctx, %{"watch" => ["@pool"], "mode" => "add"})
    assert Enum.sort(w) == ["@pool", "a", "tasks:x"]

    assert %{"watch" => w, "dropped" => ["tasks:x"]} = sub(ctx, %{"watch" => ["tasks:x"], "mode" => "remove"})
    assert Enum.sort(w) == ["@pool", "a"]

    assert %{"watch" => ["b"], "dropped" => dropped} = sub(ctx, %{"watch" => ["b"]})
    assert Enum.sort(dropped) == ["@pool", "a"], "a replace says what it dropped"
  end

  test "a re-subscribe keeps pings already queued", ctx do
    sub(ctx, %{"watch" => ["src"]})
    :sys.replace_state(Router, fn st -> update_in(st, [:listeners, ctx.title], &%{&1 | queue: [%{title: "src", kind: "idle", tool_use_id: nil}], session_id: nil}) end)
    sub(ctx, %{"watch" => ["other"], "mode" => "add"})
    assert [%{title: "src"}] = Router.peek(ctx.title)
  end
end
