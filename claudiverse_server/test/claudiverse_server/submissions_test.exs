defmodule ClaudiverseServer.SubmissionsTest do
  @moduledoc """
  Component B's invariants, each with the failure it prevents.
  """
  use ClaudiverseServer.DataCase, async: false

  alias ClaudiverseServer.Knowledge.Submission
  alias ClaudiverseServer.Submissions

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        address: "0x00336B88",
        unit: "text/336000",
        build: "usa_v200",
        tier: "T1",
        base_sha: "abc123def456",
        compiler: "ee-gcc 2.9-ee-991111",
        flags: "-O2 -G0",
        body_c: "void GuiComputeBlendWeights(void) {}",
        submitted_by: "lorem-w1"
      },
      overrides
    )
  end

  defp pass_gate(sub, overrides \\ %{}) do
    Submissions.record_gate(
      sub.id,
      Map.merge(
        %{
          gate_name: "objdiff_unit",
          verdict: "PASS",
          raw_output: "336B88 GuiComputeBlendWeights 100.00%",
          positive_control_output: "seeded 1-byte change -> 99.61%, gate FAILED as expected",
          runner: "test"
        },
        overrides
      )
    )
  end

  describe "invariant 1 — durability is the acceptance" do
    test "a submission is committed and readable the instant submit returns" do
      assert {:ok, sub} = Submissions.submit(attrs())
      assert sub.id

      # Nothing else had to happen. No branch, no push, no ref surviving a reap.
      assert %{submission: read} = Submissions.get(sub.id)
      assert read.state == "SUBMITTED"
      assert read.body_c =~ "GuiComputeBlendWeights"
      assert read.body_hash
    end

    test "addresses are normalised, so one function is ONE identity" do
      # Spelled three ways across this project. Stored as typed, the same
      # function occupies several identities and a supersede silently fails to
      # find its predecessor.
      for spelling <- ["0x00336B88", "func_00336b88", "00336B88", "FUN_00336B88"] do
        assert Submission.normalise(spelling) == "00336b88"
      end

      {:ok, a} = Submissions.submit(attrs(%{address: "0x00336B88"}))
      {:ok, b} = Submissions.submit(attrs(%{address: "func_00336b88"}))

      assert Repo.reload(a).state == "SUPERSEDED"
      assert Repo.reload(a).superseded_by == b.id
    end
  end

  describe "invariant 2 — state moves only along declared transitions" do
    test "a forbidden jump is refused, naming both ends" do
      {:ok, sub} = Submissions.submit(attrs())

      # ⛔ SUBMITTED -> INTEGRATED would mean "it is in master" with no gate
      # ever having run. GATE_PASS, INTEGRATED and AUDITED are three different
      # claims with three different amounts of evidence.
      assert {:error, cs} = Submissions.transition(sub.id, "INTEGRATED")
      assert errors_on(cs).state |> hd() =~ "SUBMITTED -> INTEGRATED"
    end

    test "a terminal state says so rather than failing vaguely" do
      {:ok, sub} = Submissions.submit(attrs())
      {:ok, _} = Submissions.transition(sub.id, "RETRACTED")

      assert {:error, cs} = Submissions.transition(sub.id, "GATING")
      assert errors_on(cs).state |> hd() =~ "terminal"
    end
  end

  describe "invariant 3 — a PASS must carry its output" do
    test "a PASS with no raw_output is refused" do
      {:ok, sub} = Submissions.submit(attrs())

      # Every single-instrument gate in this project has been observed lying. A
      # verdict can be re-derived from output; it cannot be re-derived from a
      # flag, so an unauditable PASS is refused outright.
      assert {:error, cs} = pass_gate(sub, %{raw_output: nil})
      assert errors_on(cs).raw_output |> hd() =~ "must carry its output"
    end

    test "a FAIL may be empty — the asymmetry is deliberate" do
      {:ok, sub} = Submissions.submit(attrs())
      assert {:ok, _} = pass_gate(sub, %{verdict: "FAIL", raw_output: nil})
      assert Repo.reload(sub).state == "GATE_FAIL"
    end

    test "the state follows the WORST verdict, not the last one written" do
      {:ok, sub} = Submissions.submit(attrs())
      assert {:ok, _} = pass_gate(sub, %{gate_name: "a"})
      assert Repo.reload(sub).state == "GATE_PASS"

      assert {:ok, _} = pass_gate(sub, %{gate_name: "b", verdict: "FAIL"})
      assert Repo.reload(sub).state == "GATE_FAIL"

      # ⭐ And a later PASS must NOT paper over the earlier FAIL. Ordering would
      # otherwise turn "3 passed, 1 failed" into a pass.
      assert {:ok, _} = pass_gate(sub, %{gate_name: "c"})
      assert Repo.reload(sub).state == "GATE_FAIL"
    end
  end

  describe "invariant 4 — a stale base_sha cannot be integrated" do
    test "integrating at a different sha than was gated is REFUSED" do
      {:ok, sub} = Submissions.submit(attrs(%{base_sha: "old111111111"}))
      {:ok, _} = pass_gate(sub)

      assert {:error, why} = Submissions.integrate(sub.id, "new222222222", "integrator")
      assert why =~ "re-gate at HEAD"

      # and it did NOT move
      assert Repo.reload(sub).state == "GATE_PASS"
      refute Submissions.integration_for(sub.id)
    end

    test "integrating without a passing gate is REFUSED" do
      {:ok, sub} = Submissions.submit(attrs())
      assert {:error, why} = Submissions.integrate(sub.id, "abc123def456", "integrator")
      assert why =~ "nothing has passed a gate"
    end

    test "integrating at the gated sha succeeds" do
      {:ok, sub} = Submissions.submit(attrs(%{base_sha: "abc123def456"}))
      {:ok, _} = pass_gate(sub)

      assert {:ok, int} = Submissions.integrate(sub.id, "abc123def456", "integrator")
      assert int.integrated_sha == "abc123def456"
      assert Repo.reload(sub).state == "INTEGRATED"
    end
  end

  describe "invariant 5 — body_c is dropped at integration" do
    test "the C survives until integrated, then only the hash remains" do
      {:ok, sub} = Submissions.submit(attrs())
      hash = sub.body_hash
      {:ok, _} = pass_gate(sub)

      assert Repo.reload(sub).body_c =~ "GuiComputeBlendWeights"

      {:ok, _} = Submissions.integrate(sub.id, "abc123def456", "integrator")

      after_ = Repo.reload(sub)
      # Keeping it would put the C in two places — the second-source-of-truth
      # failure this design exists to avoid.
      refute after_.body_c
      # but the claim "this is what was integrated" stays checkable
      assert after_.body_hash == hash
    end
  end

  describe "the acceptance query — gates that could not have failed" do
    test "a gate with no positive control is FINDABLE" do
      {:ok, a} = Submissions.submit(attrs(%{address: "0x1000"}))
      {:ok, b} = Submissions.submit(attrs(%{address: "0x2000"}))

      {:ok, _} = pass_gate(a)
      {:ok, _} = pass_gate(b, %{positive_control_output: nil})

      # ⭐ The acceptance criterion names this query and requires the set empty.
      # A gate that cannot fail reports PASS forever and nothing else tells it
      # apart from one that works.
      found = Submissions.gates_without_positive_control()
      assert length(found) == 1
      assert hd(found).submission_id == b.id
    end
  end

  describe "revert" do
    test "a revert must say why" do
      {:ok, sub} = Submissions.submit(attrs())
      {:ok, _} = pass_gate(sub)
      {:ok, _} = Submissions.integrate(sub.id, "abc123def456", "integrator")

      assert {:error, cs} = Submissions.revert(sub.id, "  ")
      assert errors_on(cs).revert_reason |> hd() =~ "must say why"

      assert {:ok, int} = Submissions.revert(sub.id, "broke the link at 0x1B4218")
      assert int.reverted_at
      assert Repo.reload(sub).state == "RETRACTED"
    end
  end
end
