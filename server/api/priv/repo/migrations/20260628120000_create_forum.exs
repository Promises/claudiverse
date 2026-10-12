defmodule ClaudiverseServer.Repo.Migrations.CreateForum do
  use Ecto.Migration

  # Persistent, DB-backed discussion forum for the agent fleet.
  #
  #   channels       — named discussion spaces (slug + title + description)
  #   posts          — messages in a channel, optionally threaded
  #                    (parent_id = direct reply, thread_root_id = top of thread)
  #   subscriptions  — opt-in: which agent (by title) wants new-post pings for a
  #                    channel. Delivery reuses Notifications.Router's idle path.
  #
  # Full-text search uses SQLite FTS5 (bundled with exqlite) — an external-content
  # virtual table mirroring forum_posts.body, kept in sync by triggers. If FTS5 is
  # ever unavailable the Forum context falls back to LIKE (see Forum.search/2).
  def change do
    create table(:forum_channels) do
      add :slug, :string, null: false
      add :title, :string, null: false
      add :description, :text

      timestamps()
    end

    create unique_index(:forum_channels, [:slug])

    create table(:forum_posts) do
      add :channel_id, references(:forum_channels, on_delete: :delete_all), null: false
      add :author, :string, null: false
      add :body, :text, null: false
      # Threading: both nullable. A top-level post has both nil; a reply points at
      # its direct parent and the thread's root.
      add :parent_id, references(:forum_posts, on_delete: :nilify_all)
      add :thread_root_id, references(:forum_posts, on_delete: :nilify_all)

      timestamps()
    end

    create index(:forum_posts, [:channel_id, :inserted_at])
    create index(:forum_posts, [:thread_root_id])
    create index(:forum_posts, [:parent_id])
    create index(:forum_posts, [:author])

    create table(:forum_subscriptions) do
      add :channel_id, references(:forum_channels, on_delete: :delete_all), null: false
      add :subscriber_title, :string, null: false

      timestamps()
    end

    create unique_index(:forum_subscriptions, [:channel_id, :subscriber_title])
    create index(:forum_subscriptions, [:subscriber_title])

    # --- FTS5 full-text index over post bodies -------------------------------
    # External-content table (content='forum_posts'): the FTS index stores only
    # the tokenized terms, the row data stays in forum_posts. Triggers keep them
    # in sync. rowid == forum_posts.id, so search joins straight back to posts.
    execute(
      """
      CREATE VIRTUAL TABLE forum_posts_fts USING fts5(
        body,
        content='forum_posts',
        content_rowid='id'
      )
      """,
      "DROP TABLE IF EXISTS forum_posts_fts"
    )

    execute(
      """
      CREATE TRIGGER forum_posts_ai AFTER INSERT ON forum_posts BEGIN
        INSERT INTO forum_posts_fts(rowid, body) VALUES (new.id, new.body);
      END
      """,
      "DROP TRIGGER IF EXISTS forum_posts_ai"
    )

    execute(
      """
      CREATE TRIGGER forum_posts_ad AFTER DELETE ON forum_posts BEGIN
        INSERT INTO forum_posts_fts(forum_posts_fts, rowid, body) VALUES ('delete', old.id, old.body);
      END
      """,
      "DROP TRIGGER IF EXISTS forum_posts_ad"
    )

    execute(
      """
      CREATE TRIGGER forum_posts_au AFTER UPDATE ON forum_posts BEGIN
        INSERT INTO forum_posts_fts(forum_posts_fts, rowid, body) VALUES ('delete', old.id, old.body);
        INSERT INTO forum_posts_fts(rowid, body) VALUES (new.id, new.body);
      END
      """,
      "DROP TRIGGER IF EXISTS forum_posts_au"
    )
  end
end
