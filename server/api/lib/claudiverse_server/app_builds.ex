defmodule ClaudiverseServer.AppBuilds do
  @moduledoc """
  The Android app's self-update store. The app publishes a signed APK (app
  token only, AppBuildController) and every install downloads the latest one
  over its own connection. Android refuses an update not signed with the
  installed app's key and the app checks the sha256, so this only stores and
  serves.

  🔴 ONE BUILD, REPLACED ONLY ON SUCCESS. Storage is limited (operator,
  2026-10-04), so a publish replaces the stored build — but the old one is
  deleted only after the new file is fully written, its sha256 computed and
  its row inserted. A failed upload never leaves zero builds.
  """
  import Ecto.Query
  require Logger

  alias ClaudiverseServer.Repo
  alias ClaudiverseServer.AppBuilds.AppBuild

  @max_bytes 100 * 1024 * 1024

  def max_bytes, do: @max_bytes

  # The enforced cap; overridable so a test need not write 100 MiB.
  defp cap, do: Application.get_env(:claudiverse_server, :app_builds_max_bytes, @max_bytes)

  @doc "Where APKs are kept: beside the database on /data, so a swap keeps them."
  def dir do
    cond do
      d = Application.get_env(:claudiverse_server, :app_builds_dir) -> d
      db = System.get_env("DATABASE_PATH") -> Path.join(Path.dirname(db), "app-builds")
      true -> nil
    end
  end

  @doc """
  Store the APK at `source` (an upload's temp file) as the new latest build.
  `{:ok, build}`, `{:error, :too_large | :no_storage}` or `{:error, changeset}`;
  on any error the previous build is untouched.
  """
  def publish(source, attrs) do
    with root when is_binary(root) <- dir() || {:error, :no_storage},
         {:ok, %{size: size}} <- File.stat(source),
         :ok <- if(size <= cap(), do: :ok, else: {:error, :too_large}),
         :ok <- File.mkdir_p(root) do
      file = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false) <> ".apk"
      target = Path.join(root, file)

      with {:ok, _} <- File.copy(source, target),
           sha = sha256(target),
           {:ok, build} <-
             %AppBuild{}
             |> AppBuild.changeset(Map.merge(attrs, %{"sha256" => sha, "size" => size, "file" => file}))
             |> Repo.insert() do
        drop_all_but(build)
        Logger.info("[app_builds] published #{build.version_name} (#{build.version_code}), #{size} bytes")
        {:ok, build}
      else
        error ->
          File.rm(target)
          error
      end
    end
  end

  @doc "The stored build (the newest by version_code), or nil."
  def latest do
    from(b in AppBuild, order_by: [desc: b.version_code, desc: b.id], limit: 1) |> Repo.one()
  end

  def get(id), do: Repo.get(AppBuild, id)

  def path(%AppBuild{file: file}), do: Path.join(dir(), file)

  # Everything except `keep`, rows first then files: a crash in between leaves
  # an orphan file, never a row pointing at nothing.
  defp drop_all_but(%AppBuild{id: keep_id}) do
    old = from(b in AppBuild, where: b.id != ^keep_id) |> Repo.all()

    for b <- old do
      Repo.delete!(b)
      File.rm(path(b))
    end
  end

  defp sha256(path) do
    path
    |> File.stream!(2_097_152)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
