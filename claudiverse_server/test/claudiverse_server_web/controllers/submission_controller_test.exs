defmodule ClaudiverseServerWeb.SubmissionControllerTest do
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures

  setup do
    {_user, token} = user_with_token()
    %{token: token}
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp submit(token, over \\ %{}) do
    body =
      Map.merge(
        %{
          "address" => "0x00336B88",
          "build" => "usa_v200",
          "unit" => "text/336000",
          "tier" => "T1",
          "base_sha" => "abc123def456",
          "body_c" => "void F(void) {}",
          "submitted_by" => "lorem-w1"
        },
        over
      )

    build_conn() |> auth(token) |> post("/api/kb/submissions", body)
  end

  test "a worker submits with no branch and no push access", %{token: token} do
    body = submit(token) |> json_response(200)

    assert body["ok"]
    assert body["durable"], "the response must state that durability has ALREADY arrived"
    assert body["submission"]["state"] == "SUBMITTED"
    # normalised: one function, one identity, however it was spelled
    assert body["submission"]["address"] == "00336b88"
    assert body["submission"]["body_hash"]
  end

  test "integrating at a sha the gate did not run against is 409, not 422", %{token: token} do
    id = submit(token, %{"base_sha" => "old111"}) |> json_response(200) |> get_in(["submission", "id"])

    build_conn()
    |> auth(token)
    |> post("/api/kb/submissions/#{id}/gates", %{
      "gate_name" => "objdiff_unit",
      "verdict" => "PASS",
      "raw_output" => "100.00%",
      "positive_control_output" => "seeded change -> 99.6%, gate failed as expected"
    })
    |> json_response(200)

    # ⭐ 409 CONFLICT, not 422. The submission is well-formed; the WORLD moved.
    # That distinction tells a client to re-gate rather than to fix its payload.
    body =
      build_conn()
      |> auth(token)
      |> post("/api/kb/submissions/#{id}/integrate", %{"sha" => "new222", "by" => "integrator"})
      |> json_response(409)

    assert body["error"] =~ "re-gate at HEAD"
  end

  test "blind-gates surfaces a gate that could not have failed", %{token: token} do
    id = submit(token) |> json_response(200) |> get_in(["submission", "id"])

    build_conn()
    |> auth(token)
    |> post("/api/kb/submissions/#{id}/gates", %{
      "gate_name" => "objdiff_unit",
      "verdict" => "PASS",
      "raw_output" => "100.00%"
    })
    |> json_response(200)

    body = build_conn() |> auth(token) |> get("/api/kb/submissions/blind-gates") |> json_response(200)

    assert body["count"] == 1
    assert hd(body["gates"])["could_have_failed"] == false
  end

  test "a PASS without raw_output is refused at the API too", %{token: token} do
    id = submit(token) |> json_response(200) |> get_in(["submission", "id"])

    body =
      build_conn()
      |> auth(token)
      |> post("/api/kb/submissions/#{id}/gates", %{"gate_name" => "g", "verdict" => "PASS"})
      |> json_response(422)

    refute body["ok"]
    assert body["errors"]["raw_output"]
  end
end
