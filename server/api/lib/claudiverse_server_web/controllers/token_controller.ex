defmodule ClaudiverseServerWeb.TokenController do
  @moduledoc """
  SUPER TOKEN ONLY: the operator's tokens, so the desktop can see which
  devices are signed in and cut one off.

  - `GET /api/tokens` — id, context, label, inserted_at; never the values.
    `current: true` marks the token making the request.
  - `DELETE /api/tokens/:id` — revoke one. 409 for an unlabelled "api" token:
    it may be the fleet's shared seat token (Accounts.revoke_token/2).
  """
  use ClaudiverseServerWeb, :controller

  alias ClaudiverseServer.Accounts

  plug :super_only

  def index(conn, _params) do
    current = current_token_id(conn)
    tokens = for t <- Accounts.list_tokens(conn.assigns.current_user), do: Map.put(t, :current, t.id == current)
    json(conn, %{tokens: tokens})
  end

  def delete(conn, %{"id" => id}) do
    case Integer.parse(id) do
      {n, ""} ->
        case Accounts.revoke_token(conn.assigns.current_user, n) do
          :ok -> json(conn, %{ok: true})
          {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "Not found"})
          {:error, :protected} -> conn |> put_status(:conflict) |> json(%{error: "this may be the fleet's shared seat token; revoke it on the server"})
        end

      _ ->
        conn |> put_status(:bad_request) |> json(%{error: "bad token id"})
    end
  end

  defp current_token_id(conn) do
    case Accounts.token_id(conn.assigns[:api_token]) do
      {:ok, id} -> id
      _ -> nil
    end
  end

  defp super_only(conn, _opts) do
    if Accounts.super_powers?(conn.assigns[:token_context]),
      do: conn,
      else: conn |> put_status(:forbidden) |> json(%{error: "managing tokens needs the super (desktop) token"}) |> halt()
  end
end
