defmodule ClaudiverseServerWeb.NotifyForceTest do
  @moduledoc """
  `force: true` on POST /api/notify/send delivers into a busy seat, and only
  for an "app" token. A fake sidecar (the test process) is registered on the
  Room, so delivery is observable as {:forward_to_sidecar, ...}.
  """
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.Accounts
  alias ClaudiverseServer.Sessions.{Room, Supervisor}

  setup do
    {user, api} = user_with_token()
    app = Accounts.create_user_api_token(user, "app")
    session = session_fixture(user, %{title: "busy-seat"})
    {:ok, _} = Supervisor.start_room(session.id, owner_id: user.id)
    Room.register_sidecar(session.id, self())

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(ClaudiverseServer.Sessions.Supervisor), is_pid(pid),
          do: DynamicSupervisor.terminate_child(ClaudiverseServer.Sessions.Supervisor, pid)
    end)

    %{api: api, app: app, session: session}
  end

  defp send_as(token, body) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> post("/api/notify/send", body)
  end

  test "the seat starts busy: an unforced send is refused as busy", ctx do
    assert %{"status" => "busy"} = send_as(ctx.api, %{session_id: ctx.session.id, content: "x"}) |> json_response(200)
    refute_receive {:forward_to_sidecar, "remote_input", _}, 200
  end

  test "force with the shared api token is 403 and delivers nothing", ctx do
    for force <- [true, "true"] do
      r = send_as(ctx.api, %{session_id: ctx.session.id, content: "pushed", force: force})
      assert json_response(r, 403) == %{"error" => "force is app-only"}
    end

    refute_receive {:forward_to_sidecar, "remote_input", _}, 300
  end

  test "force with the app token delivers to a busy seat", ctx do
    r = send_as(ctx.app, %{session_id: ctx.session.id, content: "pushed", force: true})
    assert %{"status" => "delivered"} = json_response(r, 200)
    assert_receive {:forward_to_sidecar, "remote_input", %{"content" => "pushed"}}
  end

  test "a mod seat is sent no slash command but /compact; a patched seat is left alone", ctx do
    ClaudiverseServer.Repo.update!(Ecto.Changeset.change(ctx.session, client_version: "2.1.292 (Claude Code) [claudiverse-mod]"))
    r = send_as(ctx.app, %{session_id: ctx.session.id, content: "/model opus", force: true}) |> json_response(200)
    assert %{"status" => "refused", "error" => error} = r
    assert error =~ "/model was not delivered"
    refute_receive {:forward_to_sidecar, "remote_input", _}, 200

    assert %{"status" => "delivered"} = send_as(ctx.app, %{session_id: ctx.session.id, content: "/compact", force: true}) |> json_response(200)
    assert %{"status" => "delivered"} = send_as(ctx.app, %{session_id: ctx.session.id, content: "see a/b /model", force: true}) |> json_response(200)

    ClaudiverseServer.Repo.update!(Ecto.Changeset.change(ctx.session, client_version: "2.1.289 (Claude Code) [claudiverse]"))
    assert %{"status" => "delivered"} = send_as(ctx.app, %{session_id: ctx.session.id, content: "/model opus", force: true}) |> json_response(200)
  end

  test "the app token without force still respects busy", ctx do
    assert %{"status" => "busy"} = send_as(ctx.app, %{session_id: ctx.session.id, content: "x"}) |> json_response(200)
    refute_receive {:forward_to_sidecar, "remote_input", _}, 200
  end

  test "a send to a stopped row is not reported delivered; it names the title's live row", ctx do
    {:ok, old} = ClaudiverseServer.Sessions.update_session(ctx.session, %{status: :stopped})
    live = session_fixture(ctx.session.user_id |> ClaudiverseServer.Accounts.get_user!(), %{title: "busy-seat"})

    for token <- [ctx.api, ctx.app], body <- [%{session_id: old.id, content: "hi"}, %{session_id: old.id, content: "hi", force: true}],
        token == ctx.app or not Map.has_key?(body, :force) do
      assert %{"status" => "stopped", "live_session_id" => live_id} = send_as(token, body) |> json_response(200)
      assert live_id == live.id
    end

    refute_receive {:forward_to_sidecar, "remote_input", _}, 200
  end
end
