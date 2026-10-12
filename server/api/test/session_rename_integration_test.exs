defmodule ClaudiverseServerWeb.SessionRenameIntegrationTest do
  @moduledoc """
  The rename path END TO END, through the real HTTP request with the real header.

  🔴 THIS IS THE TEST THAT WAS MISSING. Three attempts at this feature passed
  their unit tests while production renamed nothing, because every one of them
  called the context functions DIRECTLY with values I chose. The defect was that
  the two records never shared a value in the first place — invisible unless the
  request itself produces them.
  """
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures

  alias ClaudiverseServer.AnthropicAuths
  alias ClaudiverseServer.AnthropicAuths.AnthropicAuth
  alias ClaudiverseServer.Repo

  @instance "inst-e2e-1"

  defp seat_conn(conn, token, title, session_id) do
    ident =
      "title=#{URI.encode_www_form(title)}; id=#{URI.encode_www_form(session_id || "")}; instance=#{@instance}"

    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("x-claudiverse-client", ident)
    |> put_req_header("content-type", "application/json")
  end

  test "a seat renamed after startup: its account assignment follows", %{conn: conn} do
    {_user, token} = user_with_token()

    auth = Repo.insert!(%AnthropicAuth{label: "Personal", priority: 10, status: "available"})

    # 1. STARTUP LEASE — before Claude's session hook, so the title is a
    #    timestamp and there is no session id. Seeded directly rather than
    #    driven over HTTP: a real lease needs a vault-encrypted token this env
    #    has no key for, and the lease's own recording is covered by
    #    AnthropicAuthAssignmentTest. What was broken, and what this test is
    #    for, is everything AFTER this point.
    :ok =
      AnthropicAuths.record_assignment(
        %{title: "Claude 11:41:02 AM", claude_session_id: nil, instance_id: @instance},
        auth.id,
        "lease"
      )

    assert [row] = AnthropicAuths.list_assignments()
    assert row.title == "Claude 11:41:02 AM"
    assert row.anthropic_auth_id == auth.id
    assert row.instance_id == @instance

    # 2. SESSION CREATE — the hook has fired, so the title is now the UUID.
    #    The assignment and the session share NO title at this point; only the
    #    instance connects them.
    uuid = "4092e923-ddcb-476f-916c-77fe5f6fb571"

    conn
    |> seat_conn(token, uuid, uuid)
    |> post(~p"/api/sessions", %{"title" => uuid, "claude_session_id" => uuid})

    assert [%{title: ^uuid}] = AnthropicAuths.list_assignments()

    # 3. AUTO-NAMED, then /rename — each is a re-POST from the client.
    for name <- ["runejs-f3", "hello-0world"] do
      conn
      |> seat_conn(token, name, uuid)
      |> post(~p"/api/sessions", %{"title" => name, "claude_session_id" => uuid})
    end

    assert [final] = AnthropicAuths.list_assignments(),
           "one seat must have exactly one assignment row, never a fork"

    assert final.title == "hello-0world"
    assert final.claude_session_id == uuid
    assert final.instance_id == @instance
    assert final.anthropic_auth_id == auth.id
  end

  test "display_title is stored, exposed, and never wiped by a push that omits it", %{conn: conn} do
    {user, token} = user_with_token()
    uuid = "d15p-1111-2222-3333-444455556666"

    # 1. arrives with a display title
    conn
    |> seat_conn(token, "runejs-38", uuid)
    |> post(~p"/api/sessions", %{
      "title" => "runejs-38",
      "claude_session_id" => uuid,
      "display_title" => "Knights of Ni follow-up phrase"
    })

    [s] = ClaudiverseServer.Sessions.list_sessions(user.id, []) |> Enum.filter(&(&1.title == "runejs-38"))
    assert s.display_title == "Knights of Ni follow-up phrase"

    # 2. a later push carries no display_title — must NOT clear the stored one.
    #    A plain Map.get would have written nil here.
    conn
    |> seat_conn(token, "runejs-38", uuid)
    |> post(~p"/api/sessions", %{"title" => "runejs-38", "claude_session_id" => uuid})

    [s2] = ClaudiverseServer.Sessions.list_sessions(user.id, []) |> Enum.filter(&(&1.title == "runejs-38"))
    assert s2.display_title == "Knights of Ni follow-up phrase", "absence must mean no news, not clear it"

    # 3. and the API exposes it, which is what cv_list renders
    body =
      conn
      |> seat_conn(token, "runejs-38", uuid)
      |> get(~p"/api/sessions")
      |> json_response(200)

    row = Enum.find(body["sessions"], &(&1["title"] == "runejs-38"))
    assert row["display_title"] == "Knights of Ni follow-up phrase"
  end

  test "a seat that has reported no model has none: no default stands in for it", %{conn: conn} do
    # The panel showed "sonnet" for every new seat, a Haiku one included: the
    # row's default, not anything the seat said.
    {_user, token} = user_with_token()

    body =
      conn
      |> seat_conn(token, "seat-new", "new-1111-2222-3333-444455556666")
      |> post(~p"/api/sessions", %{"title" => "seat-new", "claude_session_id" => "new-1111-2222-3333-444455556666"})
      |> json_response(201)

    # The stored row, not the response: the response echoes the struct, which
    # read nil while the column's default put "sonnet" in the row.
    assert %{model: nil} = ClaudiverseServer.Repo.get!(ClaudiverseServer.Sessions.Session, body["session"]["id"])
  end

  test "🔴 a rename must not RESET the model the seat reported", %{conn: conn} do
    # Measured: a session reporting "claude-opus-5" reverted to "sonnet" the
    # moment it was renamed, because create_session took
    # `model: Map.get(params, "model", "sonnet")` and the client never sends one.
    # Every title push therefore undid what Room had extracted from the seat's
    # own assistant messages.
    {user, token} = user_with_token()
    uuid = "mdl-1111-2222-3333-444455556666"

    conn
    |> seat_conn(token, "seat-m", uuid)
    |> post(~p"/api/sessions", %{"title" => "seat-m", "claude_session_id" => uuid})

    [s] = ClaudiverseServer.Sessions.list_sessions(user.id, []) |> Enum.filter(&(&1.title == "seat-m"))
    {:ok, _} = ClaudiverseServer.Sessions.update_session(s, %{model: "claude-opus-5"})

    # the client renames the seat — carrying no model, as it never does
    conn
    |> seat_conn(token, "seat-m-renamed", uuid)
    |> post(~p"/api/sessions", %{"title" => "seat-m-renamed", "claude_session_id" => uuid})

    [after_rename] =
      ClaudiverseServer.Sessions.list_sessions(user.id, [])
      |> Enum.filter(&(&1.title == "seat-m-renamed"))

    assert after_rename.model == "claude-opus-5",
           "absence of model must mean no news, not reset to the default"
  end
end
