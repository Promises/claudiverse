defmodule ClaudiverseServer.Notifications.RouterAckTest do
  @moduledoc """
  cv_ack clears only what the listener was shown. MEASURED 2026-10-12: seat
  ipsum-w6-t31607 handled a delivered ping, a reply was queued for it 4 s
  before it called cv_ack with no arguments, and that ack erased the reply's
  ping: the seat idled ~30 min waiting for the GO in it.
  """
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.Notifications.Router

  setup do
    {_user, api} = user_with_token()
    title = "ack-#{System.unique_integer([:positive])}"
    # A listener busy with the ping it was just delivered: its queue emptied by
    # that delivery, not idle, watching "src".
    :sys.replace_state(Router, fn st ->
      put_in(st, [:listeners, title], %{session_id: nil, watch: MapSet.new(["src", "other"]), queue: [], idle: false})
    end)

    on_exit(fn -> :sys.replace_state(Router, fn st -> update_in(st, [:listeners], &Map.delete(&1, title)) end) end)
    %{api: api, title: title}
  end

  defp ack(ctx, body),
    do: build_conn() |> put_req_header("authorization", "Bearer " <> ctx.api) |> post("/api/notify/ack", Map.put(body, "self", ctx.title)) |> json_response(200)

  defp pending(ctx),
    do: build_conn() |> put_req_header("authorization", "Bearer " <> ctx.api) |> get("/api/notify/pending?self=#{ctx.title}") |> json_response(200)

  # A cast; a call behind it makes sure it has been handled.
  defp queue_report(from, text) do
    Router.report(from, text)
    :sys.get_state(Router)
  end

  test "a ping queued after the delivery survives a cv_ack with no arguments, and is delivered next", ctx do
    queue_report("src", "B: GO")

    assert %{"cleared" => 0, "kept" => 1} = ack(ctx, %{})
    assert [%{kind: "report", text: "B: GO"}] = Router.peek(ctx.title)

    assert %{"cleared" => 0, "kept" => 1} = ack(ctx, %{"target" => "src"})
    assert [%{text: "B: GO"}] = Router.peek(ctx.title)
  end

  test "what cv_pending listed is shown, so cv_ack clears it; a ping queued after the listing stays", ctx do
    queue_report("src", "A")
    assert %{"queue" => [%{"text" => "A"}]} = pending(ctx)
    queue_report("other", "B")

    assert %{"cleared" => 1, "kept" => 1} = ack(ctx, %{})
    assert [%{title: "other", text: "B"}] = Router.peek(ctx.title)
  end

  test "a forum ping updated after it was listed is not what was shown, and stays", ctx do
    Router.forum_post(%{channel: "c", post_id: 1, author: "x"}, [ctx.title])
    :sys.get_state(Router)
    pending(ctx)
    Router.forum_post(%{channel: "c", post_id: 2, author: "x"}, [ctx.title])
    :sys.get_state(Router)

    assert %{"cleared" => 0} = ack(ctx, %{})
    assert [%{kind: "forum", post_id: 2, count: 2}] = Router.peek(ctx.title)
  end

  test "cv_send / cv_answer acting on a title clear its queued pings, shown or not; others stay", ctx do
    queue_report("src", "question")
    queue_report("other", "B")

    assert %{"cleared" => 1, "kept" => 1} = ack(ctx, %{"target" => "src", "acted" => true})
    assert [%{title: "other"}] = Router.peek(ctx.title)

    # "acted" names a title; with none it is a plain cv_ack.
    assert %{"cleared" => 0, "kept" => 1} = ack(ctx, %{"acted" => true})
  end
end
