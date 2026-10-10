defmodule ClaudiverseServerWeb.SeatController do
  @moduledoc """
  `GET /api/seats/whoami?claude_session_id=<id>` (or `?title=<title>`)

  Which seat a process belongs to, and what it may use: for one global
  claudiverse MCP config shared by every seat, in place of a per-seat
  `.mcp.json` carrying CLAUDIVERSE_SELF / _ROLE / _NOTIFY. cv-mcp is started by
  Claude Code with CLAUDE_CODE_SESSION_ID in its environment, the id the seat
  registers under (the claudiverse-seat mod, or the patched sidecar).

  → `{session_id, title, role, can_notify, fleet, origin}`: a running
  non-proxy row first (a stale row of the same title must not answer for the
  live seat, measured 2026-10-05), else the newest; `role` is the server's tool policy for the seat:
  `"worker"` for a runner's worker (only reporting and the shared tools),
  `"orchestrator"` otherwise (a profile's seat included, whatever its board
  role). `profile_id` is the profile the seat was started from, or nil. 404 until the seat has registered; the caller
  retries.
  """
  use ClaudiverseServerWeb, :controller

  import Ecto.Query

  alias ClaudiverseServer.Repo
  alias ClaudiverseServer.Sessions.Session

  def whoami(conn, params) do
    user_id = conn.assigns.current_user.id

    query =
      case params do
        %{"claude_session_id" => id} when is_binary(id) and id != "" -> where(Session, claude_session_id: ^id)
        %{"title" => t} when is_binary(t) and t != "" -> where(Session, title: ^t)
        _ -> nil
      end

    case query && Repo.one(from s in query, where: s.user_id == ^user_id and s.type != :proxy, order_by: [desc: s.status == :running, desc: s.inserted_at, desc: s.id], limit: 1) do
      nil when is_nil(query) ->
        conn |> put_status(:bad_request) |> json(%{error: "claude_session_id or title is required"})

      nil ->
        conn |> put_status(:not_found) |> json(%{error: "no seat registered under that id yet"})

      s ->
        {role, can_notify} = ClaudiverseServer.Sessions.Access.effective(s)

        json(conn, %{
          session_id: s.id,
          title: s.title,
          role: role,
          can_notify: can_notify,
          access: ClaudiverseServer.Sessions.Access.level(s),
          fleet: s.fleet,
          origin: s.origin,
          profile_id: s.profile_id
        })
    end
  end
end
