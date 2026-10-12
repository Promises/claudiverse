defmodule ClaudiverseServer.Repo.Migrations.CreateMachines do
  @moduledoc """
  The machines a user's host agents have joined as, and when each was last
  seen (Hosts.seen/2): the web panel lists a machine that is offline now,
  with when it was last there, not only the ones online.
  """
  use Ecto.Migration

  def change do
    create table(:machines) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :last_seen_at, :utc_datetime, null: false
      timestamps()
    end

    create unique_index(:machines, [:user_id, :name])
  end
end
