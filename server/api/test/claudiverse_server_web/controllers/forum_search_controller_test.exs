defmodule ClaudiverseServerWeb.ForumSearchControllerTest do
  @moduledoc """
  A forum search must not be able to wedge the server.

  MEASURED 2026-09-28: one search ran 253 s in production and every other request
  queued behind its DB connection. Cost grows faster than linearly with the
  number of OR'd prefix terms (10 → 0.05 s … 300 → 9.1 s on a copy of the live
  forum), so a pasted paragraph is enough. The cap refuses such a query with an
  explicit error instead of truncating it into an answer to a different question.
  """
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.Forum

  setup do
    {_u, token} = user_with_token()
    {:ok, _} = Forum.create_channel(%{slug: "srch", title: "Search"})
    {:ok, _} = Forum.create_post(%{channel: "srch", author: "t", body: "term0 appears here with func_002933D0"})
    %{token: token}
  end

  defp search(token, q),
    do: build_conn() |> put_req_header("authorization", "Bearer #{token}") |> get("/api/forum/search", %{q: q})

  defp words(n), do: Enum.map_join(0..(n - 1), " ", &"term#{&1}")

  test "a query over the term cap is refused with the count and the cap", %{token: token} do
    max = Forum.max_search_terms()
    body = search(token, words(max + 1)) |> json_response(400)

    assert body["terms"] == max + 1
    assert body["max_terms"] == max
    assert body["error"] =~ "distinct terms"
  end

  test "a query AT the cap still searches, so the cap is not an off-by-one", %{token: token} do
    body = search(token, words(Forum.max_search_terms())) |> json_response(200)
    assert Enum.any?(body["results"], &(&1["snippet"] =~ "term0"))
  end

  test "repeated words count once, case-insensitively", %{token: token} do
    many = String.duplicate("term0 TERM0 ", Forum.max_search_terms() * 3)
    assert length(Forum.search_terms(many)) == 1
    body = search(token, many) |> json_response(200)
    assert length(body["results"]) == 1
  end

  test "an ordinary identifier search is unaffected", %{token: token} do
    body = search(token, "func_002933D0") |> json_response(200)
    assert length(body["results"]) == 1
  end
end
