defmodule ClaudiverseServer.Repo.Migrations.CreateJoinCodes do
  @moduledoc """
  One-time join codes (ClaudiverseServer.JoinCodes): the panel's "Add a
  machine" mints one, and a machine's installer redeems it once, within
  minutes, for that machine's seat and host tokens. Only the code's hash is
  stored.
  """
  use Ecto.Migration

  def change do
    create table(:join_codes) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :code_hash, :string, null: false
      add :machine, :string
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      add :used_by_machine, :string
      timestamps()
    end

    create unique_index(:join_codes, [:code_hash])
    create index(:join_codes, [:user_id])
  end
end
