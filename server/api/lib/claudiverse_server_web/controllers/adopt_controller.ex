defmodule ClaudiverseServerWeb.AdoptController do
  @moduledoc """
  Adopt a seat started by hand into a profile (ClaudiverseServer.Adopt).
  APP OR SUPER TOKEN, like starting and stopping a profile.

  - A row with no host (an older plain seat) may name one: `?host=` on the
    preview, `"host"` in the adopt body (the app's own machine). Only a match
    by conversation id is accepted there; a row WITH a host ignores it.
  - `GET /api/sessions/:id/adopt_preview` → 200 `{process, existing_profile,
    suggested, blocked}`; `blocked` is a sentence for the operator, or null.
  - `POST /api/sessions/:id/adopt` {profile fields, pid, proc_start,
    profile_id?, force?} → 202 `{profile}`. 409 `{error, code}` with code
    busy | profile_running | runner | process_changed | several | blocked;
    422 `{errors}`; 504 when the machine's agent is offline.
  """
  use ClaudiverseServerWeb, :controller

  alias ClaudiverseServer.{Accounts, Adopt, Profiles, Sessions}

  def preview(conn, %{"id" => id}) do
    with :ok <- app_only(conn), {:ok, session} <- fetch(conn, id) do
      json(conn, Adopt.preview(conn.assigns.current_user.id, session, params_host(conn)))
    end
  end

  def adopt(conn, %{"id" => id} = params) do
    user_id = conn.assigns.current_user.id

    with :ok <- app_only(conn), {:ok, session} <- fetch(conn, id) do
      case Adopt.adopt(user_id, session, params) do
        {:ok, profile} ->
          conn |> put_status(:accepted) |> json(%{profile: hd(Profiles.with_status(user_id, [profile]))})

        {:error, "offline", message} ->
          conn |> put_status(:gateway_timeout) |> json(%{error: message, code: "offline"})

        {:error, code, message} ->
          conn |> put_status(:conflict) |> json(%{error: message, code: conflict_code(code)})

        {:error, %Ecto.Changeset{} = cs} ->
          conn |> put_status(:unprocessable_entity) |> json(%{errors: errors(cs)})
      end
    end
  end

  # A row with no host may be looked for on the machine the app names.
  defp params_host(conn), do: conn.params["host"]

  # The agent's refusal codes the app acts on; any other refusal is "blocked"
  # and its message says why.
  defp conflict_code(code) when code in ~w(busy profile_running runner process_changed several), do: code
  defp conflict_code(_), do: "blocked"

  defp fetch(conn, id) do
    case Sessions.get_user_session(conn.assigns.current_user.id, id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "Not found"})
      session -> {:ok, session}
    end
  end

  defp app_only(conn) do
    if Accounts.app_powers?(conn.assigns[:token_context]),
      do: :ok,
      else: conn |> put_status(:forbidden) |> json(%{error: "adopting seats is app-only"})
  end

  defp errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
  end
end
