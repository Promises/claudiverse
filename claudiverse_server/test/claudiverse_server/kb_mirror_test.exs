defmodule ClaudiverseServer.KbMirrorTest do
  @moduledoc """
  The mirror export and its verifier.

  ⭐ The verifier's own reachable negative is the point: a checker that cannot
  report a failure is decoration, and this fleet has shipped two such probes.
  Each check here is exercised with a corruption that only IT can catch.
  """
  use ClaudiverseServer.DataCase, async: false

  alias ClaudiverseServer.Knowledge
  alias ClaudiverseServer.Repo

  setup do
    dir = Path.join(System.tmp_dir!(), "kbmirror-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp seed do
    {:ok, claim} =
      Knowledge.create_document(%{
        kind: "FACT", scope: "project:lorem-fleet", title: "a claim", slug: "m-claim",
        created_by: "w", body_md: "the body", author: "w",
        fact_command: "run it", fact_fails_when: "prints 0",
        fact_fails_when_status: "DEMONSTRATED"
      })

    {:ok, narrow} =
      Knowledge.create_document(%{
        kind: "FACT", scope: "project:lorem-fleet", title: "narrower", slug: "m-narrow",
        created_by: "w", body_md: "bounded", author: "w",
        fact_command: "run it", fact_fails_when: "prints 0",
        fact_fails_when_status: "DEMONSTRATED"
      })

    {:ok, _} =
      Knowledge.relate(%{from_document_id: narrow.id, to_document_id: claim.id,
                         kind: "NARROWS", author: "watcher", note: "smaller than stated"})

    Knowledge.record_symbol("0x00336B88", "old_name", "usa_v200", recorded_by: "t")
    Knowledge.record_symbol("0x00336B88", "NewName", "usa_v200", recorded_by: "t")
    claim
  end

  defp export(dir), do: Mix.Tasks.Claudiverse.Kb.Export.run([dir])
  defp manifest(dir), do: Path.join(dir, "manifest.json") |> File.read!() |> Jason.decode!()

  test "export renders documents and a lossless manifest", %{dir: dir} do
    seed()
    export(dir)
    m = manifest(dir)

    assert m["counts"]["documents"] == 2
    assert m["counts"]["relations"] == 1
    # BOTH symbol rows — the closed alias must survive, or a rename orphans
    # every document anchored at that address.
    assert m["counts"]["symbols"] == 2
    assert File.exists?(Path.join([dir, "documents", "project:lorem-fleet", "FACT", "m-claim.md"]))
  end

  test "a corrected claim cannot be read from the mirror without its correction",
       %{dir: dir} do
    seed()
    export(dir)

    body = Path.join([dir, "documents", "project:lorem-fleet", "FACT", "m-claim.md"]) |> File.read!()

    # FAILS IF the renderer stops inlining corrections: a mirror reader would
    # then see a narrowed claim as if it stood unqualified.
    assert body =~ "Corrections applying to this document"
    assert body =~ "NARROWS"
    assert body =~ "smaller than stated"
  end

  test "the FACT's command and fails_when survive the export", %{dir: dir} do
    seed()
    export(dir)
    body = Path.join([dir, "documents", "project:lorem-fleet", "FACT", "m-claim.md"]) |> File.read!()

    # These are the fields the forum's tail-biased truncation destroys first.
    assert body =~ "command:"
    assert body =~ "fails_when:"
    assert body =~ "fails_when_status: DEMONSTRATED"
  end

  test "the manifest keeps every revision, not only the current one", %{dir: dir} do
    {:ok, note} =
      Knowledge.create_document(%{kind: "NOTE", scope: "fleet", title: "n", slug: "m-note",
                                  created_by: "w", body_md: "v1", author: "w"})

    {:ok, _} = Knowledge.add_revision(note, %{body_md: "v2", author: "w"})
    export(dir)

    bodies = manifest(dir)["revisions"] |> Enum.map(& &1["body_md"])
    assert "v1" in bodies and "v2" in bodies
  end

  describe "restore — the half that makes the mirror a backup" do
    test "a wiped store rebuilds from the manifest, and still WORKS", %{dir: dir} do
      seed()
      export(dir)
      before = manifest(dir)

      # wipe every kb_* table, as a lost database would
      for t <- ~w(kb_relations kb_doc_anchors kb_anchors kb_revisions kb_documents kb_symbols) do
        Repo.query!("DELETE FROM #{t}")
      end

      assert Repo.aggregate(ClaudiverseServer.Knowledge.Document, :count) == 0

      Mix.Tasks.Claudiverse.Kb.Restore.run([dir])

      # 1. structure is back
      after_ = %{
        "documents" => Repo.aggregate(ClaudiverseServer.Knowledge.Document, :count),
        "revisions" => Repo.aggregate(ClaudiverseServer.Knowledge.Revision, :count),
        "relations" => Repo.aggregate(ClaudiverseServer.Knowledge.Relation, :count),
        "symbols" => Repo.aggregate(ClaudiverseServer.Knowledge.Symbol, :count)
      }

      for {k, v} <- after_, do: assert(before["counts"][k] == v, "#{k}: #{before["counts"][k]} vs #{v}")

      # 2. ⭐ the restored store FUNCTIONS. Raw INSERT bypasses Ecto, so if the
      # FTS triggers did not fire, search would be SILENTLY EMPTY on every
      # restored database — a backup that restores unusable data.
      assert [%{slug: "m-claim"}] = Knowledge.search("body")

      # 3. corrections survive: a restored claim must not read as if it stood
      read = Knowledge.get_document("m-claim")
      assert [%{kind: "NARROWS"}] = read.corrections

      # 4. front_matter round-trips as a MAP, not the JSON string raw SQL binds
      assert is_map(read.revision.front_matter)

      # 5. the closed alias survives, so anchored documents are not orphaned
      assert [%{current: false}] = Knowledge.addresses_for_name("old_name", "usa_v200")
      assert %{name: "NewName"} = Knowledge.current_symbol("0x00336B88", "usa_v200")
    end

    test "restore REFUSES over a non-empty store without --force", %{dir: dir} do
      seed()
      export(dir)

      assert_raise Mix.Error, ~r/REFUSING/, fn ->
        Mix.Tasks.Claudiverse.Kb.Restore.run([dir])
      end
    end
  end
end
