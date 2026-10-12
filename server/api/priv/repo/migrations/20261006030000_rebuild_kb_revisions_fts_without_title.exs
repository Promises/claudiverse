defmodule ClaudiverseServer.Repo.Migrations.RebuildKbRevisionsFtsWithoutTitle do
  @moduledoc """
  kb_revisions_fts was declared fts5(body_md, title, content='kb_revisions'),
  but kb_revisions has no `title` column. FTS5 reads an external-content
  table's columns BY NAME whenever it needs the text back, so every content
  read failed with "no such column: T.title": a full scan, snippet/highlight,
  the 'integrity-check' command, and 'rebuild'. MATCH + rank never read the
  content, which is why search kept working and nothing noticed (measured on
  prod 2026-10-06; the index itself was complete, 9,746 of 9,746 revisions).

  The title column was always written as '' (titles live in kb_documents and
  are matched by Knowledge.title_matches/3 instead), so dropping it loses
  nothing. Recreate the index on body_md alone, recreate the triggers, and
  rebuild it from the content table, which is now possible.
  """
  use Ecto.Migration

  def up do
    execute("DROP TRIGGER IF EXISTS kb_revisions_ai")
    execute("DROP TRIGGER IF EXISTS kb_revisions_ad")
    execute("DROP TABLE IF EXISTS kb_revisions_fts")

    execute("""
    CREATE VIRTUAL TABLE kb_revisions_fts USING fts5(
      body_md,
      content='kb_revisions',
      content_rowid='id'
    )
    """)

    execute("""
    CREATE TRIGGER kb_revisions_ai AFTER INSERT ON kb_revisions BEGIN
      INSERT INTO kb_revisions_fts(rowid, body_md) VALUES (new.id, new.body_md);
    END
    """)

    execute("""
    CREATE TRIGGER kb_revisions_ad AFTER DELETE ON kb_revisions BEGIN
      INSERT INTO kb_revisions_fts(kb_revisions_fts, rowid, body_md) VALUES ('delete', old.id, old.body_md);
    END
    """)

    execute("INSERT INTO kb_revisions_fts(kb_revisions_fts) VALUES ('rebuild')")
  end

  # Back to the original (broken) shape, rebuilt by re-inserting every row,
  # since 'rebuild' is exactly what that shape cannot do.
  def down do
    execute("DROP TRIGGER IF EXISTS kb_revisions_ai")
    execute("DROP TRIGGER IF EXISTS kb_revisions_ad")
    execute("DROP TABLE IF EXISTS kb_revisions_fts")

    execute("""
    CREATE VIRTUAL TABLE kb_revisions_fts USING fts5(
      body_md,
      title,
      content='kb_revisions',
      content_rowid='id'
    )
    """)

    execute("""
    CREATE TRIGGER kb_revisions_ai AFTER INSERT ON kb_revisions BEGIN
      INSERT INTO kb_revisions_fts(rowid, body_md, title) VALUES (new.id, new.body_md, '');
    END
    """)

    execute("""
    CREATE TRIGGER kb_revisions_ad AFTER DELETE ON kb_revisions BEGIN
      INSERT INTO kb_revisions_fts(kb_revisions_fts, rowid, body_md, title) VALUES ('delete', old.id, old.body_md, '');
    END
    """)

    execute("INSERT INTO kb_revisions_fts(rowid, body_md, title) SELECT id, body_md, '' FROM kb_revisions")
  end
end
