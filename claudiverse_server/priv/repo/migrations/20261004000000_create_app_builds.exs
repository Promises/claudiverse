defmodule ClaudiverseServer.Repo.Migrations.CreateAppBuilds do
  @moduledoc """
  The Android app's self-update store: the latest published APK, which the app
  downloads over its own connection. Only ONE build is kept (operator,
  2026-10-04: storage is limited); a publish replaces it.
  """
  use Ecto.Migration

  def change do
    create table(:app_builds) do
      add :version_code, :integer, null: false
      add :version_name, :string, null: false
      add :commit, :string
      add :notes, :text
      add :sha256, :string, null: false
      add :size, :bigint, null: false
      # The file's name under the build directory (never a client-chosen path).
      add :file, :string, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
