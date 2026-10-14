defmodule ClaudiverseServerWeb.RestartController do
  @moduledoc """
  Restarting idle seats (Restarts). APP OR SUPER TOKEN ONLY.

  - `POST /api/sessions/:id/restart` {dry_run, include_self, caller,
    confirm_protected}: one seat. Not eligible: 409 {error, reason_code}
    (504 when its machine is offline). dry_run: 200 {seat}. Else 202
    {restart_id, seat}; the outcome arrives as "seat_restart".
  - `POST /api/hosts/:host/restart_idle`, `POST /api/hosts/restart_idle` (every
    machine): {session_ids, exclude_session_ids, fleets, exclude_fleets,
    exclude_paused (default true), only_outdated, dry_run, caller,
    include_self}. dry_run: 200 {seats}. Else 202 {batch_id, seats}; the
    seats are restarted one at a time ("seat_restart", "restart_batch").
  """
  use ClaudiverseServerWeb, :controller

  import Ecto.Query

  alias ClaudiverseServer.{Accounts, Repo, Restarts, Sessions}
  alias ClaudiverseServer.Sessions.Session

  def restart_one(conn, %{"id" => id} = params) do
    user_id = conn.assigns.current_user.id

    with :ok <- app_only(conn),
         %Session{} = s <- Sessions.get_user_session(user_id, id) do
      [entry] = Restarts.plan(user_id, [s], params, true)

      cond do
        entry.action == "skip" and entry.reason_code == "offline" ->
          conn |> put_status(:gateway_timeout) |> json(%{error: entry.reason, reason_code: "offline"})

        entry.action == "skip" ->
          conn |> put_status(:conflict) |> json(%{error: entry.reason, reason_code: entry.reason_code})

        params["dry_run"] == true ->
          json(conn, %{seat: entry})

        true ->
          conn |> put_status(:accepted) |> json(%{restart_id: Restarts.start_one(user_id, entry), seat: entry})
      end
    else
      {:refused, conn} -> conn
      nil -> conn |> put_status(:not_found) |> json(%{error: "no such seat"})
    end
  end

  def restart_idle(conn, params) do
    user_id = conn.assigns.current_user.id
    host = params["host"]

    case app_only(conn) do
      :ok ->
        sessions =
          from(s in Session,
            where: s.user_id == ^user_id and s.status == :running and s.type != :proxy and not is_nil(s.host),
            order_by: [asc: s.host, asc: s.title],
            select: s.id
          )
          |> then(fn q -> if host, do: where(q, [s], s.host == ^host), else: q end)
          |> Repo.all()
          |> Enum.map(&Sessions.get_user_session(user_id, &1))

        seats = Restarts.plan(user_id, sessions, params)

        if params["dry_run"] == true do
          json(conn, %{seats: seats})
        else
          conn |> put_status(:accepted) |> json(%{batch_id: Restarts.start_batch(user_id, seats, host), seats: seats})
        end

      {:refused, conn} ->
        conn
    end
  end

  defp app_only(conn) do
    if Accounts.app_powers?(conn.assigns[:token_context]),
      do: :ok,
      else: {:refused, conn |> put_status(:forbidden) |> json(%{error: "restarting seats is app-only"})}
  end
end
