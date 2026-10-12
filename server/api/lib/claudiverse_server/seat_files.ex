defmodule ClaudiverseServer.SeatFiles do
  @moduledoc """
  Files the operator's app sends to a seat. Seats run on other hosts, so a file
  is stored here and the seat fetches it over HTTP with its own token.

  One directory per file under `dir/0`, which sits on the /data volume next to
  the database so a container swap keeps it:

      <dir>/<file_id>/meta.json   name, size, session_id, uploaded_at
      <dir>/<file_id>/blob

  The original name lives only in meta.json, never in a path, so no name can
  steer where a file is written. `file_id` is random and is checked against
  its own shape before it touches the filesystem.
  """

  @max_bytes 25 * 1024 * 1024
  @id_shape ~r/\A[A-Za-z0-9_-]{22}\z/

  def max_bytes, do: @max_bytes

  @doc "Where files are kept, or nil when the server has no data directory."
  def dir do
    cond do
      d = Application.get_env(:claudiverse_server, :seat_files_dir) -> d
      db = System.get_env("DATABASE_PATH") -> Path.join(Path.dirname(db), "seat-files")
      true -> nil
    end
  end

  @doc "Store the file at `source` (an upload's temp path) for `session_id`."
  def store(source, name, session_id) do
    with root when is_binary(root) <- dir() || {:error, :no_storage},
         {:ok, %{size: size}} <- File.stat(source),
         :ok <- if(size <= @max_bytes, do: :ok, else: {:error, :too_large}) do
      id = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      target = Path.join(root, id)
      meta = %{"name" => clean_name(name), "size" => size, "session_id" => session_id,
               "uploaded_at" => DateTime.utc_now() |> DateTime.to_iso8601()}

      with :ok <- File.mkdir_p(target),
           {:ok, _} <- File.copy(source, Path.join(target, "blob")),
           :ok <- File.write(Path.join(target, "meta.json"), Jason.encode!(meta)) do
        {:ok, Map.put(meta, "file_id", id)}
      else
        error ->
          File.rm_rf(target)
          error
      end
    end
  end

  @image_types ~w(image/png image/jpeg image/gif image/webp)
  def image_type?(t), do: t in @image_types

  @doc """
  Store `bytes` (an image a seat mirrored) for `session_id`, CONTENT-ADDRESSED:
  the id is derived from the bytes, so the same picture mirrored twice (a
  replayed record, a second viewer) is stored once. `{:ok, meta}` with
  "file_id" and "media_type".
  """
  def store_bytes(bytes, name, media_type, session_id) when is_binary(bytes) do
    with root when is_binary(root) <- dir() || {:error, :no_storage},
         :ok <- if(byte_size(bytes) <= @max_bytes, do: :ok, else: {:error, :too_large}) do
      id = :crypto.hash(:sha256, bytes) |> binary_part(0, 16) |> Base.url_encode64(padding: false)
      target = Path.join(root, id)
      meta = %{"name" => clean_name(name), "size" => byte_size(bytes), "session_id" => session_id,
               "media_type" => media_type, "uploaded_at" => DateTime.utc_now() |> DateTime.to_iso8601()}

      if File.exists?(Path.join(target, "meta.json")) do
        {:ok, Map.put(meta, "file_id", id)}
      else
        with :ok <- File.mkdir_p(target),
             :ok <- File.write(Path.join(target, "blob"), bytes),
             :ok <- File.write(Path.join(target, "meta.json"), Jason.encode!(meta)) do
          {:ok, Map.put(meta, "file_id", id)}
        else
          error ->
            File.rm_rf(target)
            error
        end
      end
    end
  end

  @doc """
  `message` with every inline base64 image block, at any depth (a user
  prompt's paste, a tool result's screenshot), moved into the store and
  replaced by a reference the apps fetch:

      %{"type" => "image", "size" => bytes,
        "source" => %{"type" => "url", "url" => "/api/files/<id>", "media_type" => "image/png"}}

  A screenshot is ~120K characters of base64; inline it would be stored in
  the message row, kept in the replay buffer and sent to every viewer. A
  block that cannot be stored (no storage, bad base64, not an image type)
  is left as it was.
  """
  def externalize_images(message, session_id) do
    if dir(), do: walk(message, session_id), else: message
  end

  defp walk(%{"type" => "image", "source" => %{"type" => "base64", "data" => data, "media_type" => mt}} = block, sid)
       when is_binary(data) do
    with true <- image_type?(mt),
         {:ok, bytes} <- Base.decode64(data, ignore: :whitespace),
         {:ok, meta} <- store_bytes(bytes, "image." <> String.replace_prefix(mt, "image/", ""), mt, sid) do
      block
      |> Map.put("source", %{"type" => "url", "url" => "/api/files/" <> meta["file_id"], "media_type" => mt})
      |> Map.put("size", meta["size"])
    else
      _ -> block
    end
  end

  defp walk(map, sid) when is_map(map), do: Map.new(map, fn {k, v} -> {k, walk(v, sid)} end)
  defp walk(list, sid) when is_list(list), do: Enum.map(list, &walk(&1, sid))
  defp walk(other, _sid), do: other

  @doc "`{:ok, meta, blob_path}` for a stored file, else `:not_found`."
  def fetch(id) do
    with true <- is_binary(id) and Regex.match?(@id_shape, id),
         root when is_binary(root) <- dir(),
         {:ok, json} <- File.read(Path.join([root, id, "meta.json"])),
         {:ok, meta} <- Jason.decode(json) do
      {:ok, meta, Path.join([root, id, "blob"])}
    else
      _ -> :not_found
    end
  end

  # A display name only: the last path segment, no control characters.
  defp clean_name(name) do
    cleaned =
      (name || "")
      |> Path.basename()
      |> String.replace(~r/[\x00-\x1f\x7f]/u, "")
      |> String.trim()

    if cleaned in ["", ".", ".."], do: "file", else: cleaned
  end
end
