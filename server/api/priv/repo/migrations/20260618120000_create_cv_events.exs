defmodule ClaudiverseServer.Repo.Migrations.CreateCvEvents do
  use Ecto.Migration

  # Structured observability log: state transitions (and, later, client cvdebug
  # snapshots) in a queryable table so we can build pictures with SQL instead of
  # grepping the server log — and so it survives restarts. One DB; index, don't
  # split.
  def change do
    create table(:cv_events) do
      add :session_id, references(:sessions, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :from_state, :string
      add :to_state, :string
      add :trigger, :string
      add :detail, :map

      timestamps(updated_at: false)
    end

    create index(:cv_events, [:session_id, :inserted_at])
    create index(:cv_events, [:kind])
  end
end
