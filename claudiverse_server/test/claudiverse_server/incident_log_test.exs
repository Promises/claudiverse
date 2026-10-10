defmodule ClaudiverseServer.IncidentLogTest do
  use ClaudiverseServerWeb.ConnCase, async: false

  alias ClaudiverseServer.IncidentLog

  setup do
    path = Path.join(System.tmp_dir!(), "incidents-#{System.unique_integer([:positive])}.jsonl")
    Application.put_env(:claudiverse_server, :incident_log, path)

    on_exit(fn ->
      Application.delete_env(:claudiverse_server, :incident_log)
      File.rm(path)
    end)

    %{path: path}
  end

  defp lines(path), do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  test "a 5xx response is recorded; a 2xx/4xx is not", %{path: path} do
    for status <- [200, 404, 500, 503] do
      conn = %Plug.Conn{Phoenix.ConnTest.build_conn(:post, "/api/forum/handoff/set") | status: status}
      IncidentLog.handle_event([:phoenix, :endpoint, :stop], %{}, %{conn: conn}, nil)
    end

    assert Enum.map(lines(path), & &1["status"]) == [500, 503]
    assert hd(lines(path))["route"] == "/api/forum/handoff/set"
  end

  test "an exception is recorded with its module and message, never request content", %{path: path} do
    conn = Phoenix.ConnTest.build_conn(:post, "/api/forum/handoff/set", %{"body" => "SECRET-PARAM"})
    err = %RuntimeError{message: "Database busy"}

    IncidentLog.handle_event([:phoenix, :router_dispatch, :exception], %{},
      %{conn: conn, route: "/api/forum/handoff/set", kind: :error, reason: err, stacktrace: []}, nil)

    [e] = lines(path)
    assert e["kind"] == "exception" and e["exception"] == "RuntimeError" and e["message"] == "Database busy"
    refute File.read!(path) =~ "SECRET-PARAM"
  end

  test "a numeric path segment is collapsed so counts group by route", %{path: path} do
    conn = %Plug.Conn{Phoenix.ConnTest.build_conn(:get, "/api/tasks/714") | status: 500}
    IncidentLog.handle_event([:phoenix, :endpoint, :stop], %{}, %{conn: conn}, nil)
    assert hd(lines(path))["route"] == "/api/tasks/:id"
  end

  test "a broken record never raises out of the handler" do
    Application.put_env(:claudiverse_server, :incident_log, "/nonexistent-dir/x/incidents.jsonl")
    conn = %Plug.Conn{Phoenix.ConnTest.build_conn(:get, "/x") | status: 500}
    assert IncidentLog.handle_event([:phoenix, :endpoint, :stop], %{}, %{conn: conn}, nil) == :ok
  end

  test "GET /api/incidents counts by route and status since a time", %{conn: conn} do
    {_user, token} = ClaudiverseServer.Fixtures.user_with_token()
    for _ <- 1..3, do: IncidentLog.record(%{kind: "response", status: 500, method: "POST", route: "/api/forum/handoff/set"})
    IncidentLog.record(%{kind: "response", status: 502, method: "POST", route: "/proxy"})

    body =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/incidents?since=2000-01-01T00:00:00Z")
      |> json_response(200)

    assert body["total"] == 4
    assert %{"count" => 3, "status" => 500, "route" => "/api/forum/handoff/set"} = hd(body["counts"])

    future = conn |> recycle() |> put_req_header("authorization", "Bearer " <> token)
             |> get("/api/incidents?since=2999-01-01T00:00:00Z") |> json_response(200)
    assert future["total"] == 0
  end

  test "end to end: a real 5xx through the endpoint lands in the file via the attached handler", %{conn: conn, path: path} do
    {_user, token} = ClaudiverseServer.Fixtures.user_with_token()
    prev = Application.get_env(:claudiverse_server, :proxy_upstream)
    Application.put_env(:claudiverse_server, :proxy_upstream, "http://127.0.0.1:1")
    on_exit(fn -> if prev, do: Application.put_env(:claudiverse_server, :proxy_upstream, prev), else: Application.delete_env(:claudiverse_server, :proxy_upstream) end)

    request = fn c -> c |> put_req_header("x-claudiverse-token", token) |> put_req_header("content-type", "application/json") |> post("/proxy/v1/messages", "{}") end

    # Control: with the handler detached the same 502 must leave no trace,
    # or the assertion below could pass without the wiring doing anything.
    :telemetry.detach("claudiverse-incident-log")
    assert request.(conn).status == 502
    refute File.exists?(path)
    IncidentLog.attach()

    assert request.(recycle(conn)).status == 502
    assert [%{"kind" => "response", "status" => 502, "method" => "POST"}] = lines(path)
  end
end
