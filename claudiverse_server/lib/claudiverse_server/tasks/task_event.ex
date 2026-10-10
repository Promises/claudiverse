defmodule ClaudiverseServer.Tasks.TaskEvent do
  @moduledoc """
  The audit trail. Today this exists only as ephemeral tmux scrollback, so a
  strand leaves no record anywhere once the pane scrolls.

  The four emitted conditions (STARVED, STRANDED, STALLED, DRIFTED) are the
  watcher sweep promoted from a human ritual to a query — between 2026-09-05
  and 09-08 that sweep ran roughly 40 times by hand and caught exactly these.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(
    CREATED READY CLAIMED STARTED PROGRESS DONE VALIDATED
    RELEASED STRANDED STARVED STALLED DRIFTED REAPED SUPERSEDED EDITED DEP_ADDED
  )
  def kinds, do: @kinds

  @doc "Conditions the fleet should be notified about, not just logged."
  def alert_kinds, do: ~w(STRANDED STARVED STALLED DRIFTED)

  schema "task_events" do
    field :at, :utc_datetime
    field :kind, :string
    field :actor, :string
    field :detail, :string
    belongs_to :task, ClaudiverseServer.Tasks.Task
    timestamps()
  end

  def changeset(ev, attrs) do
    ev
    |> cast(attrs, [:task_id, :at, :kind, :actor, :detail])
    |> validate_required([:task_id, :at, :kind])
    |> validate_inclusion(:kind, @kinds)
  end
end
