defmodule ClaudiverseServer.KnowledgeSymbolsTest do
  @moduledoc """
  Invariant 5 — symbol writes are alias-aware.

  The scenario under test is the real one: commit bb754675 renamed asm glabels
  and every reference keyed on the old spelling desynced. A rename here must
  CLOSE the old name, not erase it.
  """
  use ClaudiverseServer.DataCase, async: false

  # ⛔ NOT async. SQLite permits a single writer, and the Ecto sandbox holds a
  # write transaction open for a test's whole duration — so concurrent async
  # tests exhaust the 2s busy_timeout and fail with "Database busy". It is
  # ORDER-DEPENDENT: green at seed 0, four failures at seed 7. A suite that
  # passes on most seeds is not a passing suite; it is an untrustworthy one.

  alias ClaudiverseServer.Knowledge

  @build "usa_v200"

  test "a rename closes the old name and keeps it resolvable" do
    {:ok, _} = Knowledge.record_symbol("0x00336B88", "func_00336B88", @build, recorded_by: "splat")

    assert %{name: "func_00336B88"} = Knowledge.current_symbol("0x00336B88", @build)

    {:ok, _} =
      Knowledge.record_symbol("0x00336B88", "GuiComputeBlendWeights", @build,
        recorded_by: "track-b",
        source_sha: "bb754675"
      )

    # the new name is current
    assert %{name: "GuiComputeBlendWeights"} = Knowledge.current_symbol("0x00336B88", @build)

    # ⭐ FAILS IF INVARIANT REMOVED: the DEAD name must still resolve to the
    # address. If a rename overwrote the row instead of closing it, this is [].
    assert [%{address: "00336b88", current: false}] =
             Knowledge.addresses_for_name("func_00336B88", @build)

    # positive control: the live name resolves too, and is marked current
    assert [%{current: true}] = Knowledge.addresses_for_name("GuiComputeBlendWeights", @build)

    # history is ordered and complete, with the old row closed
    [old, new] = Knowledge.symbol_history("0x00336B88", @build)
    assert old.name == "func_00336B88" and not is_nil(old.valid_to)
    assert new.name == "GuiComputeBlendWeights" and is_nil(new.valid_to)
  end

  test "recording the same name twice is a no-op, not a duplicate" do
    {:ok, _} = Knowledge.record_symbol("0x1A8180", "SomeFn", @build, recorded_by: "t")
    {:ok, _} = Knowledge.record_symbol("0x1A8180", "SomeFn", @build, recorded_by: "t")

    assert length(Knowledge.symbol_history("0x1A8180", @build)) == 1
  end

  test "address spellings collapse — a symbol and its anchor cannot disagree" do
    {:ok, _} = Knowledge.record_symbol("0x00336B88", "Fn", @build, recorded_by: "t")

    for spelling <- ["0x00336B88", "0x336b88", "336B88", "00336b88"] do
      assert %{name: "Fn"} = Knowledge.current_symbol(spelling, @build),
             "lookup failed for #{spelling}"
    end
  end

  test "builds are independent — the same address may differ across builds" do
    {:ok, _} = Knowledge.record_symbol("0x00336B88", "UsaName", "usa_v200", recorded_by: "t")
    {:ok, _} = Knowledge.record_symbol("0x00336B88", "EurName", "eur_v100", recorded_by: "t")

    assert %{name: "UsaName"} = Knowledge.current_symbol("0x00336B88", "usa_v200")
    assert %{name: "EurName"} = Knowledge.current_symbol("0x00336B88", "eur_v100")
  end

  test "address_listing gathers name, aliases and anchored documents" do
    {:ok, _} = Knowledge.record_symbol("0x00336B88", "OldName", @build, recorded_by: "t")
    {:ok, _} = Knowledge.record_symbol("0x00336B88", "NewName", @build, recorded_by: "t")

    {:ok, doc} =
      Knowledge.create_document(%{
        kind: "NOTE",
        scope: "project:lorem-fleet",
        title: "what this does",
        slug: "listing-note",
        created_by: "t",
        body_md: "b",
        author: "t"
      })

    {:ok, _} = Knowledge.anchor_document(doc, "address", "0x336b88")

    listing = Knowledge.address_listing("0x00336B88", @build)
    assert listing.current_symbol.name == "NewName"
    assert Enum.map(listing.aliases, & &1.name) == ["OldName", "NewName"]
    assert Enum.map(listing.documents, & &1.slug) == ["listing-note"]
  end
end
