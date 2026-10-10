defmodule Mix.Tasks.Claudiverse.Kb.Restore do
  @moduledoc """
  Rebuild the knowledge store from an exported mirror.

      mix claudiverse.kb.restore /path/to/mirror [--force]

  This is the half that makes the mirror a backup rather than a copy. Until it
  existed, `verify_mirror` could only prove the mirror MATCHED the store — never
  that the store could be rebuilt from it.

  ## Safety

  ⛔ REFUSES to run when `kb_documents` is non-empty, unless `--force`. A restore
  over live data is destructive and must be deliberate, not a mistyped path.

  IDs are preserved verbatim. Relations, anchors and `current_revision_id` all
  reference by id, so remapping them would silently rewire corrections — a
  RETRACTS pointing at the wrong claim is worse than a failed restore.

  Insert order follows the foreign keys: documents (without `current_revision_id`)
  → revisions → back-fill `current_revision_id` → anchors → joins → relations →
  symbols. The back-fill is a separate pass because a document and its current
  revision reference each other.
  """
  use Mix.Task
  alias ClaudiverseServer.Repo

  @shortdoc "Rebuild the knowledge store from an exported mirror"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    {opts, rest, _} = OptionParser.parse(args, strict: [force: :boolean])
    dir = List.first(rest) || Mix.raise("usage: mix claudiverse.kb.restore <dir> [--force]")

    existing = Repo.aggregate(ClaudiverseServer.Knowledge.Document, :count)

    # `!` not `not`: opts[:force] is nil when the flag is absent, and Elixir's
    # `not` raises ArgumentError on a non-boolean — which aborted with "argument
    # error" instead of the explanatory refusal. Caught by the safety test.
    if existing > 0 and !opts[:force] do
      Mix.raise("""
      REFUSING: kb_documents already holds #{existing} row(s).
      A restore over live data is destructive. Pass --force only if you mean it.
      """)
    end

    m = Path.join(dir, "manifest.json") |> File.read!() |> Jason.decode!()

    Repo.transaction(fn ->
      # documents first, WITHOUT current_revision_id — it points at a revision
      # that does not exist yet.
      for d <- m["documents"] do
        ins("kb_documents", Map.drop(d, ["current_revision_id"]))
      end

      for r <- m["revisions"], do: ins("kb_revisions", r)

      # second pass: now the revisions exist, wire each document to its current
      for d <- m["documents"], not is_nil(d["current_revision_id"]) do
        Repo.query!("UPDATE kb_documents SET current_revision_id = ?1 WHERE id = ?2", [
          d["current_revision_id"],
          d["id"]
        ])
      end

      for a <- m["anchors"], do: ins("kb_anchors", a)
      for da <- m["doc_anchors"], do: ins("kb_doc_anchors", da)
      for rel <- m["relations"], do: ins("kb_relations", rel)
      for s <- m["symbols"], do: ins("kb_symbols", s)
    end)

    Mix.shell().info("restored from #{dir}: #{inspect(m["counts"])}")
  end

  defp ins(table, row) do
    cols = Map.keys(row)
    ph = Enum.map_join(1..length(cols), ", ", &"?#{&1}")
    vals = Enum.map(cols, fn c -> row |> Map.get(c) |> bind() end)
    Repo.query!("INSERT INTO #{table} (#{Enum.join(cols, ", ")}) VALUES (#{ph})", vals)
  end

  # Raw SQL bypasses Ecto's type layer, so an Ecto :map field (front_matter)
  # arrives as a bare map and SQLite rejects it with "unsupported type: %{}".
  # Encode it the way the :map type would, so a restored row is byte-identical
  # to one written through the schema.
  defp bind(v) when is_map(v) and not is_struct(v), do: Jason.encode!(v)
  defp bind(v) when is_list(v), do: Jason.encode!(v)
  defp bind(v), do: v
end
