defmodule ClaudiverseServer.Repo.Migrations.CreateSeatStalls do
  @moduledoc """
  Auto-resume (ClaudiverseServer.AutoResume): one row per seat whose model
  calls pass the API proxy. It says whether a response is streaming to the
  seat now (a server restart cuts it), and whether the seat's last model call
  died on the pool or on a restart, until its `continue` is sent.
  """
  use Ecto.Migration

  def change do
    create table(:seat_stalls) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :seat_title, :string, null: false
      add :claude_session_id, :string
      add :in_flight, :boolean, null: false, default: false
      add :state, :string, null: false, default: "clear"
      add :reason, :string
      add :detail, :string
      add :stalled_at, :utc_datetime
      add :waiting, :string
      add :nudged_at, :utc_datetime
      add :nudged_session_id, :integer
      timestamps()
    end

    create unique_index(:seat_stalls, [:user_id, :seat_title])
    create index(:seat_stalls, [:state])
    create index(:seat_stalls, [:in_flight])
  end
end
