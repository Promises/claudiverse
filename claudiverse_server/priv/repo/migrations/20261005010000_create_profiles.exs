defmodule ClaudiverseServer.Repo.Migrations.CreateProfiles do
  @moduledoc """
  Seat profiles (docs/design/seat-profiles.md): one record per managed seat,
  started by its machine's host agent. Sessions record the profile and the
  revision they were started with, and their tmux session.
  """
  use Ecto.Migration

  def change do
    create table(:profiles) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :revision, :integer, null: false, default: 1
      add :machine, :string, null: false
      add :folder, :string, null: false
      add :fleet, :string
      add :role, :string, null: false, default: "member"
      add :can_notify, :boolean, null: false, default: false
      add :runtime, :string, null: false, default: "stock+mod"
      add :model, :string
      add :effort, :string
      add :permission_mode, :string, null: false, default: "default"
      add :mcp, {:array, :string}, null: false, default: []
      add :pooled, :boolean, null: false, default: false
      add :autostart, :boolean, null: false, default: false
      add :resume, :string, null: false, default: "latest"
      add :debug, :boolean, null: false, default: false
      add :last_start, :map
      timestamps()
    end

    create unique_index(:profiles, [:user_id, :name])

    alter table(:sessions) do
      add :profile_id, :integer
      add :profile_revision, :integer
      add :tmux_session, :string
    end

    create index(:sessions, [:profile_id])
  end
end
