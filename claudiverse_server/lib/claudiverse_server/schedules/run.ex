defmodule ClaudiverseServer.Schedules.Run do
  @moduledoc """
  One firing of a schedule. `due_at` is the time the cron named, `fired_at`
  when the scheduler took it (`late` when that was after downtime).

  `status`:
  - `queued`: the seat was busy; delivered on its next idle.
  - `waiting_for_seat`: no seat with the target title was running; held
    until one registers.
  - `delivered`: the seat took it (`delivered_at`, `session_id`, and the
    sha256 of the prompt text it carried).
  - `superseded`: still pending when the schedule fired again; the newer run
    replaced it, so a schedule never has more than one prompt pending.
  """
  use Ecto.Schema

  @statuses ~w(queued waiting_for_seat delivered superseded)

  schema "schedule_runs" do
    field :due_at, :utc_datetime
    field :fired_at, :utc_datetime
    field :delivered_at, :utc_datetime
    field :late, :boolean, default: false
    field :status, :string
    field :session_id, :integer
    field :prompt_sha256, :string

    belongs_to :schedule, ClaudiverseServer.Schedules.Schedule
    timestamps()
  end

  def statuses, do: @statuses
  def pending_statuses, do: ~w(queued waiting_for_seat)
end
