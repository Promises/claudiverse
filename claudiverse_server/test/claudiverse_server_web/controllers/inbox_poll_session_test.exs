defmodule ClaudiverseServerWeb.InboxPollSessionTest do
  @moduledoc """
  A seat's inbox poll lands on its most recently active row, whatever that
  row's status, never on an older row of the same title that still reads
  running. MEASURED 2026-10-09: with the live rows briefly stopped, polls went
  to running ghosts (ipsum-orchestrator idle since 2026-07-27) and woke them as second seats.
  """
  use ClaudiverseServerWeb.ConnCase, async: false

  import Ecto.Query
  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.{Repo, Sessions}
  alias ClaudiverseServer.Sessions.Session

  setup do
    {user, api} = user_with_token()
    %{user: user, api: api}
  end

  defp aged(session, hours) do
    at = NaiveDateTime.add(NaiveDateTime.utc_now(), -hours * 3600, :second) |> NaiveDateTime.truncate(:second)
    from(s in Session, where: s.id == ^session.id) |> Repo.update_all(set: [inserted_at: at])
    session
  end

  defp stop_room(id) do
    case Registry.lookup(ClaudiverseServer.Sessions.Registry, id) do
      [{pid, _}] -> ClaudiverseServer.Sessions.Supervisor.stop_room(pid)
      [] -> :ok
    end
  end

  defp poll(ctx, seat),
    do: build_conn() |> put_req_header("authorization", "Bearer " <> ctx.api) |> get("/api/seats/#{seat}/inbox?wait=0")

  test "a poll revives the seat's newest row, not a running ghost of its title", %{user: user} = ctx do
    ghost = session_fixture(user, %{title: "ipsum-orchestrator"}) |> aged(24 * 70)
    live = session_fixture(user, %{title: "ipsum-orchestrator", status: :stopped}) |> aged(1)
    Enum.each([ghost.id, live.id], &stop_room/1)
    on_exit(fn -> Enum.each([ghost.id, live.id], &stop_room/1) end)

    poll(ctx, "ipsum-orchestrator")

    assert Sessions.get_session!(live.id).status == :running
    assert Registry.lookup(ClaudiverseServer.Sessions.Registry, live.id) != []
    assert Registry.lookup(ClaudiverseServer.Sessions.Registry, ghost.id) == []
  end
end
