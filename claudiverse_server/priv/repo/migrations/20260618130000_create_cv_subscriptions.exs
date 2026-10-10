defmodule ClaudiverseServer.Repo.Migrations.CreateCvSubscriptions do
  use Ecto.Migration

  # Persist Router subscriptions (listener title -> watched titles) so a server
  # restart no longer wipes them. Keyed by title (stable across relaunch); the
  # live session id is rebound on the listener's next idle. queue/idle stay
  # in-memory (transient — stale after a restart anyway).
  def change do
    create table(:cv_subscriptions, primary_key: false) do
      add :listener_title, :string, primary_key: true
      add :watch, :map, null: false

      timestamps()
    end
  end
end
