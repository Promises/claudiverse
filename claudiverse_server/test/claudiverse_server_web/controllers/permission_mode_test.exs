defmodule ClaudiverseServerWeb.PermissionModeTest do
  @moduledoc """
  POST /api/sessions/:id/permission_mode — app token only, a fixed set of
  modes, and the seat's own answer as the response. The test process is the
  seat's sidecar: it sees {:forward_to_sidecar, "remote_set_mode", ...} and
  answers through Room.permission_mode_result/2 as the seat would.
  """
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.Accounts
  alias ClaudiverseServer.Sessions.{Room, Supervisor}

  setup do
    {user, api} = user_with_token()
    app = Accounts.create_user_api_token(user, "app")
    session = session_fixture(user, %{title: "mode-seat"})
    {:ok, _} = Supervisor.start_room(session.id, owner_id: user.id)
    Room.register_sidecar(session.id, self())

    on_exit(fn ->
      Application.delete_env(:claudiverse_server, :mode_reply_ms)
      for {_, pid, _, _} <- DynamicSupervisor.which_children(ClaudiverseServer.Sessions.Supervisor), is_pid(pid),
          do: DynamicSupervisor.terminate_child(ClaudiverseServer.Sessions.Supervisor, pid)
    end)

    %{api: api, app: app, session: session}
  end

  defp set_mode(ctx, token, mode) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> post("/api/sessions/#{ctx.session.id}/permission_mode", %{mode: mode})
  end

  # The request blocks until the seat answers, so it runs beside the "seat".
  defp async_set(ctx, mode), do: Task.async(fn -> set_mode(ctx, ctx.app, mode) end)

  defp seat_request do
    assert_receive {:forward_to_sidecar, "remote_set_mode", %{"request_id" => rid, "mode" => mode}}, 2_000
    {rid, mode}
  end

  test "the shared token is 403 and the seat is never asked", ctx do
    assert set_mode(ctx, ctx.api, "auto") |> json_response(403) == %{"error" => "permission mode is app-only"}
    refute_receive {:forward_to_sidecar, "remote_set_mode", _}, 200
    assert Room.get_status(ctx.session.id).permission_mode == nil
  end

  test "bypassPermissions and dontAsk are 400 even for the app", ctx do
    for mode <- ["bypassPermissions", "dontAsk", "manual", nil] do
      assert set_mode(ctx, ctx.app, mode) |> json_response(400)
    end

    refute_receive {:forward_to_sidecar, "remote_set_mode", _}, 200
  end

  test "an applied mode is returned and shows in the session's live status", ctx do
    t = async_set(ctx, "acceptEdits")
    {rid, "acceptEdits"} = seat_request()
    Room.permission_mode_result(ctx.session.id, %{"request_id" => rid, "ok" => true, "mode" => "acceptEdits"})

    assert Task.await(t) |> json_response(200) == %{"status" => "applied", "mode" => "acceptEdits"}

    show = build_conn() |> put_req_header("authorization", "Bearer " <> ctx.api) |> get("/api/sessions/#{ctx.session.id}")
    assert json_response(show, 200)["live"]["permission_mode"] == "acceptEdits"
  end

  test "a seat that refuses (auto not available there) is 409 and the mode is unchanged", ctx do
    Room.report_permission_mode(ctx.session.id, "default")
    t = async_set(ctx, "auto")
    {rid, "auto"} = seat_request()
    Room.permission_mode_result(ctx.session.id, %{"request_id" => rid, "ok" => false,
      "error" => "auto mode not available on this seat", "code" => "auto_mode_unavailable"})

    assert %{"status" => "refused", "code" => "auto_mode_unavailable"} = Task.await(t) |> json_response(409)
    assert Room.get_status(ctx.session.id).permission_mode == "default"
  end

  test "a seat that never answers is 504, not applied", ctx do
    Application.put_env(:claudiverse_server, :mode_reply_ms, 200)
    t = async_set(ctx, "plan")
    _ = seat_request()
    assert Task.await(t) |> json_response(504) == %{"error" => "seat did not answer"}
  end

  test "the seat's own reports (e.g. local Shift+Tab) update the live mode", ctx do
    Room.report_permission_mode(ctx.session.id, "plan")
    assert Room.get_status(ctx.session.id).permission_mode == "plan"
  end
end
