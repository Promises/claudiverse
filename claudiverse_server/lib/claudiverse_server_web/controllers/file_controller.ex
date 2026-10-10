defmodule ClaudiverseServerWeb.FileController do
  @moduledoc """
  The operator's app sends a seat a file; the seat downloads it.

  - `POST /api/sessions/:id/files` (multipart field `file`) — APP TOKEN ONLY.
    Every seat carries the shared "api" token, so any other token gets 403 and
    nothing is stored. The app then tells the seat, in an ordinary message, how
    to fetch it.
  - `GET /api/files/:file_id` — any valid token, so the seat can fetch it with
    its own CLAUDIVERSE_TOKEN.
  """
  use ClaudiverseServerWeb, :controller

  alias ClaudiverseServer.Accounts

  alias ClaudiverseServer.{SeatFiles, Sessions}

  def create(conn, %{"id" => session_id} = params) do
    cond do
      not Accounts.app_powers?(conn.assigns[:token_context]) ->
        conn |> put_status(:forbidden) |> json(%{error: "file send is app-only"})

      is_nil(Sessions.get_user_session(conn.assigns.current_user.id, session_id)) ->
        conn |> put_status(:not_found) |> json(%{error: "session not found"})

      true ->
        store(conn, params["file"], session_id)
    end
  end

  defp store(conn, %Plug.Upload{path: path, filename: name}, session_id) do
    case SeatFiles.store(path, name, session_id) do
      {:ok, meta} ->
        json(conn, %{file_id: meta["file_id"], name: meta["name"], size: meta["size"],
                     url: "/api/files/" <> meta["file_id"]})

      {:error, :too_large} ->
        conn |> put_status(:request_entity_too_large) |> json(%{error: "file exceeds #{SeatFiles.max_bytes()} bytes"})

      {:error, :no_storage} ->
        conn |> put_status(:service_unavailable) |> json(%{error: "no file storage configured"})

      {:error, reason} ->
        conn |> put_status(:internal_server_error) |> json(%{error: "store failed: #{inspect(reason)}"})
    end
  end

  defp store(conn, _not_an_upload, _session_id) do
    conn |> put_status(:bad_request) |> json(%{error: "multipart field \"file\" is required"})
  end

  def show(conn, %{"file_id" => id}) do
    case SeatFiles.fetch(id) do
      {:ok, meta, blob} ->
        # An image a seat mirrored is served as what it is; anything else as bytes.
        type = if SeatFiles.image_type?(meta["media_type"]), do: meta["media_type"], else: "application/octet-stream"

        conn
        |> put_resp_content_type(type, nil)
        |> put_resp_header("content-disposition", disposition(meta["name"]))
        |> send_file(200, blob)

      :not_found ->
        conn |> put_status(:not_found) |> json(%{error: "file not found"})
    end
  end

  # ASCII fallback plus the exact UTF-8 name (RFC 6266).
  defp disposition(name) do
    ascii = name |> String.replace(~r/[^\x20-\x7e]/u, "_") |> String.replace(~r/["\\]/, "_")
    ~s(attachment; filename="#{ascii}"; filename*=UTF-8''#{URI.encode(name, &URI.char_unreserved?/1)})
  end
end
