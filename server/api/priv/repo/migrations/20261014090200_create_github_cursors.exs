defmodule ClaudiverseServer.Repo.Migrations.CreateGithubCursors do
  @moduledoc """
  Where each GitHub source was read up to (GitHub.Poller): a repository's
  `since`, the items a search last returned, a token's expiry warning. Kept
  so a restart fires nothing twice.
  """
  use Ecto.Migration

  def change do
    create table(:github_cursors) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :source, :string, null: false
      add :data, :map, null: false, default: %{}
      timestamps()
    end

    create unique_index(:github_cursors, [:user_id, :source])
  end
end
