defmodule Mix.Tasks.Claudiverse.Kb.Export do
  @moduledoc """
  Export the knowledge store to a directory as markdown + a restore manifest.

      mix claudiverse.kb.export /path/to/mirror

  ## Why this exists

  Claudiverse owns its storage, which means it owns the durability too — and a
  database is ONE COPY. Measured cost of single-copy storage on this fleet: 84
  commits reachable from no remote, and a `fleet-charters/` directory living
  only on one machine.

  ⭐ This mirror carries `kb_*` ONLY. Knowledge is kilobytes; the same database
  holds 8.4M message rows and 4.4 GB of transcripts. Exporting everything would
  make the mirror unusable and is not what it is for.

  Two outputs, for two different readers:

    * `documents/<scope>/<kind>/<slug>.md` — the CURRENT revision with YAML
      front-matter. For humans, `git diff`, and grep. Lossy by design: it holds
      what a reader wants, not every revision.
    * `manifest.json` — EVERY document, EVERY revision, anchors, relations,
      symbols. This is the restore source. Lossless.

  ⛔ The mirror is a MIRROR. Claudiverse remains the source of truth; nothing
  reads back from here except a restore or a verification run.
  """
  use Mix.Task
  import Ecto.Query
  alias ClaudiverseServer.Repo
  alias ClaudiverseServer.Knowledge.{Document, Revision, Anchor, DocAnchor, Relation, Symbol}

  @shortdoc "Export the knowledge store to a git-friendly mirror directory"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    dir =
      case args do
        [d | _] -> d
        [] -> Mix.raise("usage: mix claudiverse.kb.export <dir>")
      end

    docs = Repo.all(from(d in Document, order_by: [asc: d.id]))
    revs = Repo.all(from(r in Revision, order_by: [asc: r.id]))
    anchors = Repo.all(Anchor)
    doc_anchors = Repo.all(DocAnchor)
    relations = Repo.all(from(r in Relation, order_by: [asc: r.id]))
    symbols = Repo.all(from(s in Symbol, order_by: [asc: s.id]))

    revs_by_doc = Enum.group_by(revs, & &1.document_id)
    anchors_by_id = Map.new(anchors, &{&1.id, &1})

    anchors_by_doc =
      doc_anchors
      |> Enum.group_by(& &1.document_id)
      |> Map.new(fn {doc_id, das} ->
        {doc_id, Enum.map(das, fn da -> Map.get(anchors_by_id, da.anchor_id) end) |> Enum.reject(&is_nil/1)}
      end)

    corrections_by_doc = Enum.group_by(relations, & &1.to_document_id)

    File.mkdir_p!(Path.join(dir, "documents"))

    written =
      Enum.reduce(docs, 0, fn doc, acc ->
        case Enum.find(revs_by_doc[doc.id] || [], &(&1.id == doc.current_revision_id)) do
          nil ->
            acc

          rev ->
            path =
              Path.join([dir, "documents", safe(doc.scope), safe(doc.kind), "#{safe(doc.slug)}.md"])

            File.mkdir_p!(Path.dirname(path))
            File.write!(path, render(doc, rev, anchors_by_doc[doc.id] || [], corrections_by_doc[doc.id] || []))
            acc + 1
        end
      end)

    manifest = %{
      exported_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      counts: %{
        documents: length(docs),
        revisions: length(revs),
        anchors: length(anchors),
        doc_anchors: length(doc_anchors),
        relations: length(relations),
        symbols: length(symbols)
      },
      documents: Enum.map(docs, &strip/1),
      revisions: Enum.map(revs, &strip/1),
      anchors: Enum.map(anchors, &strip/1),
      doc_anchors: Enum.map(doc_anchors, &strip/1),
      relations: Enum.map(relations, &strip/1),
      symbols: Enum.map(symbols, &strip/1)
    }

    File.write!(Path.join(dir, "manifest.json"), Jason.encode!(manifest, pretty: true))

    Mix.shell().info("""
    exported to #{dir}
      documents rendered : #{written}
      manifest counts    : #{inspect(manifest.counts)}
    """)
  end

  # A document's markdown view. Corrections are rendered INLINE, because a
  # reader of the mirror must not be able to see a claim without seeing that it
  # was retracted — the same rule the API enforces.
  defp render(doc, rev, anchors, corrections) do
    fm =
      [
        "---",
        "kind: #{doc.kind}",
        "scope: #{doc.scope}",
        "slug: #{doc.slug}",
        "title: #{doc.title}",
        "created_by: #{doc.created_by}",
        "revision: #{rev.id}",
        "author: #{rev.author}",
        rev.fact_command && "command: #{inspect(rev.fact_command)}",
        rev.fact_fails_when && "fails_when: #{inspect(rev.fact_fails_when)}",
        rev.fact_fails_when_status && "fails_when_status: #{rev.fact_fails_when_status}",
        anchors != [] && "anchors: [#{Enum.map_join(anchors, ", ", &"#{&1.type}:#{&1.value}")}]",
        "---",
        ""
      ]
      |> Enum.reject(&(&1 == false or is_nil(&1)))

    body = [rev.body_md, ""]

    corr =
      if corrections == [] do
        []
      else
        ["", "---", "", "## ⚠️ Corrections applying to this document", ""] ++
          Enum.map(corrections, fn c ->
            "- **#{c.kind}** by document ##{c.from_document_id}#{c.note && " — #{c.note}"}"
          end)
      end

    Enum.join(fm ++ body ++ corr, "\n")
  end

  defp safe(s), do: s |> to_string() |> String.replace(~r/[^A-Za-z0-9._:-]/, "_")

  defp strip(struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__, :document, :anchor, :from_document, :to_document, :revisions])
    |> Map.new(fn
      {k, %DateTime{} = v} -> {k, DateTime.to_iso8601(v)}
      {k, %NaiveDateTime{} = v} -> {k, NaiveDateTime.to_iso8601(v)}
      {k, v} -> {k, v}
    end)
  end
end
