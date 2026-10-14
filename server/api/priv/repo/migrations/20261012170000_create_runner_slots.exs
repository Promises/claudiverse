defmodule ClaudiverseServer.Repo.Migrations.CreateRunnerSlots do
  @moduledoc """
  Each runner slot's last heartbeat, kept (Runners): its state, where it runs,
  when it last beat, and since when it has beaten without a gap. The registry
  itself stays in memory; this row outlives a server restart, so whether a
  slot was alive through a window can still be answered after the fact.
  """
  use Ecto.Migration

  def change do
    create table(:runner_slots) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :slot, :string, null: false
      add :fleet, :string
      add :state, :string, null: false
      add :host, :string
      add :lane, :string
      add :beating_since, :utc_datetime, null: false
      add :last_seen_at, :utc_datetime, null: false
      timestamps()
    end

    create unique_index(:runner_slots, [:user_id, :slot])
  end
end
