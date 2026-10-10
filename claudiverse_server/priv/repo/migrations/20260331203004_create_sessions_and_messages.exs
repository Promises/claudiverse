defmodule ClaudiverseServer.Repo.Migrations.CreateSessionsAndMessages do
  use Ecto.Migration

  def change do
    create table(:sessions) do
      add :title, :string
      add :type, :string, null: false, default: "spawned"
      add :mode, :string, default: "json"
      add :status, :string, null: false, default: "running"
      add :working_directory, :string
      add :model, :string, default: "sonnet"
      add :permission_mode, :string, default: "default"
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:sessions, [:user_id])
    create index(:sessions, [:status])

    create table(:messages) do
      add :type, :string, null: false
      add :payload, :map, null: false
      add :sequence, :integer, null: false
      add :session_id, references(:sessions, on_delete: :delete_all), null: false

      timestamps(updated_at: false)
    end

    create index(:messages, [:session_id])
    create index(:messages, [:session_id, :sequence])
  end
end
