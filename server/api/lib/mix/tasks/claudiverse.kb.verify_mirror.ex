defmodule Mix.Tasks.Claudiverse.Kb.VerifyMirror do
  @moduledoc """
  Verify an exported mirror against the live store.

      mix claudiverse.kb.verify_mirror /path/to/mirror

  ⛔ A backup nobody checks is not a backup. This is the check.

  Compares, in order of how quietly each can go wrong:

    1. **row counts** per table — catches a truncated or partial export;
    2. **per-document body sha256** — catches silent content drift, which a
       count comparison cannot see;
    3. **relation tuples** — catches a lost correction, the failure that would
       let a retracted claim read as if it stood;
    4. **symbol intervals** — catches a lost alias, the failure that orphans
       knowledge on a rename.

  ⚠️ SCOPE BOUND: this verifies the mirror MATCHES the store. Rebuilding a store
  FROM the mirror is `mix claudiverse.kb.restore`, and the round trip
  (export → wipe → restore → re-export) is covered by `KbMirrorTest`. Run both:
  a mirror that matches a store you no longer have is only half a backup.
  """
  use Mix.Task
  import Ecto.Query
  alias ClaudiverseServer.Repo
  alias ClaudiverseServer.Knowledge.{Document, Revision, Anchor, DocAnchor, Relation, Symbol}

  @shortdoc "Check an exported knowledge mirror against the live store"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    dir = List.first(args) || Mix.raise("usage: mix claudiverse.kb.verify_mirror <dir>")
    manifest = Path.join(dir, "manifest.json") |> File.read!() |> Jason.decode!()

    live = %{
      "documents" => Repo.aggregate(Document, :count),
      "revisions" => Repo.aggregate(Revision, :count),
      "anchors" => Repo.aggregate(Anchor, :count),
      "doc_anchors" => Repo.aggregate(DocAnchor, :count),
      "relations" => Repo.aggregate(Relation, :count),
      "symbols" => Repo.aggregate(Symbol, :count)
    }

    count_fails =
      Enum.filter(live, fn {t, n} -> Map.get(manifest["counts"], t) != n end)

    # 2. content hashes — a count match with different bytes is the silent case
    mirror_hashes =
      manifest["revisions"]
      |> Map.new(fn r -> {r["id"], :crypto.hash(:sha256, r["body_md"] || "") |> Base.encode16()} end)

    live_hashes =
      Repo.all(from(r in Revision, select: {r.id, r.body_md}))
      |> Map.new(fn {id, b} -> {id, :crypto.hash(:sha256, b || "") |> Base.encode16()} end)

    hash_fails =
      Enum.filter(live_hashes, fn {id, h} -> Map.get(mirror_hashes, id) != h end)

    # 3. relations — a lost correction lets a retracted claim read as standing
    live_rel =
      Repo.all(from(r in Relation, select: {r.from_document_id, r.to_document_id, r.kind}))
      |> MapSet.new()

    mirror_rel =
      manifest["relations"]
      |> Enum.map(&{&1["from_document_id"], &1["to_document_id"], &1["kind"]})
      |> MapSet.new()

    rel_missing = MapSet.difference(live_rel, mirror_rel)

    # 4. symbols — a lost alias orphans knowledge on a rename
    live_sym =
      Repo.all(from(s in Symbol, select: {s.address, s.name, s.build})) |> MapSet.new()

    mirror_sym =
      manifest["symbols"] |> Enum.map(&{&1["address"], &1["name"], &1["build"]}) |> MapSet.new()

    sym_missing = MapSet.difference(live_sym, mirror_sym)

    report("row counts", count_fails, fn {t, n} -> "#{t}: live #{n} vs mirror #{manifest["counts"][t]}" end)
    report("body hashes", hash_fails, fn {id, _} -> "revision #{id} differs" end)
    report("relations", MapSet.to_list(rel_missing), &inspect/1)
    report("symbols", MapSet.to_list(sym_missing), &inspect/1)

    ok =
      count_fails == [] and hash_fails == [] and MapSet.size(rel_missing) == 0 and
        MapSet.size(sym_missing) == 0

    Mix.shell().info("")

    if ok do
      Mix.shell().info("MIRROR VERIFIED — counts, bodies, relations and symbols all match.")
      Mix.shell().info("BOUND: this proves the mirror MATCHES the store. Rebuilding FROM it is")
      Mix.shell().info("`mix claudiverse.kb.restore`; the export/wipe/restore round trip is tested.")
    else
      Mix.raise("MIRROR VERIFICATION FAILED — see above")
    end
  end

  defp report(_label, [], _fmt), do: :ok

  defp report(label, fails, fmt) do
    Mix.shell().error("#{label}: #{length(fails)} mismatch(es)")
    Enum.each(Enum.take(fails, 5), fn f -> Mix.shell().error("  #{fmt.(f)}") end)
  end
end
