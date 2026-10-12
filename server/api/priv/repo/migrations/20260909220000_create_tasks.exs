defmodule ClaudiverseServer.Repo.Migrations.CreateTasks do
  @moduledoc """
  Component E — the task system.

  The queue MECHANIC is sound and is preserved unchanged: atomic claim, one
  worker per task, reap on exactly one signal. What this replaces is the thin
  STATE around them, which is convention-on-forum-posts.

  Each column below kills a MEASURED defect, not a hypothetical one.
  """
  use Ecto.Migration

  def change do
    create table(:tasks) do
      add :fleet, :string, null: false
      # Channel stays as LANE — routing to a slot class (lorem-tasks vs
      # lorem-tasks-deep vs lorem-analysis). It stops carrying PRIORITY.
      add :lane, :string, null: false
      add :title, :string, null: false
      add :body_md, :text

      # ⛔ E-1. `state` is NOT NULL with a default, and READY is the only
      # claimable value. Today a post created without status=incoming is
      # invisible to the claim query and fails SILENTLY — a defect documented in
      # FIVE channel descriptions, which makes it a schema gap, not a usage
      # error. Here, creating an unclaimable task is impossible rather than
      # warned about.
      add :state, :string, null: false, default: "DRAFT"

      # ⭐ E-2, at the cause. Priority had no field, so it was expressed as
      # PROSE IN A BODY — and prose can redirect a worker away from the task the
      # runner is tracking. #22557's body said "TAKE #22445 FIRST"; the worker
      # complied and called cv_task_done on #22445 while the runner waited on
      # #22557 for a signal that could never arrive. One slot, ~1h, freed only
      # by a hand tmux kill-session.
      add :priority, :integer, null: false, default: 0

      add :claimed_by, :string
      add :claimed_at, :utc_datetime
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime

      # E-5. Linkage was title convention ("VALIDATE #21672"), so tracing one
      # result meant hand-walking #22585 -> #22443 -> #22538 -> #22726 -> #22771.
      add :validates_task_id, references(:tasks, on_delete: :nilify_all)
      add :superseded_by, references(:tasks, on_delete: :nilify_all)

      # The single-owner colima VM. Today workers hand-check
      # `docker --context colima-ee-x86 ps` and yield by convention.
      add :vm_required, :boolean, null: false, default: false

      add :created_by, :string, null: false
      timestamps()
    end

    # The claim query's index: highest-priority READY task in a lane.
    create index(:tasks, [:fleet, :lane, :state, :priority])
    create index(:tasks, [:claimed_by])
    create index(:tasks, [:validates_task_id])

    create table(:task_deps) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :depends_on_task_id, references(:tasks, on_delete: :delete_all), null: false
      # BLOCKS: the task cannot become READY until the dependency is DONE.
      # INFORMS: advisory only — recorded so the graph is complete.
      add :kind, :string, null: false, default: "BLOCKS"
      timestamps()
    end

    create unique_index(:task_deps, [:task_id, :depends_on_task_id])
    create index(:task_deps, [:depends_on_task_id])

    create table(:task_events) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :at, :utc_datetime, null: false
      add :kind, :string, null: false
      add :actor, :string
      add :detail, :text
      timestamps()
    end

    create index(:task_events, [:task_id, :at])
    create index(:task_events, [:kind, :at])
  end
end
