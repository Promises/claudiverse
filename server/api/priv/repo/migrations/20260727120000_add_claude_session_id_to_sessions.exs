defmodule ClaudiverseServer.Repo.Migrations.AddClaudeSessionIdToSessions do
  use Ecto.Migration

  # Claude Code's OWN session UUID, reported by the sidecar on connect.
  #
  # Without it the server cannot tell a RECONNECTING session from a brand-new
  # one, so every launch/blip inserted a fresh row — ~38k rows accumulated and
  # cv_list grew to a 1-3.5MB payload. Worse, stale rows kept the same title,
  # so title-resolution could wake a zombie.
  #
  # Nullable on purpose: rows created by older sidecars (and `spawned`
  # sessions, which have no Claude UUID) simply keep NULL and fall back to the
  # previous insert-always behaviour. No backfill, no downtime.
  def change do
    alter table(:sessions) do
      add :claude_session_id, :string
    end

    # Partial index: one live row per (user, claude session). NULLs are excluded
    # so legacy/spawned rows are unaffected by the constraint.
    create index(:sessions, [:user_id, :claude_session_id],
             where: "claude_session_id IS NOT NULL",
             name: :sessions_user_claude_session_id_index
           )
  end
end
