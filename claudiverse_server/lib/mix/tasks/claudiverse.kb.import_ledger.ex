defmodule Mix.Tasks.Claudiverse.Kb.ImportLedger do
  @moduledoc """
  Import `#ledger-proto2` forum posts into the knowledge store.

      mix claudiverse.kb.import_ledger [--dry-run] [--channel SLUG] [--limit N]

  ⛔ `--dry-run` first, always. It classifies every post and reports the counts
  and every rejection WITHOUT writing, so the shape of the import is known
  before it happens rather than discovered afterwards.

  A thin CLI over `ClaudiverseServer.Knowledge.LedgerImport.run/1`, which is
  also what production calls via `bin/claudiverse_server rpc` — a release has
  no `mix`, and a second code path would be a second thing to get wrong.
  """
  use Mix.Task

  alias ClaudiverseServer.Knowledge.LedgerImport

  @shortdoc "Import the ledger channel into the knowledge store"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args, strict: [dry_run: :boolean, channel: :string, limit: :integer])

    case LedgerImport.run(Keyword.take(opts, [:dry_run, :channel, :limit])) do
      {:error, why} -> Mix.raise(why)
      report -> print(report)
    end
  end

  defp print(r) do
    Mix.shell().info("#{r.channel}: #{r.posts} post(s)#{if r[:dry_run], do: "  [DRY RUN]"}\n")

    for k <- [:fact, :correction, :skip, :reject] do
      Mix.shell().info("  #{String.pad_trailing(to_string(k), 12)} #{Map.get(r.counts, k, 0)}")
    end

    # ⚠️ EVERY rejection, not a sample. A migration that summarises its failures
    # as "N rejected" is one where nobody ever looks at the N.
    if r.rejects != [] do
      Mix.shell().info("\n⚠️ REJECTED (looked like a FACT, could not be stored):")
      for %{id: id, why: why, title: t} <- r.rejects do
        Mix.shell().info("  ##{id}  #{why}\n      #{String.slice(t || "", 0, 90)}")
      end
    end

    if r[:dry_run] do
      Mix.shell().info("\nDRY RUN — nothing written. Re-run without --dry-run to import.")
    else
      Mix.shell().info(
        "\n  facts: #{r.facts_inserted} inserted, #{r.facts_already_present} already present, " <>
          "#{length(r.fact_failures)} failed"
      )

      Mix.shell().info("  correction docs: #{r.correction_docs}")
      Mix.shell().info("  edges: #{r.edges_wired} wired, #{length(r.edge_failures)} failed")

      # Grouped BY REASON: 1,064 identical failures and 1,064 different ones
      # need different responses, and a bare count cannot tell them apart.
      r.edge_failures
      |> Enum.group_by(& String.slice(&1.why, 0, 60))
      |> Enum.sort_by(fn {_w, l} -> -length(l) end)
      |> Enum.each(fn {why, l} ->
        Mix.shell().info("    #{length(l)}x  #{why}   (e.g. ##{hd(l).id})")
      end)

      Mix.shell().info("\n✅ import complete. Source posts untouched.")
    end
  end
end
