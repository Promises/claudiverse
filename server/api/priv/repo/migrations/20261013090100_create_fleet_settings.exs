defmodule ClaudiverseServer.Repo.Migrations.CreateFleetSettings do
  @moduledoc """
  Per fleet, what the operator set (Fleets): `paused`, which a bulk restart
  leaves out by default. A fleet with no row is not paused.
  """
  use Ecto.Migration

  def change do
    create table(:fleet_settings) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :fleet, :string, null: false
      add :paused, :boolean, default: false, null: false
      timestamps()
    end

    create unique_index(:fleet_settings, [:user_id, :fleet])
  end
end
