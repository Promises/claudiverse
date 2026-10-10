defmodule ClaudiverseServerWeb.HumanRequestController do
  @moduledoc """
  Seats asking for the operator (see HumanRequests).

  - `POST /api/human_requests` `%{"self" => seat, "summary", "detail"}` — the
    seat side (cv_request_human). The seat is `self`, else the calling seat's
    X-Claudiverse-Client title. A runner seat gets 403 and nothing is stored.
  - `GET /api/human_requests?status=open` — the app's list.
  - `POST /api/sessions/:id/human_requests/resolve` — APP TOKEN ONLY (403
    otherwise, like force-send): the operator opened the seat.
  """
  use ClaudiverseServerWeb, :controller

  alias ClaudiverseServer.Accounts

  alias ClaudiverseServer.{HumanRequests, Sessions}

  def create(conn, params) do
    user = conn.assigns.current_user
    seat = params["self"] || get_in(conn.assigns, [:client_identity, :title])
    summary = params["summary"]

    with {:seat, seat} when is_binary(seat) and seat != "" <- {:seat, seat},
         {:summary, s} when is_binary(s) and s != "" <- {:summary, summary},
         {:session, %{} = session} <- {:session, ClaudiverseServerWeb.McpController.seat_session(user, seat)} do
      case HumanRequests.request(session, summary, params["detail"]) do
        {:ok, req} -> json(conn, %{id: req.id, status: req.status})
        {:error, :runner} -> conn |> put_status(:forbidden) |> json(%{error: "runner seats cannot request a human"})
        {:error, :not_allowed} ->
          conn |> put_status(:forbidden) |> json(%{error: "this seat may not request a human (its launcher does not set CLAUDIVERSE_NOTIFY=1)"})
        {:error, cs} -> conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(cs.errors)})
      end
    else
      {:seat, _} -> conn |> put_status(:bad_request) |> json(%{error: "which seat? pass self"})
      {:summary, _} -> conn |> put_status(:bad_request) |> json(%{error: "summary is required"})
      {:session, _} -> conn |> put_status(:not_found) |> json(%{error: "no running session for that seat"})
    end
  end

  def index(conn, params) do
    status = if params["status"] in ~w(open resolved), do: params["status"], else: "open"
    json(conn, %{requests: HumanRequests.list(conn.assigns.current_user.id, status)})
  end

  def resolve(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    if not Accounts.app_powers?(conn.assigns[:token_context]) do
      conn |> put_status(:forbidden) |> json(%{error: "resolving human requests is app-only"})
    else
      case Sessions.get_user_session(user.id, id) do
        nil -> conn |> put_status(:not_found) |> json(%{error: "session not found"})
        session -> json(conn, %{resolved: HumanRequests.resolve_session(user.id, session.id)})
      end
    end
  end
end
