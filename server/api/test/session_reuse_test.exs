defmodule ClaudiverseServer.SessionReuseTest do
  @moduledoc """
  Registration reuses the seat's own row: by Claude session id, or by a
  recorded conversation_id (a seat started with `--resume <name>` on the
  patched runtime registered a placeholder session id). MEASURED 2026-10-06:
  claudiverse-desktop's profile start attached to an abandoned Oct 4 row.
  """
  use ClaudiverseServer.DataCase, async: false

  import ClaudiverseServer.Fixtures
  import Ecto.Query

  alias ClaudiverseServer.Sessions
  alias ClaudiverseServer.Sessions.Session

  @conv "7ca78cbc-ecdd-4c38-ac8b-d5b46110afc2"

  defp age!(s, iso) do
    {:ok, t, _} = DateTime.from_iso8601(iso)
    Repo.update_all(from(x in Session, where: x.id == ^s.id), set: [updated_at: DateTime.to_naive(t) |> NaiveDateTime.truncate(:second)])
  end

  defp register(user), do: Sessions.create_session(%{title: "claudiverse-desktop", type: :sidecar, mode: :json, status: :running, user_id: user.id, claude_session_id: @conv})

  test "the row that recorded the conversation and was active last is reused, not an old one with the session id" do
    user = user_fixture()
    abandoned = session_fixture(user, %{title: "claudiverse-desktop", claude_session_id: @conv, status: :stopped})
    real = session_fixture(user, %{title: "claudiverse-desktop", claude_session_id: "9febdcef-placeholder", status: :stopped})
    Repo.update_all(from(x in Session, where: x.id == ^real.id), set: [conversation_id: @conv])
    age!(abandoned, "2026-10-04T18:10:00Z")
    age!(real, "2026-10-06T12:02:01Z")

    assert {:ok, %Session{id: id, status: :running}} = register(user)
    assert id == real.id
  end

  test "control: with only the session-id row, it is reused as before" do
    user = user_fixture()
    only = session_fixture(user, %{title: "x", claude_session_id: @conv, status: :stopped})
    assert {:ok, %Session{id: id}} = register(user)
    assert id == only.id
  end

  test "another user's row is never reused" do
    user = user_fixture()
    other = user_fixture()
    theirs = session_fixture(other, %{title: "x", claude_session_id: @conv})
    assert {:ok, %Session{id: id}} = register(user)
    refute id == theirs.id
  end
end
