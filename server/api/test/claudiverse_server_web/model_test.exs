defmodule ClaudiverseServerWeb.ModelTest do
  use ClaudiverseServerWeb.ConnCase, async: true

  import ClaudiverseServer.Fixtures

  setup do
    {_user, api} = user_with_token()
    %{api: api}
  end

  test "the models, exactly as Claude Code takes them: 5 and 5.5 apart, 1M as it is", ctx do
    body = build_conn() |> put_req_header("authorization", "Bearer " <> ctx.api) |> get("/api/models") |> json_response(200)
    by_id = Map.new(body["models"], &{&1["id"], &1})

    assert %{"label" => "Opus 5.5", "family" => "opus", "one_m" => true, "accepts_1m_suffix" => false, "since" => nil, "older" => false} =
             by_id["claude-opus-5-5"]
    assert %{"label" => "Opus 5"} = by_id["claude-opus-5"]
    # Haiku 5.5: 1M as it is; Claude Code knows it from 2.1.293 (its changelog; 2.1.292 does not).
    assert %{"label" => "Haiku 5.5", "one_m" => true, "since" => "2.1.293"} = by_id["claude-haiku-5-5"]
    # [1m] gives Sonnet 4.6 its 1M window; Haiku 4.5 carries the suffix flag, but Claude Code ignores it.
    assert %{"one_m" => false, "accepts_1m_suffix" => true, "older" => true} = by_id["claude-sonnet-4-6"]
    assert %{"one_m" => false, "accepts_1m_suffix" => false} = by_id["claude-haiku-4-5"]
    # Ids are exact: no suffix, no dotted version (the web once sent claude-fable-5.1[1m]).
    assert Enum.filter(Map.keys(by_id), &String.contains?(&1, ["[", "."])) == []
    assert Enum.map(body["aliases"], & &1["id"]) == ~w(default opus sonnet haiku opusplan)
  end

  test "needs a token" do
    assert build_conn() |> get("/api/models") |> response(401)
  end
end
