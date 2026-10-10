defmodule ClaudiverseServer.KnowledgeTest do
  @moduledoc """
  Tests for the knowledge store's invariants.

  ⭐ Each invariant test is written so it FAILS if the invariant is removed —
  that is the point. A test that passes whether or not the rule is enforced is
  the same defect this store exists to catch: a check with no reachable
  negative.
  """
  use ClaudiverseServer.DataCase, async: false

  # ⛔ NOT async. SQLite permits a single writer, and the Ecto sandbox holds a
  # write transaction open for a test's whole duration — so concurrent async
  # tests exhaust the 2s busy_timeout and fail with "Database busy". It is
  # ORDER-DEPENDENT: green at seed 0, four failures at seed 7. A suite that
  # passes on most seeds is not a passing suite; it is an untrustworthy one.

  alias ClaudiverseServer.Knowledge
  alias ClaudiverseServer.Knowledge.Document

  defp fact_attrs(slug, overrides \\ %{}) do
    Map.merge(
      %{
        kind: "FACT",
        scope: "fleet",
        title: "probe fact #{slug}",
        slug: slug,
        created_by: "test",
        body_md: "the claim body",
        author: "test",
        fact_command: "/usr/bin/grep -c foo bar.txt",
        fact_fails_when: "prints 0",
        fact_fails_when_status: "DEMONSTRATED"
      },
      overrides
    )
  end

  describe "invariant 1 — a read never returns a claim without its corrections" do
    test "corrections are present on a plain read, and are [] when there are none" do
      {:ok, claim} = Knowledge.create_document(fact_attrs("inv1-claim"))
      read = Knowledge.get_document(claim.id)

      # POSITIVE CONTROL: the key exists and is empty before any correction, so
      # the assertion below cannot pass merely because the field is missing.
      assert read.corrections == []

      {:ok, retraction} =
        Knowledge.create_document(fact_attrs("inv1-retraction", %{title: "it is false"}))

      {:ok, _} =
        Knowledge.relate(%{
          from_document_id: retraction.id,
          to_document_id: claim.id,
          kind: "RETRACTS",
          author: "test"
        })

      read = Knowledge.get_document(claim.id)

      # FAILS IF INVARIANT REMOVED: drop the corrections load from get_document
      # and this is [] — the caller reads a retracted claim as if it stood.
      assert [%{kind: "RETRACTS", from_document_id: from_id}] = read.corrections
      assert from_id == retraction.id
    end

    test "CITES is not a correction and does not pollute the corrections list" do
      {:ok, a} = Knowledge.create_document(fact_attrs("inv1-a"))
      {:ok, b} = Knowledge.create_document(fact_attrs("inv1-b"))

      {:ok, _} =
        Knowledge.relate(%{from_document_id: b.id, to_document_id: a.id, kind: "CITES", author: "t"})

      assert Knowledge.get_document(a.id).corrections == []
    end
  end

  describe "invariant 2 — a FACT may be revised, but never silently" do
    test "a FACT accepts a revision that attaches a bound it was filed without" do
      # ⛔ WHY THIS CHANGED. FACT revisions were rejected outright. Then ~20 facts
      # were filed with an explicit fact_bound that the API silently discarded,
      # and there was NO way to attach the bounds afterwards — the corpus was
      # stuck with claims whose scope could never be recorded. A bound found
      # later must be attachable, or bounds only ever get weaker in practice.
      {:ok, doc} =
        Knowledge.create_document(%{
          slug: "revisable-fact",
          kind: "FACT",
          scope: "test",
          title: "a fact",
          body_md: "the claim",
          author: "a",
          created_by: "a",
          fact_command: "run it",
          fact_fails_when: "it prints NOPE",
          fact_fails_when_status: "ASSERTED"
        })

      assert {:ok, _} =
               Knowledge.add_revision(doc, %{
                 body_md: "the claim",
                 author: "b",
                 fact_command: "run it",
                 fact_fails_when: "it prints NOPE",
                 fact_fails_when_status: "ASSERTED",
                 front_matter: %{"bound" => "n=3, one region"}
               })
    end

    test "the revision is visible on the DEFAULT read path, not only via history" do
      # The original rule existed because an edited claim and the cited claim
      # become "silently different things". The word doing the work is SILENTLY:
      # a queryable history nobody queries is the same as no history.
      {:ok, doc} =
        Knowledge.create_document(%{
          slug: "counted-fact",
          kind: "FACT",
          scope: "test",
          title: "a fact",
          body_md: "v1",
          author: "a",
          created_by: "a",
          fact_command: "run it",
          fact_fails_when: "NOPE",
          fact_fails_when_status: "ASSERTED"
        })

      assert %{count: 1} = Knowledge.revision_summary(doc)

      {:ok, doc} =
        Knowledge.add_revision(doc, %{
          body_md: "v2",
          author: "b",
          fact_command: "run it",
          fact_fails_when: "NOPE",
          fact_fails_when_status: "ASSERTED"
        })

      assert %{count: 2} = Knowledge.revision_summary(doc),
             "a revised FACT must announce itself to a reader who cites it"
    end

    test "ASSERTED cannot be promoted to DEMONSTRATED without saying how" do
      # ⛔ The single edit that turns a never-green fact green. Allowing it
      # unbacked would let a fact be promoted by editing one word.
      {:ok, doc} =
        Knowledge.create_document(%{
          slug: "promotable-fact",
          kind: "FACT",
          scope: "test",
          title: "a fact",
          body_md: "the claim",
          author: "a",
          created_by: "a",
          fact_command: "run it",
          fact_fails_when: "NOPE",
          fact_fails_when_status: "ASSERTED"
        })

      assert {:error, cs} =
               Knowledge.add_revision(doc, %{
                 body_md: "the claim",
                 author: "b",
                 fact_command: "run it",
                 fact_fails_when: "NOPE",
                 fact_fails_when_status: "DEMONSTRATED"
               })

      assert "fact_fails_when_status" in Enum.map(cs.errors, fn {k, _} -> to_string(k) end)

      # ...and it succeeds once the evidence rides along.
      assert {:ok, _} =
               Knowledge.add_revision(doc, %{
                 body_md: "the claim",
                 author: "b",
                 fact_command: "run it",
                 fact_fails_when: "NOPE",
                 fact_fails_when_status: "DEMONSTRATED",
                 front_matter: %{"demonstrated_by" => "injected a mutant and saw NOPE"}
               })
    end
  end

  describe "invariant 2 (revised 2026-09-11) — a FACT revision must carry its fact fields" do
    test "add_revision works for a FACT and for a NOTE" do
      {:ok, fact} = Knowledge.create_document(fact_attrs("inv2-fact"))

      # A FACT revision still has to satisfy validate_fact_fields — a bare body
      # edit that drops command/fails_when is rejected, so relaxing immutability
      # did NOT relax what makes a fact a fact.
      assert {:error, cs} = Knowledge.add_revision(fact, %{body_md: "edited", author: "test"})
      assert cs.errors != []

      assert {:ok, _} =
               Knowledge.add_revision(fact, %{
                 body_md: "edited",
                 author: "test",
                 fact_command: "run it",
                 fact_fails_when: "NOPE",
                 fact_fails_when_status: "ASSERTED"
               })

      # POSITIVE CONTROL: the same call on a NOTE must SUCCEED, so the test
      # cannot pass because add_revision is simply broken for everything.
      {:ok, note} =
        Knowledge.create_document(%{
          kind: "NOTE",
          scope: "fleet",
          title: "a note",
          slug: "inv2-note",
          created_by: "test",
          body_md: "v1",
          author: "test"
        })

      assert {:ok, updated} = Knowledge.add_revision(note, %{body_md: "v2", author: "test"})
      assert length(Knowledge.history(updated.id)) == 2
    end
  end

  describe "invariant 3 — ASSERTED is never swept green" do
    defp run(doc, output, opts \\ []) do
      {:ok, c} =
        Knowledge.record_run(doc.id, %{
          output: output,
          exit_status: Keyword.get(opts, :exit_status, 0),
          manual: Keyword.get(opts, :manual, false),
          environment: "test-host",
          runner: "test"
        })

      c
    end

    test "an ASSERTED fact reads :untested even after a clean run" do
      {:ok, asserted} =
        Knowledge.create_document(fact_attrs("inv3-asserted", %{fact_fails_when_status: "ASSERTED"}))

      run(asserted, "all good")
      run(asserted, "all good")

      # FAILS IF INVARIANT REMOVED: read the last check naively and this is
      # :corroborated — an unobserved failing arm reported as evidence.
      assert Knowledge.sweep_status(asserted) == :untested

      # POSITIVE CONTROL: an otherwise identical DEMONSTRATED fact, same output,
      # DOES corroborate — so :untested is the status doing work, not a constant.
      {:ok, demonstrated} = Knowledge.create_document(fact_attrs("inv3-demo"))
      run(demonstrated, "all good")
      run(demonstrated, "all good")
      assert Knowledge.sweep_status(demonstrated) == :corroborated
    end

    test "a NON-ZERO exit is a RESULT, not an error" do
      {:ok, fact} = Knowledge.create_document(fact_attrs("inv3-exit1"))

      # ⛔ grep exits 1 when it matches nothing, and "matches nothing" is the
      # expected measurement for every fact claiming something is ABSENT.
      # Measured on the first real sweep batch: 2 of 11 executed checks were
      # marked ERROR while holding valid output. ERROR stores no hash, so they
      # could never baseline and therefore never detect change — permanently
      # blind, while looking like a transient problem.
      c = run(fact, "", exit_status: 1)
      assert c.verdict == "BASELINE"
      assert c.output_hash

      assert run(fact, "", exit_status: 1).verdict == "UNCHANGED"

      # ⭐ and the exit status is part of the comparison: the same output with
      # a different exit code IS a change.
      assert run(fact, "", exit_status: 0).verdict == "CHANGED"
    end

    test "only a command that COULD NOT RUN is an ERROR" do
      for status <- [127, 126, 124, 137, nil] do
        {:ok, f} = Knowledge.create_document(fact_attrs("inv3-err-#{status || "nil"}"))
        c = run(f, "bash: ee-gcc: command not found", exit_status: status)
        assert c.verdict == "ERROR", "exit #{inspect(status)} should be ERROR"
        refute c.output_hash
        assert Knowledge.sweep_status(f) == :unrunnable
      end
    end

    test "ERROR is unrunnable, never corroborated" do
      {:ok, fact} = Knowledge.create_document(fact_attrs("inv3-error"))

      c = run(fact, "bash: ee-gcc: command not found", exit_status: 127)
      assert c.verdict == "ERROR"
      assert Knowledge.sweep_status(fact) == :unrunnable

      # ⭐ And a failed run stores NO hash. Otherwise an error's output would
      # become the baseline, and the next real run would read as CHANGED —
      # manufacturing a staleness alarm out of a missing toolchain.
      refute c.output_hash
    end

    test "a prose procedure is MANUAL, not silently skipped" do
      {:ok, fact} = Knowledge.create_document(fact_attrs("inv3-manual"))

      c = run(fact, "", manual: true)
      assert c.verdict == "MANUAL"
      assert Knowledge.sweep_status(fact) == :unrunnable

      # 1,138 of 5,116 measured commands are prose. Recording them is what
      # stops 22% of the corpus being skipped and counted as covered.
      refute c.output_hash
    end

    test "the verdict is DERIVED from output, not taken from the runner" do
      {:ok, fact} = Knowledge.create_document(fact_attrs("inv3-derive"))

      assert run(fact, "42 differing bytes").verdict == "BASELINE"
      assert run(fact, "42 differing bytes").verdict == "UNCHANGED"

      # ⭐ The actionable signal: the evidence moved.
      changed = run(fact, "83843 differing bytes")
      assert changed.verdict == "CHANGED"
      assert Knowledge.sweep_status(fact) == :moved

      # and it settles again on the NEW output rather than the original
      assert run(fact, "83843 differing bytes").verdict == "UNCHANGED"
    end

    test "a hash from an OLD formula re-baselines instead of firing as drift" do
      {:ok, fact} = Knowledge.create_document(fact_attrs("inv3-fpver"))

      # Simulate a check stored under a previous fingerprint formula.
      {:ok, _} =
        Knowledge.record_check(%{
          document_id: fact.id,
          ran_at: DateTime.utc_now() |> DateTime.truncate(:second),
          verdict: "BASELINE",
          output_hash: "v1:deadbeef",
          exit_status: 0,
          runner: "test"
        })

      # ⛔ Compared naively this is CHANGED — and since a formula change hits
      # EVERY fact at once, it is indistinguishable from the whole world moving.
      # OBSERVED in a live pass: 9 of 11 checks went CHANGED on a repository
      # nothing had touched.
      assert run(fact, "same output").verdict == "BASELINE"

      # and once re-baselined, ordinary comparison resumes
      assert run(fact, "same output").verdict == "UNCHANGED"
      assert run(fact, "different output").verdict == "CHANGED"
    end

    test "a run that executed MUST carry a hash, or nothing is ever CHANGED" do
      {:ok, fact} = Knowledge.create_document(fact_attrs("inv3-hash"))

      # Bypassing record_run to hand-write an executed check without a hash:
      # every later run would look like a BASELINE and CHANGED would never fire.
      assert {:error, cs} =
               Knowledge.record_check(%{
                 document_id: fact.id,
                 ran_at: DateTime.utc_now() |> DateTime.truncate(:second),
                 verdict: "UNCHANGED",
                 runner: "test"
               })

      assert "is required when the command actually ran" in errors_on(cs).output_hash
    end

    test "output is truncated LOUDLY, never silently" do
      {:ok, fact} = Knowledge.create_document(fact_attrs("inv3-trunc"))

      big = String.duplicate("x", 20_000) <> "THE-TAIL-WHERE-CAVEATS-LIVE"
      c = run(fact, big)

      assert String.contains?(c.output, "TRUNCATED")
      assert String.contains?(c.output, "20027 bytes total")

      # ⭐ The HASH covers the whole output, not the stored excerpt — otherwise
      # two runs differing only past the cut would read as UNCHANGED.
      c2 = run(fact, String.duplicate("x", 20_000) <> "A-DIFFERENT-TAIL")
      assert c2.verdict == "CHANGED"
    end

    test "stale_facts lists the untested and omits the corroborated" do
      {:ok, a} = Knowledge.create_document(fact_attrs("inv3-l1", %{fact_fails_when_status: "ASSERTED"}))
      {:ok, b} = Knowledge.create_document(fact_attrs("inv3-l2"))

      run(b, "same")
      run(b, "same")

      slugs = Knowledge.stale_facts() |> Enum.map(fn {d, s} -> {d.slug, s} end)
      assert {"inv3-l1", :untested} in slugs
      refute Enum.any?(slugs, fn {slug, _} -> slug == "inv3-l2" end)
      assert a.id != b.id
    end

    test "the worklist EXCLUDES untested facts, so they cannot be worked off" do
      {:ok, _a} = Knowledge.create_document(fact_attrs("inv3-w1", %{fact_fails_when_status: "ASSERTED"}))
      {:ok, b} = Knowledge.create_document(fact_attrs("inv3-w2"))

      work = Knowledge.sweep_worklist(min_age_hours: 0) |> Enum.map(& &1.slug)

      # ⛔ Running an ASSERTED fact's command yields UNCHANGED and makes it look
      # worked-on, while the actual defect — a failure branch nobody has ever
      # observed — is untouched. Motion recorded as progress.
      refute "inv3-w1" in work
      assert "inv3-w2" in work
      assert b.id

      # but it stays VISIBLE on the stale list, so its count is not hidden
      assert Enum.any?(Knowledge.stale_facts(), fn {d, s} -> d.slug == "inv3-w1" and s == :untested end)
    end

    test "a CORROBORATED fact returns to the worklist — corroboration is not a finish line" do
      {:ok, fact} = Knowledge.create_document(fact_attrs("inv3-recheck"))

      run(fact, "same")
      run(fact, "same")
      assert Knowledge.sweep_status(fact) == :corroborated

      # ⛔ REGRESSION GUARD. Built on stale_facts/0 this returned [], because
      # that helper omits :corroborated. A fact would then be checked twice and
      # dropped from coverage permanently, and every later drift would be
      # invisible — while the sweep still reported clean runs for everything
      # else. Silent loss of coverage, disguised as success.
      assert [%{slug: "inv3-recheck"}] = Knowledge.sweep_worklist(min_age_hours: 0)

      # and re-running it CAN still detect drift
      assert run(fact, "different now").verdict == "CHANGED"
      assert Knowledge.sweep_status(fact) == :moved
    end

    test "the worklist skips facts checked recently" do
      {:ok, _} = Knowledge.create_document(fact_attrs("inv3-recent"))
      [%{slug: "inv3-recent"} = item] = Knowledge.sweep_worklist(min_age_hours: 0)
      assert item.command

      Knowledge.record_run(item.id, %{output: "x", exit_status: 0, runner: "test"})

      # skipped because it was checked seconds ago, NOT because it is done
      assert Knowledge.sweep_worklist(min_age_hours: 24) == []

      # ⭐ and it is still WORK: one BASELINE run corroborates nothing, so it
      # must come back for the second run that can actually say something.
      assert [%{slug: "inv3-recent", status: :baselined}] =
               Knowledge.sweep_worklist(min_age_hours: 0)
    end
  end

  describe "invariant 4 — STATUS is never storable" do
    test "STATUS is rejected while the five real kinds are accepted" do
      assert {:error, cs} =
               Knowledge.create_document(fact_attrs("inv4-status", %{kind: "STATUS"}))

      # Assert the REASON, not merely that something errored. Without this the
      # test passes even when the derived-kind branch is deleted, because the
      # unknown-kind catch-all rejects STATUS too — a different rule wearing the
      # same result. (Caught by mutation testing 2026-09-08.)
      {msg, _} = Keyword.fetch!(cs.errors, :kind)
      assert msg =~ "DERIVED", "expected the derived-kind rule, got: #{msg}"

      # POSITIVE CONTROL: every storable kind must still insert, so the test
      # cannot pass because creation is broken generally.
      for {kind, i} <- Enum.with_index(Document.kinds()) do
        attrs =
          fact_attrs("inv4-ok-#{i}", %{kind: kind})
          |> then(fn a -> if kind == "FACT", do: a, else: Map.drop(a, [:fact_command]) end)

        assert {:ok, _} = Knowledge.create_document(attrs), "kind #{kind} should be storable"
      end
    end
  end

  describe "a FACT needs a command that can fail" do
    test "creation without fact_command is rejected; a NOTE without one is fine" do
      assert {:error, _} =
               Knowledge.create_document(fact_attrs("nofail") |> Map.drop([:fact_command]))

      assert {:ok, _} =
               Knowledge.create_document(%{
                 kind: "NOTE",
                 scope: "fleet",
                 title: "n",
                 slug: "nofail-note",
                 created_by: "t",
                 body_md: "b",
                 author: "t"
               })
    end
  end

  describe "anchors — address is the stable key" do
    test "spellings of one address collapse to one anchor" do
      {:ok, doc} = Knowledge.create_document(fact_attrs("anchor-1"))
      {:ok, _} = Knowledge.anchor_document(doc, "address", "0x00336B88")

      # Every spelling must find it. FAILS IF normalise/2 is removed.
      for spelling <- ["0x00336B88", "0x336b88", "00336b88", "336B88"] do
        found = Knowledge.documents_for_anchor("address", spelling)
        assert Enum.map(found, & &1.slug) == ["anchor-1"], "lookup failed for #{spelling}"
      end

      # POSITIVE CONTROL: a genuinely different address must NOT match.
      assert Knowledge.documents_for_anchor("address", "0x00336B89") == []
    end
  end

  describe "search — the queries this corpus is actually made of" do
    setup do
      {:ok, _} =
        Knowledge.create_document(%{
          slug: "search-flags",
          kind: "NOTE",
          scope: "test",
          title: "flags and paths",
          body_md: "built with -O2 -G0 via tools/ee/vm.sh using ee-gcc 2.9-ee-991111",
          author: "t",
          created_by: "t"
        })

      :ok
    end

    test "a hyphen or slash no longer raises — it used to kill the query" do
      # ⛔ MEASURED on the imported ledger: FTS5 raises ArgumentError on a bare
      # `-` or `/`. Compiler flags and file paths are exactly what this corpus
      # is searched for, so the crash landed on the most valuable queries — and
      # the caller could not tell a crash from an empty corpus.
      for q <- ["-O2 -G0", "tools/ee/vm.sh", "ee-gcc 2.9", "-fopt-stack"] do
        result = Knowledge.search(q)
        refute match?({:error, _}, result), "#{q} returned an error"
        assert is_list(result)
      end

      assert [%{slug: "search-flags"}] = Knowledge.search("tools/ee/vm.sh")
      assert [%{slug: "search-flags"}] = Knowledge.search("-O2 -G0")
    end

    test "plain terms are UNAFFECTED — the control on the quoting change" do
      # Without this, quoting could break ordinary search and the test above
      # would still pass.
      assert [%{slug: "search-flags"}] = Knowledge.search("ee-gcc")
      assert [] = Knowledge.search("nonexistentterm")
    end

    test "a NEW document is reachable at the default limit — rowid order buried it" do
      # ⛔ REGRESSION. FTS5 returns matches in ROWID order unless ranked, and
      # rowid is insertion order. The imported ledger holds the lowest rowids,
      # so every small LIMIT was filled by the oldest corpus and nothing
      # written since the import could be reached.
      #
      # MEASURED 2026-09-11 on the live store: search("GetRandomInt") returned
      # 32 matches with the two project:lorem-project documents at positions 31 and
      # 32 — invisible at the default limit of 15. A document filed two minutes
      # earlier was unfindable, and it looked exactly like a corpus that does
      # not contain the term.
      #
      # The shape below reproduces that: 30 older, weakly-relevant documents
      # inserted FIRST, then the strongly-relevant one LAST. Under rowid order
      # the new document is 31st. Under bm25 it is first.
      for i <- 1..30 do
        {:ok, _} =
          Knowledge.create_document(%{
            slug: "bury-#{i}",
            kind: "NOTE",
            scope: "test",
            title: "filler #{i}",
            body_md:
              "scheduler mentioned once here, " <>
                String.duplicate("unrelated padding prose ", 40),
            author: "t",
            created_by: "t"
          })
      end

      {:ok, _} =
        Knowledge.create_document(%{
          slug: "newest-and-most-relevant",
          kind: "NOTE",
          scope: "test",
          title: "scheduler verdict",
          body_md: "scheduler scheduler scheduler",
          author: "t",
          created_by: "t"
        })

      slugs = Knowledge.search("scheduler") |> Enum.map(& &1.slug)

      assert "newest-and-most-relevant" in slugs,
             "the newest document was buried below the default limit — is ORDER BY rank still in the query?"

      # Ranked, not merely present: it is the most relevant match.
      assert hd(slugs) == "newest-and-most-relevant"
    end

    test "a term that appears ONLY in the title is findable" do
      # ⛔ REGRESSION. kb_revisions_fts is external-content on kb_revisions, but
      # `title` belongs to kb_documents — FTS5 cannot index it, so the insert
      # trigger writes a literal '' into the title column. Every title term was
      # silently unfindable, and an unfindable document is indistinguishable
      # from one that does not exist.
      #
      # MEASURED 2026-09-11: this exact case returned [] before the LIKE pass.
      {:ok, _} =
        Knowledge.create_document(%{
          slug: "title-probe",
          kind: "NOTE",
          scope: "test",
          title: "zarquon calibration verdict",
          body_md: "this body deliberately does not contain the title word",
          author: "t",
          created_by: "t"
        })

      assert [%{slug: "title-probe"}] = Knowledge.search("zarquon")
    end

    test "a title hit outranks a body-only mention" do
      # Title hits are placed first deliberately: a term in the title is a
      # stronger signal about what a document IS than a mention in its prose.
      {:ok, _} =
        Knowledge.create_document(%{
          slug: "body-mentions-quasar",
          kind: "NOTE",
          scope: "test",
          title: "unrelated heading",
          body_md: "somewhere in here the word quasar appears once",
          author: "t",
          created_by: "t"
        })

      {:ok, _} =
        Knowledge.create_document(%{
          slug: "titled-quasar",
          kind: "NOTE",
          scope: "test",
          title: "quasar",
          body_md: "no mention of the heading word in this body at all",
          author: "t",
          created_by: "t"
        })

      slugs = Knowledge.search("quasar") |> Enum.map(& &1.slug)
      assert hd(slugs) == "titled-quasar"
      assert "body-mentions-quasar" in slugs
    end

    test "scope filters to that scope PLUS fleet, and REPORTS what it withheld" do
      # ⛔ One corpus serves several fleets. An unscoped search returns another
      # project's documents — which got materially worse the moment ORDER BY
      # rank landed, because before it the other project's documents sat past
      # the default limit and the mixing was invisible.
      #
      # MEASURED 2026-09-11: a search for a generic engineering term returned 9
      # lorem-fleet documents in a 10-result page for a fleet that does not work on lorem-fleet.
      for {slug, scope} <- [
            {"scoped-mine", "project:alpha"},
            {"scoped-theirs", "project:beta"},
            {"scoped-shared", "fleet"}
          ] do
        {:ok, _} =
          Knowledge.create_document(%{
            slug: slug,
            kind: "NOTE",
            scope: scope,
            title: "t-#{slug}",
            body_md: "zircon appears in every one of these",
            author: "t",
            created_by: "t"
          })
      end

      all = Knowledge.search("zircon") |> Enum.map(& &1.slug) |> Enum.sort()
      assert all == ["scoped-mine", "scoped-shared", "scoped-theirs"]

      scoped =
        Knowledge.search("zircon", scope: "project:alpha") |> Enum.map(& &1.slug) |> Enum.sort()

      # fleet scope is ALWAYS included — it exists for knowledge every fleet
      # shares, and cutting a project off from it defeats the point.
      assert scoped == ["scoped-mine", "scoped-shared"],
             "scope must include the requested scope AND fleet, and nothing else"

      # ...and the thing it hid must be COUNTED, not silently dropped.
      assert Knowledge.search_withheld("zircon", scope: "project:alpha") == 1
      assert Knowledge.search_withheld("zircon", scope: "*") == 0
    end

    test "a multi-word query matches words that are NOT adjacent" do
      # ⛔ REGRESSION. The whole query used to be quoted into ONE FTS5 phrase,
      # so a natural query matched only documents containing its words
      # contiguously and in order. MEASURED on the live corpus 2026-09-27:
      # "save stride packed save slot cc1 variants screened func_002CE0C8"
      # returned 0 as a phrase and 1 with every term required, and a seat
      # read the 0 as "no such record".
      {:ok, _} =
        Knowledge.create_document(%{
          slug: "scattered-terms",
          kind: "NOTE",
          scope: "test",
          title: "unrelated heading",
          body_md: "the zeppelin was calibrated long before the marmoset arrived",
          author: "t",
          created_by: "t"
        })

      assert [%{slug: "scattered-terms"}] = Knowledge.search("marmoset zeppelin")
      # Every term is still REQUIRED: one absent term means no match.
      assert [] = Knowledge.search("marmoset zeppelin nonexistentterm")
    end

    test "an explicitly quoted query is still an exact phrase" do
      {:ok, _} =
        Knowledge.create_document(%{
          slug: "phrase-probe",
          kind: "NOTE",
          scope: "test",
          title: "unrelated heading",
          body_md: "the quokka sprinted past the wombat",
          author: "t",
          created_by: "t"
        })

      assert [%{slug: "phrase-probe"}] = Knowledge.search(~s("quokka sprinted"))
      assert [] = Knowledge.search(~s("wombat quokka"))
      # ...while the same words unquoted are simply all required.
      assert [%{slug: "phrase-probe"}] = Knowledge.search("wombat quokka")
    end

    test "terms found only in the SLUG are findable" do
      # A document's slug is often the most exact name for it — and the FTS
      # index never contained it. MEASURED 2026-09-27: a control built from the
      # slug of #6381 (verify-match-unit-zero-run-elision-blindspot) could not
      # match, because "blindspot" occurs only in the slug.
      {:ok, _} =
        Knowledge.create_document(%{
          slug: "verify-match-narwhal-blindspot",
          kind: "NOTE",
          scope: "test",
          title: "unrelated heading",
          body_md: "this body mentions neither slug word",
          author: "t",
          created_by: "t"
        })

      assert [%{slug: "verify-match-narwhal-blindspot"}] = Knowledge.search("narwhal blindspot")
    end

    test "prefix search survives the quoting" do
      # The trailing * must stay OUTSIDE the phrase, or prefix search silently
      # becomes a literal search for a word ending in an asterisk.
      assert [%{slug: "search-flags"}] = Knowledge.search("tool*")
      assert [] = Knowledge.search("zzzz*")
    end

    test "raw: true still passes FTS5 operators through" do
      assert [%{slug: "search-flags"}] = Knowledge.search("ee OR zzzz", raw: true)
    end

    test "the index can read its content back: integrity-check, rebuild, snippet" do
      # ⛔ MEASURED on prod 2026-10-06: the index declared a `title` column its
      # content table does not have, so every operation that reads text back
      # failed with "no such column: T.title". MATCH + rank never do, so search
      # looked fine while the index could be neither verified nor rebuilt.
      alias ClaudiverseServer.Repo
      assert {:ok, _} = Repo.query("INSERT INTO kb_revisions_fts(kb_revisions_fts) VALUES ('integrity-check')")
      assert {:ok, %{rows: [[n]]}} = Repo.query("SELECT count(*) FROM kb_revisions_fts")
      assert n > 0

      assert {:ok, %{rows: [[snip]]}} =
               Repo.query("SELECT snippet(kb_revisions_fts, 0, '[', ']', '…', 4) FROM kb_revisions_fts WHERE kb_revisions_fts MATCH 'vm'")
      assert snip =~ "[vm]"

      # A rebuild must leave search answering, never an empty index.
      assert {:ok, _} = Repo.query("INSERT INTO kb_revisions_fts(kb_revisions_fts) VALUES ('rebuild')")
      assert [%{slug: "search-flags"}] = Knowledge.search("tools/ee/vm.sh")
      assert [] = Knowledge.search("nonexistentterm")
    end

    test "a malformed RAW query returns an error, never a silent empty list" do
      # A crash reported as \"no results\" is why the hyphen bug survived: the
      # two are the same observation to the caller.
      assert {:error, _} = Knowledge.search("\"unterminated", raw: true)
    end
  end

  describe "created_by defaults to author" do
    test "a caller supplying only author succeeds" do
      # ⛔ FOUND BY FIRST REAL USE, not by review: cv_doc_put sent `author` and
      # got 422 "created_by can't be blank" — a field the caller had never
      # heard of. They are the same person in every real call, and a client
      # cannot guess that supplying one obliges the other.
      assert {:ok, doc} =
               Knowledge.create_document(%{
                 kind: "NOTE",
                 scope: "test",
                 title: "author only",
                 slug: "author-only",
                 body_md: "x",
                 author: "lorem-admin"
               })

      assert doc.created_by == "lorem-admin"
    end

    test "an explicit created_by still wins" do
      assert {:ok, doc} =
               Knowledge.create_document(%{
                 kind: "NOTE",
                 scope: "test",
                 title: "both",
                 slug: "both-given",
                 body_md: "x",
                 author: "worker",
                 created_by: "integrator"
               })

      assert doc.created_by == "integrator"
    end

    test "string-keyed attrs (the HTTP path) work too" do
      # The API passes string keys; a fix that only handled atoms would work in
      # tests and fail over HTTP — which is the only path clients use.
      assert {:ok, doc} =
               Knowledge.create_document(%{
                 "kind" => "NOTE",
                 "scope" => "test",
                 "title" => "strings",
                 "slug" => "string-keys",
                 "body_md" => "x",
                 "author" => "via-http"
               })

      assert doc.created_by == "via-http"
    end

    test "neither supplied is still an error — the requirement is not removed" do
      assert {:error, cs} =
               Knowledge.create_document(%{
                 kind: "NOTE",
                 scope: "test",
                 title: "neither",
                 slug: "neither-given",
                 body_md: "x"
               })

      assert errors_on(cs)[:created_by] || errors_on(cs)[:author]
    end
  end
end
