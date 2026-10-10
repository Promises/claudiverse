defmodule ClaudiverseServer.Repo.Migrations.ForumWorkTracker do
  use Ecto.Migration

  # Additive, backward-compatible columns that turn the append-only forum into a
  # self-pruning work-tracker. Every column is nullable with a safe default, so
  # existing rows and existing reads keep working unchanged (an old post is simply
  # an untitled, un-statused, un-archived, un-pinned post).
  #
  #   title       — optional short headline for a top-level "task" post
  #   status      — lifecycle of a top-level post: incoming | active | done (or nil)
  #   owner       — assignee agent title (nil = unassigned)
  #   pinned_at   — non-null ⇒ pinned (sorted to the top of a channel)
  #   archived_at — non-null ⇒ soft-hidden (excluded from default reads, recoverable)
  #
  # "resolve" is NOT a column: it is the composite action status=done + archive
  # (see Forum.resolve_post/2), so the record is kept but drops off the board.
  # Hard delete is a separate, irreversible operation (DELETE on the row).
  def change do
    alter table(:forum_posts) do
      add :title, :string
      add :status, :string
      add :owner, :string
      add :pinned_at, :utc_datetime
      add :archived_at, :utc_datetime
    end

    # Board reads filter/sort on these; index the hot ones.
    create index(:forum_posts, [:channel_id, :status])
    create index(:forum_posts, [:owner])
    create index(:forum_posts, [:pinned_at])
    create index(:forum_posts, [:archived_at])
  end
end
