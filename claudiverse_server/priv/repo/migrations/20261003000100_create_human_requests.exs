defmodule ClaudiverseServer.Repo.Migrations.CreateHumanRequests do
  @moduledoc """
  A seat asking for the operator (cv_request_human); the app notifies on it
  and resolves it when the operator opens the seat. At most one OPEN request
  per session: asking again updates it.
  """
  use Ecto.Migration

  def change do
    create table(:human_requests) do
      add :session_id, references(:sessions, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :summary, :text, null: false
      add :detail, :text
      add :status, :string, null: false, default: "open"
      add :resolved_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:human_requests, [:session_id, :status])
    create index(:human_requests, [:user_id, :status])
  end
end
