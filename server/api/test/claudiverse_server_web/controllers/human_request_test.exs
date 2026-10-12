defmodule ClaudiverseServerWeb.HumanRequestTest do
  @moduledoc """
  Seat placement (host/fleet/origin) and human requests: a seat asks for the
  operator, the app lists and resolves, the operator channel carries it live.
  """
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures
  import Ecto.Query
  import Phoenix.ChannelTest, except: [connect: 2, connect: 3]

  @endpoint ClaudiverseServerWeb.Endpoint

  alias ClaudiverseServer.{Accounts, Repo}
  alias ClaudiverseServer.HumanRequests.HumanRequest

  setup do
    {user, api} = user_with_token()
    app = Accounts.create_user_api_token(user, "app")
    %{user: user, api: api, app: app}
  end

  defp as(token), do: build_conn() |> put_req_header("authorization", "Bearer " <> token)

  # Opted in (can_notify) unless said otherwise: most tests are about what an
  # allowed seat can do.
  defp seat(ctx, title, origin, can_notify \\ true) do
    session_fixture(ctx.user, %{title: title, origin: origin, can_notify: can_notify})
  end

  defp ask(ctx, title, summary \\ "need you", detail \\ nil) do
    as(ctx.api) |> post("/api/human_requests", %{self: title, summary: summary, detail: detail})
  end

  defp open_rows(session_id) do
    Repo.aggregate(from(r in HumanRequest, where: r.session_id == ^session_id and r.status == "open"), :count)
  end

  # --- placement ---------------------------------------------------------------

  test "a seat's host, fleet and origin are stored and returned; a re-POST without them keeps them", ctx do
    body = %{title: "xps-w", claude_session_id: "cs-1", host: "xps", fleet: "lorem-fleet", origin: "runner"}
    as(ctx.api) |> post("/api/sessions", body) |> json_response(201)
    as(ctx.api) |> post("/api/sessions", %{title: "xps-w", claude_session_id: "cs-1"}) |> json_response(201)

    [s] = as(ctx.api) |> get("/api/sessions?title=xps-w") |> json_response(200) |> Map.fetch!("sessions")
    assert {s["host"], s["fleet"], s["origin"]} == {"xps", "lorem-fleet", "runner"}
  end

  test "working directory, Claude session id and client version are returned; a re-POST without them keeps them", ctx do
    body = %{title: "info-seat", claude_session_id: "cs-9", working_directory: "/w/ipsum-api",
             client_version: "2.1.286 (Claude Code) [claudiverse]"}
    as(ctx.api) |> post("/api/sessions", body) |> json_response(201)
    # The rename path re-POSTs with just the title: it used to wipe working_directory.
    as(ctx.api) |> post("/api/sessions", %{title: "info-seat", claude_session_id: "cs-9"}) |> json_response(201)

    [s] = as(ctx.api) |> get("/api/sessions?title=info-seat") |> json_response(200) |> Map.fetch!("sessions")
    assert {s["working_directory"], s["claude_session_id"], s["client_version"]} ==
             {"/w/ipsum-api", "cs-9", "2.1.286 (Claude Code) [claudiverse]"}
  end

  test "the single-seat endpoint reports the same last_activity_at as the list", ctx do
    s = session_fixture(ctx.user, %{title: "active-seat"})
    {:ok, m} = ClaudiverseServer.Sessions.create_message(%{type: "assistant", payload: %{}, sequence: 1, session_id: s.id})
    later = NaiveDateTime.add(s.inserted_at, 3600) |> NaiveDateTime.truncate(:second)
    Repo.update_all(from(x in ClaudiverseServer.Sessions.Message, where: x.id == ^m.id), set: [inserted_at: later])

    detail = as(ctx.api) |> get("/api/sessions/#{s.id}") |> json_response(200) |> Map.fetch!("session")
    [listed] = as(ctx.api) |> get("/api/sessions?title=active-seat") |> json_response(200) |> Map.fetch!("sessions")

    assert detail["last_activity_at"] == listed["last_activity_at"]
    assert detail["last_activity_at"] == NaiveDateTime.to_iso8601(later)
  end

  test "an unknown origin is refused", ctx do
    r = as(ctx.api) |> post("/api/sessions", %{title: "x", origin: "martian"})
    assert json_response(r, 422)
  end

  # --- requests ----------------------------------------------------------------

  test "a seat asks; asking again updates the same open request (one row)", ctx do
    s = seat(ctx, "helper", "manual")
    %{"id" => id, "status" => "open"} = ask(ctx, "helper", "first") |> json_response(200)
    %{"id" => ^id} = ask(ctx, "helper", "second", "more") |> json_response(200)

    assert open_rows(s.id) == 1
    [req] = as(ctx.app) |> get("/api/human_requests?status=open") |> json_response(200) |> Map.fetch!("requests")
    assert req["summary"] == "second" and req["detail"] == "more" and req["seat_title"] == "helper"
  end

  test "an opted-in seat with no origin (older runtime) may ask", ctx do
    seat(ctx, "legacy", nil)
    assert %{"status" => "open"} = ask(ctx, "legacy") |> json_response(200)
  end

  test "a seat that did not opt in is refused with 403 and nothing is stored", ctx do
    s = seat(ctx, "ipsum-orchestrator", "manual", false)
    assert %{"error" => "this seat may not request a human" <> _} = ask(ctx, "ipsum-orchestrator") |> json_response(403)
    assert Repo.aggregate(from(r in HumanRequest, where: r.session_id == ^s.id), :count) == 0
  end

  test "a runner is refused even if it opted in", ctx do
    seat(ctx, "lorem-w9-t1", "runner", true)
    assert ask(ctx, "lorem-w9-t1") |> json_response(403) == %{"error" => "runner seats cannot request a human"}
  end

  test "the opt-in is set by the seat's registration, and a relaunch without it loses it", ctx do
    as(ctx.api) |> post("/api/sessions", %{title: "ipsum-admin", claude_session_id: "c1", notify: "1"}) |> json_response(201)
    as(ctx.api) |> post("/api/sessions", %{title: "ipsum-admin", claude_session_id: "c1"}) |> json_response(201)
    [s] = as(ctx.api) |> get("/api/sessions?title=ipsum-admin") |> json_response(200) |> Map.fetch!("sessions")
    assert s["can_notify"] == true, "absent = no news"

    as(ctx.api) |> post("/api/sessions", %{title: "ipsum-admin", claude_session_id: "c1", notify: "0"}) |> json_response(201)
    [s] = as(ctx.api) |> get("/api/sessions?title=ipsum-admin") |> json_response(200) |> Map.fetch!("sessions")
    assert s["can_notify"] == false
  end

  test "a runner seat is refused with 403 and nothing is stored", ctx do
    s = seat(ctx, "lorem-w5-t1", "runner")
    assert ask(ctx, "lorem-w5-t1") |> json_response(403) == %{"error" => "runner seats cannot request a human"}
    assert Repo.aggregate(from(r in HumanRequest, where: r.session_id == ^s.id), :count) == 0
  end

  test "resolve is app-only: the shared token gets 403 and the request stays open", ctx do
    s = seat(ctx, "helper", "manual")
    ask(ctx, "helper") |> json_response(200)

    assert as(ctx.api) |> post("/api/sessions/#{s.id}/human_requests/resolve") |> json_response(403)
    assert open_rows(s.id) == 1

    assert %{"resolved" => 1} = as(ctx.app) |> post("/api/sessions/#{s.id}/human_requests/resolve") |> json_response(200)
    assert open_rows(s.id) == 0
    assert as(ctx.app) |> get("/api/human_requests?status=open") |> json_response(200) == %{"requests" => []}
  end

  test "a seat with no running session is 404; no summary is 400", ctx do
    assert ask(ctx, "nobody") |> json_response(404)
    seat(ctx, "helper", "manual")
    assert as(ctx.api) |> post("/api/human_requests", %{self: "helper"}) |> json_response(400)
  end

  # --- live channel --------------------------------------------------------------

  test "the operator channel pushes new, updated and resolved requests", ctx do
    {:ok, socket} = Phoenix.ChannelTest.connect(ClaudiverseServerWeb.UserSocket, %{"token" => ctx.app})
    {:ok, _, _} = subscribe_and_join(socket, ClaudiverseServerWeb.OperatorChannel, "operator:human_requests")

    s = seat(ctx, "helper", "manual")
    ask(ctx, "helper", "first") |> json_response(200)
    assert_push "human_request", %{"summary" => "first", "seat_title" => "helper", "session_id" => sid}
    assert sid == s.id

    ask(ctx, "helper", "again") |> json_response(200)
    assert_push "human_request", %{"summary" => "again"}

    as(ctx.app) |> post("/api/sessions/#{s.id}/human_requests/resolve") |> json_response(200)
    assert_push "human_request_resolved", %{"session_id" => ^sid}
  end
end
