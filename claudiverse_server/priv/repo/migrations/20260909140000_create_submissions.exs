defmodule ClaudiverseServer.Repo.Migrations.CreateSubmissions do
  @moduledoc """
  Component B — the submission pipeline.

  **A worker delivers a matched function by calling one MCP tool. It never
  touches git, never creates a branch, and needs no push access.**

  ⭐ The load-bearing property is that DURABILITY ARRIVES HERE — when the store
  accepts the submission — not when a git ref survives a reap. That is what
  stops the rescue-ref generator: measured on the M1, **538 remote-tracking
  refs · 153 rescue refs · 103 distinct tips · 84 reachable from no remote**,
  having doubled from 72 one window earlier. Those exist because the worker
  charter says "push anything kept to an eph/ branch" while also forbidding it;
  one tool call removes the contradiction rather than documenting around it.
  """
  use Ecto.Migration

  def change do
    create table(:kb_submissions) do
      # WHAT was matched. `address` is the durable identity — a name can be
      # renamed out from under this, and on 2026-09-05 exactly that broke
      # master's link.
      add :address, :string, null: false
      add :unit, :string
      add :build, :string, null: false
      add :tier, :string

      # WHERE it was derived. A submission gated against a stale base must be
      # re-gated at HEAD and judged on THAT, never on the submitted evidence.
      add :base_sha, :string
      add :compiler, :string
      add :flags, :string

      # ⛔ body_c is TEMPORARY. Storing it makes a submission self-contained and
      # replayable; keeping it after integration would put the C in two places,
      # which is the second-source-of-truth failure this whole plan exists to
      # avoid. After integration the repo is authoritative and only body_hash
      # remains.
      add :body_c, :text
      add :body_hash, :string, null: false

      add :notes, :text
      add :submitted_by, :string, null: false
      add :state, :string, null: false, default: "SUBMITTED"
      add :superseded_by, references(:kb_submissions, on_delete: :nilify_all)

      timestamps()
    end

    create index(:kb_submissions, [:address, :build])
    create index(:kb_submissions, [:state])
    create index(:kb_submissions, [:unit])
    create index(:kb_submissions, [:submitted_by])

    create table(:kb_submission_gates) do
      add :submission_id, references(:kb_submissions, on_delete: :delete_all), null: false
      add :gate_name, :string, null: false
      add :ran_at, :utc_datetime, null: false
      add :verdict, :string, null: false

      # ⛔ RAW OUTPUT, never a pass/fail flag. Every single-instrument gate in
      # this project has been observed lying, so the evidence must stay
      # re-readable after the fact — a boolean cannot be re-audited.
      add :raw_output, :text

      # ⭐ A COLUMN, not a note. "This gate could have failed on this run"
      # becomes QUERYABLE, so a gate that quietly stops being able to fail is
      # detectable instead of silently green. Two probes this project produced
      # could not have detected anything — one returned empty for every arm
      # because cc1.exe emits CRLF and the awk never matched; another scored 21
      # functions that were all already at 100%. Both would have been confident
      # wrong answers in an unattended pipeline.
      add :positive_control_output, :text

      add :runner, :string
      add :environment, :string

      timestamps()
    end

    create index(:kb_submission_gates, [:submission_id, :ran_at])
    create index(:kb_submission_gates, [:verdict])

    create table(:kb_integrations) do
      add :submission_id, references(:kb_submissions, on_delete: :delete_all), null: false
      add :integrated_sha, :string
      add :integrated_at, :utc_datetime
      add :integrated_by, :string

      # A wrong auto-merge must be reversible, and the reason must survive with
      # it — otherwise the only record of why something was reverted is in
      # whoever's memory reverted it.
      add :reverted_at, :utc_datetime
      add :revert_reason, :text

      timestamps()
    end

    create index(:kb_integrations, [:submission_id])
    create index(:kb_integrations, [:integrated_sha])
  end
end
