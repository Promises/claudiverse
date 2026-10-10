defmodule ClaudiverseServer.KbSnapshotTest do
  @moduledoc """
  The backup verifier's REJECTION paths.

  A verifier only ever seen to pass is indistinguishable from one that returns
  `:ok` unconditionally. These tests exist to show it says NO — and that it
  deletes the bad file rather than leaving it to head a directory listing that
  then looks healthy.

  ⚠️ SCOPE BOUND: these exercise `verify/2` and `prune/2`, not `VACUUM INTO`.
  Ecto's sandbox wraps each test in a transaction and SQLite refuses to VACUUM
  inside one, so the databases here are built directly with Exqlite. The VACUUM
  path was verified end to end against a 4.44 GB copy of the live database
  (8.1s, integrity ok, 13 tables / 8,726,698 rows equal) — by hand, not here.
  """
  use ExUnit.Case, async: false

  alias ClaudiverseServer.Knowledge.Backup
  alias Exqlite.Sqlite3

  setup do
    dir = Path.join(System.tmp_dir!(), "kbsnap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # Enough rows to span many pages, so corrupting an interior page damages real
  # content rather than slack space.
  defp build_db(path, rows) do
    {:ok, c} = Sqlite3.open(path)
    :ok = Sqlite3.execute(c, "PRAGMA journal_mode=DELETE")
    :ok = Sqlite3.execute(c, "CREATE TABLE t (id INTEGER PRIMARY KEY, body TEXT)")
    :ok = Sqlite3.execute(c, "BEGIN")
    {:ok, stmt} = Sqlite3.prepare(c, "INSERT INTO t (body) VALUES (?)")

    for i <- 1..rows do
      :ok = Sqlite3.bind(stmt, ["row #{i} " <> String.duplicate("x", 200)])
      :done = Sqlite3.step(c, stmt)
    end

    :ok = Sqlite3.release(c, stmt)
    :ok = Sqlite3.execute(c, "COMMIT")
    :ok = Sqlite3.close(c)
    path
  end

  describe "verify" do
    test "a healthy snapshot passes — and the check is not vacuous", %{dir: dir} do
      path = build_db(Path.join(dir, "good.db"), 2_000)

      # An empty expectation map would make the comparison succeed on ANY file,
      # including an empty one. Assert the check has something to compare.
      counts = %{"t" => 2_000}
      assert map_size(counts) > 0

      assert :ok == Backup.verify(path, counts)
      assert File.exists?(path)
    end

    test "REJECTS a structurally corrupt snapshot, and DELETES it", %{dir: dir} do
      path = build_db(Path.join(dir, "corrupt.db"), 2_000)

      # Scribble over interior pages, header intact. This is the dangerous
      # shape: the file still OPENS and sizes plausibly, so the usual
      # existence-and-size checks pass it.
      fd = File.open!(path, [:read, :write, :binary])
      {:ok, _} = :file.position(fd, 8_192)
      IO.binwrite(fd, :binary.copy(<<0xFF>>, 60_000))
      File.close(fd)

      assert File.exists?(path)

      assert {:error, msg} = Backup.verify(path, %{"t" => 2_000})
      assert msg =~ "REJECTED"
      refute File.exists?(path), "a rejected snapshot must not survive to head a listing"
    end

    test "REJECTS a snapshot that is intact but INCOMPLETE", %{dir: dir} do
      path = build_db(Path.join(dir, "short.db"), 2_000)

      # A file can pass integrity_check and still be missing rows: a restore
      # from it succeeds and silently loses data. That is the failure
      # integrity_check cannot see, which is why the row comparison exists.
      assert {:error, msg} = Backup.verify(path, %{"t" => 2_001})
      assert msg =~ "row counts differ"
      assert msg =~ "t: 2001 -> 2000"
      refute File.exists?(path)
    end

    test "a MISSING table is a rejection, not an escaping exception", %{dir: dir} do
      path = build_db(Path.join(dir, "missing.db"), 100)

      # Swallowing this would accept a snapshot missing an entire table — the
      # largest possible loss, reported as success. Letting it escape as a raw
      # error is nearly as bad: it skips the delete, so the broken file stays.
      assert {:error, msg} = Backup.verify(path, %{"t" => 100, "kb_documents" => 5})
      assert msg =~ "kb_documents"
      assert msg =~ "UNREADABLE"
      refute File.exists?(path), "an unreadable table must delete the snapshot too"
    end
  end

  describe "retention" do
    test "prunes oldest-first and NEVER touches a file it did not create", %{dir: dir} do
      mine = ~w(
        claudiverse-20260101-000000.db
        claudiverse-20260202-000000.db
        claudiverse-20260908-230628.db
        claudiverse-20260908-230857.db
      )

      # ⭐ Files that must SURVIVE. A sweep that widens its pattern deletes the
      # operator's own backups, and the only evidence afterwards is their
      # absence — nothing logs what a glob did not intend to match.
      foreign = ~w(IMPORTANT-do-not-delete.db claudiverse-manual.db notes.md claudiverse-2026.db)

      for f <- mine ++ foreign, do: File.touch!(Path.join(dir, f))

      assert {:ok, 2} = Backup.prune(dir, 2)

      assert Enum.sort(File.ls!(dir)) ==
               Enum.sort(
                 ["claudiverse-20260908-230628.db", "claudiverse-20260908-230857.db"] ++ foreign
               )
    end

    test "REFUSES keep < 1 rather than deleting everything", %{dir: dir} do
      File.touch!(Path.join(dir, "claudiverse-20260101-000000.db"))

      # Enum.drop(files, -0) drops nothing from the front and returns the whole
      # list, so an unguarded prune deletes the snapshot it just verified.
      assert {:error, msg} = Backup.prune(dir, 0)
      assert msg =~ "keep must be at least 1"
      assert File.ls!(dir) == ["claudiverse-20260101-000000.db"]
    end

    test "keeping more than exist deletes nothing", %{dir: dir} do
      for f <- ~w(claudiverse-20260101-000000.db claudiverse-20260202-000000.db),
          do: File.touch!(Path.join(dir, f))

      assert {:ok, 0} = Backup.prune(dir, 7)
      assert length(File.ls!(dir)) == 2
    end

    test "newest_snapshot ignores foreign files", %{dir: dir} do
      for f <- ~w(claudiverse-20260101-000000.db claudiverse-20260202-000000.db zzz-newer.db),
          do: File.touch!(Path.join(dir, f))

      assert Backup.newest_snapshot(dir) == "claudiverse-20260202-000000.db"
    end
  end
end
