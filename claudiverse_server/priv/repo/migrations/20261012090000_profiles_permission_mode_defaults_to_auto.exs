defmodule ClaudiverseServer.Repo.Migrations.ProfilesPermissionModeDefaultsToAuto do
  @moduledoc """
  A new profile's permission mode defaults to `auto` (operator 2026-10-12:
  "default should be auto"). Existing rows keep the mode they have.

  SQLite cannot change a column's default in place (ecto_sqlite3 raises
  "ALTER COLUMN not supported"), so the table is rebuilt: the same columns,
  constraints and index, every row copied with its id, and the AUTOINCREMENT
  counter carried over, so an id once used is still never handed out again.
  Nothing references `profiles` by foreign key (`sessions.profile_id` is a
  plain integer), so dropping the old table touches no other table.
  """
  use Ecto.Migration

  def up, do: rebuild("auto")
  def down, do: rebuild("default")

  defp rebuild(mode) do
    execute("""
    CREATE TABLE "profiles_new" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "user_id" INTEGER NOT NULL CONSTRAINT "profiles_user_id_fkey" REFERENCES "users"("id") ON DELETE CASCADE, "name" TEXT NOT NULL, "revision" INTEGER DEFAULT 1 NOT NULL, "machine" TEXT NOT NULL, "folder" TEXT NOT NULL, "fleet" TEXT, "role" TEXT DEFAULT 'member' NOT NULL, "can_notify" INTEGER DEFAULT false NOT NULL, "runtime" TEXT DEFAULT 'stock+mod' NOT NULL, "model" TEXT, "effort" TEXT, "permission_mode" TEXT DEFAULT '#{mode}' NOT NULL, "mcp" TEXT DEFAULT ('[]') NOT NULL, "pooled" INTEGER DEFAULT false NOT NULL, "autostart" INTEGER DEFAULT false NOT NULL, "resume" TEXT DEFAULT 'latest' NOT NULL, "debug" INTEGER DEFAULT false NOT NULL, "last_start" TEXT, "inserted_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL)
    """)

    execute("""
    INSERT INTO "profiles_new" ("id", "user_id", "name", "revision", "machine", "folder", "fleet", "role", "can_notify", "runtime", "model", "effort", "permission_mode", "mcp", "pooled", "autostart", "resume", "debug", "last_start", "inserted_at", "updated_at")
    SELECT "id", "user_id", "name", "revision", "machine", "folder", "fleet", "role", "can_notify", "runtime", "model", "effort", "permission_mode", "mcp", "pooled", "autostart", "resume", "debug", "last_start", "inserted_at", "updated_at" FROM "profiles"
    """)

    # The counter, not just the highest id left: a deleted profile's id stays unused.
    execute(~s|DELETE FROM sqlite_sequence WHERE name = 'profiles_new'|)
    execute(~s|INSERT INTO sqlite_sequence (name, seq) SELECT 'profiles_new', seq FROM sqlite_sequence WHERE name = 'profiles'|)

    execute(~s|DROP TABLE "profiles"|)
    execute(~s|ALTER TABLE "profiles_new" RENAME TO "profiles"|)
    execute(~s|CREATE UNIQUE INDEX "profiles_user_id_name_index" ON "profiles" ("user_id", "name")|)
  end
end
