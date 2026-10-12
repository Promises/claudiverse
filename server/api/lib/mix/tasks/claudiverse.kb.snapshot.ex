defmodule Mix.Tasks.Claudiverse.Kb.Snapshot do
  @moduledoc """
  Take a consistent, verified point-in-time snapshot of the whole database.

      mix claudiverse.kb.snapshot [--out DIR] [--keep N]

  A thin CLI over `ClaudiverseServer.Knowledge.Backup`, which is where the
  logic and its reasoning live — the same code the scheduled custodian runs, so
  the manual and automatic paths cannot drift apart.
  """
  use Mix.Task

  alias ClaudiverseServer.Knowledge.Backup

  @shortdoc "Take and verify a VACUUM INTO snapshot of the database"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, strict: [out: :string, keep: :integer])
    dir = opts[:out] || Path.join(File.cwd!(), "snapshots")

    Mix.shell().info("source  : #{Backup.source_path()}")
    Mix.shell().info("journal : #{Backup.pragma("journal_mode")}  (WAL ⇒ a bare cp is unsafe)")
    Mix.shell().info("\nVACUUM INTO #{dir}/ ...")

    case Backup.snapshot(dir, keep: opts[:keep] || 7) do
      {:ok, i} ->
        Mix.shell().info("  wrote      : #{Backup.human(i.bytes)} in #{i.seconds}s")
        Mix.shell().info("  verified   : integrity ok, #{i.tables} tables, #{i.rows} rows equal")
        Mix.shell().info("  retention  : pruned #{i.pruned}")
        Mix.shell().info("\n✅ #{i.path}")

      {:error, why} ->
        Mix.raise(why)
    end
  end
end
