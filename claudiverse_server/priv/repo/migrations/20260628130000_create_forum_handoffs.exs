defmodule ClaudiverseServer.Repo.Migrations.CreateForumHandoffs do
  use Ecto.Migration

  # Per-agent HANDOFF / continuity state.
  #
  #   forum_handoffs          — ONE canonical current-state per agent role
  #                             (unique `role`, upserted by `Forum.set_handoff/3`).
  #                             A successor reads this ONE authoritative note on
  #                             takeover — it never reconstructs state from a scroll.
  #   forum_handoff_versions  — cheap append-only history: every set snapshots the
  #                             new body + version, so an earlier state is
  #                             recoverable. Fits the forum's searchable-history
  #                             ethos; fully decoupled from the notify path.
  #
  # IMPORTANT: handoffs are PULL-ONLY. There is deliberately NO subscription /
  # Notifications.Router involvement here — updating a handoff pings nobody. A
  # successor reads on takeover; nobody is ever alerted about someone else's
  # handoff.
  def change do
    create table(:forum_handoffs) do
      # role == the agent's title (orchestrator, decomper, tester, watcher, ...).
      add :role, :string, null: false
      add :body, :text, null: false
      # Monotonic per-role version, bumped on each upsert (== count of sets).
      add :version, :integer, null: false, default: 1

      timestamps()
    end

    create unique_index(:forum_handoffs, [:role])

    create table(:forum_handoff_versions) do
      add :role, :string, null: false
      add :body, :text, null: false
      add :version, :integer, null: false

      timestamps(updated_at: false)
    end

    create index(:forum_handoff_versions, [:role, :version])
  end
end
