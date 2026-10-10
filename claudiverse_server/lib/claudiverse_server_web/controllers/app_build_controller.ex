defmodule ClaudiverseServerWeb.AppBuildController do
  @moduledoc """
  The Android app's self-update store (see AppBuilds).

  - `POST /api/app/builds` — multipart `apk` + `version_code`, `version_name`,
    `commit`, `notes`. APP TOKEN ONLY: a seat must never publish an APK.
  - `GET /api/app/builds/latest` — the stored build, with its download url.
  - `GET /api/app/builds/:id/apk` — the file (404 once replaced).
  """
  use ClaudiverseServerWeb, :controller

  alias ClaudiverseServer.Accounts

  alias ClaudiverseServer.AppBuilds

  def create(conn, params) do
    cond do
      not Accounts.app_powers?(conn.assigns[:token_context]) ->
        conn |> put_status(:forbidden) |> json(%{error: "publishing app builds is app-only"})

      not match?(%Plug.Upload{}, params["apk"]) ->
        conn |> put_status(:bad_request) |> json(%{error: "multipart field \"apk\" is required"})

      true ->
        attrs = Map.take(params, ~w(version_code version_name commit notes))

        case AppBuilds.publish(params["apk"].path, attrs) do
          {:ok, build} ->
            json(conn, serialize(build))

          {:error, :too_large} ->
            conn |> put_status(:request_entity_too_large) |> json(%{error: "apk exceeds #{AppBuilds.max_bytes()} bytes"})

          {:error, :no_storage} ->
            conn |> put_status(:service_unavailable) |> json(%{error: "no build storage configured"})

          {:error, %Ecto.Changeset{} = cs} ->
            conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(cs.errors)})

          {:error, reason} ->
            conn |> put_status(:internal_server_error) |> json(%{error: "store failed: #{inspect(reason)}"})
        end
    end
  end

  def latest(conn, _params) do
    case AppBuilds.latest() do
      nil -> conn |> put_status(:not_found) |> json(%{error: "no builds"})
      build -> json(conn, Map.put(serialize(build), :url, "/api/app/builds/#{build.id}/apk"))
    end
  end

  def apk(conn, %{"id" => id}) do
    with {int_id, ""} <- Integer.parse(id),
         %{} = build <- AppBuilds.get(int_id),
         path = AppBuilds.path(build),
         true <- File.exists?(path) do
      conn
      |> put_resp_content_type("application/vnd.android.package-archive", nil)
      |> put_resp_header("content-disposition", ~s(attachment; filename="claudiverse-#{build.version_name}.apk"))
      |> send_file(200, path)
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: "build not found"})
    end
  end

  defp serialize(b) do
    %{id: b.id, version_code: b.version_code, version_name: b.version_name, commit: b.commit,
      notes: b.notes, sha256: b.sha256, size: b.size, inserted_at: b.inserted_at}
  end
end
