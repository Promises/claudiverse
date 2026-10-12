defmodule ClaudiverseServer.Knowledge.Backup do
  @moduledoc """
  Snapshot, verify and prune the database. Plain functions returning
  `{:ok, info}` / `{:error, reason}` — no `Mix.*`.

  This lives outside the Mix task deliberately. The scheduled custodian runs
  inside the supervision tree, where `Mix.raise` is both unavailable in a
  release and wrong in kind: a failed backup must be reported, not thrown at a
  supervisor that will cheerfully restart and try again.

  ## What "verified" means here

  A snapshot counts only once it has been REOPENED and shown to be usable:

    * `PRAGMA integrity_check`
    * a row count of EVERY table, compared against the source

  ⭐ A file of plausible size proves nothing. That is exactly how backups turn
  out to be empty on the day they are needed. A snapshot failing either check
  is DELETED — a bad snapshot sitting among good ones is worse than none,
  because the listing still looks healthy while its newest entry is broken.
  """

  alias ClaudiverseServer.Repo
  alias Exqlite.Sqlite3

  require Logger

  @name_re ~r/^claudiverse-\d{8}-\d{6}\.db$/

  @doc """
  Take a verified snapshot into `dir`. Returns `{:ok, info}` or `{:error, reason}`.
  """
  def snapshot(dir, opts \\ []) do
    keep = Keyword.get(opts, :keep, 7)
    File.mkdir_p!(dir)

    dest = Path.join(dir, "claudiverse-#{stamp()}.db")

    cond do
      keep < 1 ->
        {:error, "--keep must be at least 1 (got #{keep})"}

      File.exists?(dest) ->
        {:error, "#{dest} already exists"}

      true ->
        expected = table_counts()
        src_bytes = File.stat!(source_path()).size

        # VACUUM INTO runs in a read transaction and writes exactly the
        # committed state at its start, without blocking writers. A bare `cp`
        # is not atomic and, under WAL, misses the committed tail in -wal.
        {us, _} = :timer.tc(fn -> Repo.query!("VACUUM INTO ?", [dest]) end)

        case verify(dest, expected) do
          :ok ->
            {:ok, pruned} = prune(dir, keep)

            {:ok,
             %{
               path: dest,
               seconds: Float.round(us / 1_000_000, 1),
               source_bytes: src_bytes,
               bytes: File.stat!(dest).size,
               tables: map_size(expected),
               rows: expected |> Map.values() |> Enum.sum(),
               pruned: pruned,
               journal_mode: pragma("journal_mode")
             }}

          {:error, why} ->
            {:error, why}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Reopen a snapshot and prove it is usable. Deletes it if it is not.

  Returns `:ok` or `{:error, reason}`.
  """
  def verify(path, expected_counts) do
    case Sqlite3.open(path, mode: :readonly) do
      {:ok, conn} -> do_verify(conn, path, expected_counts)
      {:error, msg} -> reject(nil, path, "cannot open: #{msg}")
    end
  end

  defp do_verify(conn, path, expected) do
    with :ok <- check_integrity(conn, path),
         :ok <- check_counts(conn, path, expected) do
      Sqlite3.close(conn)
      :ok
    end
  end

  defp check_integrity(conn, path) do
    case one(conn, "PRAGMA integrity_check") do
      {:ok, "ok"} -> :ok
      {:ok, bad} -> reject(conn, path, "integrity_check returned #{inspect(bad)}")
      {:error, msg} -> reject(conn, path, "integrity_check failed: #{msg}")
    end
  end

  defp check_counts(conn, path, expected) do
    # EVERY table, not a sample: a snapshot can be internally consistent and
    # still be missing a whole table's rows. An UNREADABLE table is a mismatch,
    # not an exception — letting the error escape would skip the delete below,
    # so the largest possible loss would leave its file on disk.
    mismatched =
      for {table, want} <- expected, result = count(conn, table), result != {:ok, want} do
        case result do
          {:ok, got} -> "#{table}: #{want} -> #{got}"
          {:error, msg} -> "#{table}: UNREADABLE (#{msg})"
        end
      end

    if mismatched == [],
      do: :ok,
      else: reject(conn, path, "row counts differ (#{Enum.join(mismatched, "; ")})")
  end

  # A rejected snapshot is DELETED, so a directory listing never presents a
  # broken file as the newest good one.
  defp reject(conn, path, why) do
    if conn, do: Sqlite3.close(conn)
    File.rm(path)
    {:error, "SNAPSHOT REJECTED and deleted: #{why}"}
  end

  @doc """
  Delete all but the newest `keep` snapshots. Only ever removes files matching
  this module's own naming — a sweep that widens its pattern eats the
  operator's own backups, and the only evidence afterwards is their absence.
  """
  def prune(_dir, keep) when keep < 1 do
    # Enum.drop(files, -0) is Enum.drop(files, 0) — the WHOLE list. Unguarded,
    # `keep: 0` deletes the snapshot just verified, seconds after calling it
    # healthy.
    {:error, "keep must be at least 1 (got #{keep})"}
  end

  def prune(dir, keep) do
    files = dir |> File.ls!() |> Enum.filter(&Regex.match?(@name_re, &1)) |> Enum.sort()
    stale = Enum.drop(files, -keep)
    for f <- stale, do: File.rm!(Path.join(dir, f))
    {:ok, length(stale)}
  end

  @doc "Row counts for every real table, keyed by name."
  def table_counts do
    for [t] <- q("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"),
        # FTS5 shadow tables are maintained BY the virtual table; counting them
        # directly is meaningless and some are not selectable at all.
        not String.match?(t, ~r/_(data|idx|docsize|config|content)$/),
        into: %{} do
      [[n]] = q("SELECT count(*) FROM \"#{t}\"")
      {t, n}
    end
  end

  def source_path, do: Repo.config()[:database] |> Path.expand()

  def pragma(name) do
    [[v]] = q("PRAGMA #{name}")
    v
  end

  def newest_snapshot(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files |> Enum.filter(&Regex.match?(@name_re, &1)) |> Enum.sort() |> List.last()

      _ ->
        nil
    end
  end

  def human(b) when b > 1_073_741_824, do: "#{Float.round(b / 1_073_741_824, 2)} GB"
  def human(b) when b > 1_048_576, do: "#{Float.round(b / 1_048_576, 1)} MB"
  def human(b), do: "#{b} B"

  # ── low-level ──────────────────────────────────────────────────────────────

  defp q(sql), do: Repo.query!(sql).rows

  defp one(conn, sql) do
    with {:ok, stmt} <- Sqlite3.prepare(conn, sql),
         {:row, [v]} <- Sqlite3.step(conn, stmt) do
      Sqlite3.release(conn, stmt)
      {:ok, v}
    else
      {:error, msg} -> {:error, msg}
      other -> {:error, inspect(other)}
    end
  end

  # Never raises: a table that cannot be read is a finding to report, not a
  # crash that skips cleanup.
  defp count(conn, table), do: one(conn, "SELECT count(*) FROM \"#{table}\"")

  defp stamp do
    {{y, mo, d}, {h, mi, s}} = :calendar.local_time()
    :io_lib.format("~4..0B~2..0B~2..0B-~2..0B~2..0B~2..0B", [y, mo, d, h, mi, s])
    |> List.to_string()
  end
end
