defmodule ClaudiverseServerWeb.TaskControllerTest do
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures

  setup do
    {_u, token} = user_with_token()
    %{token: token}
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp create(token, over \\ %{}) do
    body =
      Map.merge(
        %{"fleet" => "lorem-fleet", "lane" => "lorem-tasks", "title" => "match 0x336B88", "created_by" => "orch"},
        over
      )

    build_conn() |> auth(token) |> post("/api/tasks", body) |> json_response(200)
  end


  test "a claimed task carries its BODY, not just a title", %{conn: conn, token: token} do
    # ⛔ REGRESSION. task_json omitted :body_md, and cv-runner builds the worker
    # prompt from `t.body_md || ""`. Every worker therefore received its TITLE
    # and three blank lines. MEASURED 2026-09-11 on the live worker running #16:
    # zero occurrences of its addresses, its governing procedure, or its
    # acceptance criteria. Nothing errored — a worker handed only a title
    # improvises something plausible, and plausible-but-ungoverned output is
    # indistinguishable from real work until checked against a rule it never saw.
    body = "THE ACTUAL INSTRUCTIONS — without these the worker improvises"

    created =
      conn
      |> auth(token)
      |> post("/api/tasks", %{
        fleet: "t-fleet",
        lane: "t-lane",
        title: "a task with a body",
        body_md: body,
        created_by: "t"
      })
      |> json_response(200)

    id = created["task"]["id"]
    build_conn() |> auth(token) |> post("/api/tasks/#{id}/ready", %{actor: "t"}) |> json_response(200)

    shown =
      build_conn() |> auth(token) |> get("/api/tasks/#{id}") |> json_response(200)

    assert shown["task"]["body_md"] == body,
           "the task body is missing from task_json — cv-runner will hand the worker an empty brief"

    claimed =
      build_conn()
      |> auth(token)
      |> post("/api/tasks/claim", %{fleet: "t-fleet", lane: "t-lane", worker: "w1"})
      |> json_response(200)

    assert claimed["task"]["body_md"] == body,
           "the CLAIM response must carry the body — that is the path the runner actually uses"
  end

  test "a task created without ready is DRAFT and unclaimable", %{token: token} do
    body = create(token)
    assert body["task"]["state"] == "DRAFT"

    claim =
      build_conn()
      |> auth(token)
      |> post("/api/tasks/claim", %{"fleet" => "lorem-fleet", "lane" => "lorem-tasks", "worker" => "w1"})
      |> json_response(200)

    # An empty queue is a normal poll result, not an error — a runner must be
    # able to tell "nothing to do" from "the call failed" without parsing an
    # error body.
    assert claim["ok"]
    assert claim["task"] == nil
    assert claim["reason"] == "none_ready"
  end

  test "ready + claim + complete, and the claim is by PRIORITY", %{token: token} do
    _low = create(token, %{"title" => "low", "priority" => 0, "ready" => true})
    high = create(token, %{"title" => "high", "priority" => 9, "ready" => true})

    claim =
      build_conn()
      |> auth(token)
      |> post("/api/tasks/claim", %{"fleet" => "lorem-fleet", "lane" => "lorem-tasks", "worker" => "w1"})
      |> json_response(200)

    assert claim["task"]["id"] == high["task"]["id"]
  end

  test "claim honours exclude over the wire, and drops malformed ids", %{token: token} do
    # The runner sends JSON integers; a malformed entry must not coerce to some
    # other id or fail the whole claim.
    high = create(token, %{"title" => "declined", "priority" => 9, "ready" => true})
    low = create(token, %{"title" => "next", "priority" => 0, "ready" => true})

    claim =
      build_conn()
      |> auth(token)
      |> post("/api/tasks/claim", %{
        "fleet" => "lorem-fleet",
        "lane" => "lorem-tasks",
        "worker" => "w1",
        "exclude" => [high["task"]["id"], "not-an-id"]
      })
      |> json_response(200)

    assert claim["task"]["id"] == low["task"]["id"]
  end

  test "a BLOCKS dep makes ready a 409 naming the blockers", %{token: token} do
    blocker = create(token, %{"title" => "land the revert"})
    dep = create(token, %{"title" => "resume"})

    build_conn()
    |> auth(token)
    |> post("/api/tasks/#{dep["task"]["id"]}/deps", %{"depends_on" => blocker["task"]["id"], "actor" => "orch"})
    |> json_response(200)

    # 409, not 422: the task is well-formed, the WORLD is not ready for it.
    body =
      build_conn()
      |> auth(token)
      |> post("/api/tasks/#{dep["task"]["id"]}/ready", %{"actor" => "orch"})
      |> json_response(409)

    assert body["blocked_by"] == [blocker["task"]["id"]]
  end

  test "completing a different task than held reports the strand", %{token: token} do
    held = create(token, %{"title" => "#22557", "ready" => true, "priority" => 5})
    other = create(token, %{"title" => "#22445", "ready" => true, "priority" => 1})

    build_conn()
    |> auth(token)
    |> post("/api/tasks/claim", %{"fleet" => "lorem-fleet", "lane" => "lorem-tasks", "worker" => "w2"})
    |> json_response(200)

    body =
      build_conn()
      |> auth(token)
      |> post("/api/tasks/#{other["task"]["id"]}/complete", %{
        "worker" => "w2",
        "held_task_id" => held["task"]["id"]
      })
      |> json_response(200)

    assert body["stranded"]["id"] == held["task"]["id"]
    assert body["stranded"]["state"] == "READY"
    assert body["note"] =~ "protocol violation"
    assert body["note"] =~ "slot is free"
  end

  test "health requires liveness as input and reports starvation", %{token: token} do
    create(token, %{"lane" => "lorem-tasks", "ready" => true})

    body =
      build_conn()
      |> auth(token)
      |> post("/api/tasks/health", %{
        "fleet" => "lorem-fleet",
        "live_lanes" => ["lorem-tasks", "lorem-analysis"],
        "live_workers" => []
      })
      |> json_response(200)

    # lorem-tasks has a READY task; lorem-analysis has a live runner and nothing.
    assert body["starved_lanes"] == ["lorem-analysis"]
    assert body["note"] =~ "live_lanes"
  end

  test "publishing or gating a task anonymously is refused at the API", %{token: token} do
    a = create(token, %{"title" => "anon publish"})
    b = create(token, %{"title" => "anon gate"})

    # #18 reached the fleet through exactly this shape: a /ready call carrying
    # no actor, accepted silently, leaving an event log that could say what
    # happened but never who to ask.
    build_conn()
    |> auth(token)
    |> post("/api/tasks/#{a["task"]["id"]}/ready", %{})
    |> json_response(422)

    build_conn()
    |> auth(token)
    |> post("/api/tasks/#{b["task"]["id"]}/deps", %{"depends_on" => a["task"]["id"]})
    |> json_response(422)

    still =
      build_conn()
      |> auth(token)
      |> get("/api/tasks/#{a["task"]["id"]}")
      |> json_response(200)

    assert still["task"]["state"] == "DRAFT"
  end

end
