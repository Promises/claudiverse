defmodule ClaudiverseServer.Repo.Migrations.CreateSchedules do
  @moduledoc """
  Scheduled prompts (ClaudiverseServer.Schedules): a cron in an IANA zone that
  delivers a stored prompt to a seat, and one run row per firing.
  """
  use Ecto.Migration

  def change do
    create table(:schedules) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :target_title, :string, null: false
      add :cron, :string, null: false
      add :tz, :string, null: false
      add :prompt, :text, null: false
      add :enabled, :boolean, null: false, default: true
      add :created_by, :string, null: false
      add :next_fire_at, :utc_datetime
      add :last_fired_at, :utc_datetime
      timestamps()
    end

    create unique_index(:schedules, [:user_id, :name])
    create index(:schedules, [:enabled, :next_fire_at])
    create index(:schedules, [:user_id, :target_title])

    create table(:schedule_runs) do
      add :schedule_id, references(:schedules, on_delete: :delete_all), null: false
      add :due_at, :utc_datetime, null: false
      add :fired_at, :utc_datetime, null: false
      add :delivered_at, :utc_datetime
      add :late, :boolean, null: false, default: false
      add :status, :string, null: false
      add :session_id, :integer
      # The sha256 (hex) of the prompt text the run delivered.
      add :prompt_sha256, :string
      timestamps()
    end

    create index(:schedule_runs, [:schedule_id, :due_at])
    create index(:schedule_runs, [:status])
  end
end
