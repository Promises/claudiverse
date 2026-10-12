defmodule ClaudiverseServer.TasksTest do
  @moduledoc """
  Component E's acceptance criteria. Each names the measured defect it kills.
  """
  use ClaudiverseServer.DataCase, async: false

  alias ClaudiverseServer.Tasks

  defp task(over \\ %{}) do
    {:ok, t} =
      Tasks.create(
        Map.merge(
          %{fleet: "lorem-fleet", lane: "lorem-tasks", title: "match 0x336B88", created_by: "orch"},
          over
        )
      )

    t
  end

  describe "E-1 — an unclaimable task is impossible, not merely warned about" do
    test "a new task is DRAFT and CANNOT be claimed until made READY" do
      t = task()
      assert t.state == "DRAFT"

      # Today: a post created without status=incoming is invisible to the claim
      # query and fails SILENTLY — warned about in five channel descriptions,
      # which makes it a schema gap rather than a usage error.
      assert {:error, :none_ready} = Tasks.claim("lorem-fleet", "lorem-tasks", "w1")

      {:ok, _} = Tasks.make_ready(t.id, "orch")
      assert {:ok, claimed} = Tasks.claim("lorem-fleet", "lorem-tasks", "w1")
      assert claimed.id == t.id
    end

    test "READY at creation is claimable immediately" do
      t = task(%{state: "READY"})
      assert {:ok, c} = Tasks.claim("lorem-fleet", "lorem-tasks", "w1")
      assert c.id == t.id
    end
  end

  describe "E-2 — priority is a FIELD, so it cannot be prose that misdirects" do
    test "the claim takes the highest priority, not the oldest" do
      _low = task(%{state: "READY", priority: 0, title: "low"})
      high = task(%{state: "READY", priority: 10, title: "high"})

      # ⭐ The cause of the #22557 strand: with no priority field, ordering lived
      # as prose in a body ("TAKE #22445 FIRST"), and prose can redirect a
      # worker away from the task its runner is tracking.
      assert {:ok, c} = Tasks.claim("lorem-fleet", "lorem-tasks", "w1")
      assert c.id == high.id
    end

    test "two runners racing cannot both win" do
      task(%{state: "READY"})
      assert {:ok, _} = Tasks.claim("lorem-fleet", "lorem-tasks", "w1")
      assert {:error, :none_ready} = Tasks.claim("lorem-fleet", "lorem-tasks", "w2")
    end

    test "a vm_required task is skipped while the VM is busy" do
      vm = task(%{state: "READY", priority: 10, vm_required: true, title: "needs vm"})
      other = task(%{state: "READY", priority: 0, title: "no vm"})

      # The single-owner colima VM: today workers hand-check `docker ps` and
      # yield by convention.
      assert {:ok, c} = Tasks.claim("lorem-fleet", "lorem-tasks", "w1", vm_busy: true)
      assert c.id == other.id
      refute c.id == vm.id

      # and it IS claimable once the VM frees
      assert {:ok, c2} = Tasks.claim("lorem-fleet", "lorem-tasks", "w2", vm_busy: false)
      assert c2.id == vm.id
    end
  end

  describe "the reap contract — the #22557 / #22445 sequence, replayed" do
    test "completing a DIFFERENT task strands and RELEASES the held one" do
      held = task(%{state: "READY", title: "#22557"})
      other = task(%{state: "READY", title: "#22445"})

      {:ok, _} = Tasks.claim("lorem-fleet", "lorem-tasks", "w2")
      {:ok, _} = Tasks.start(held.id, "w2")

      # The worker obeyed prose in the body and completed the OTHER task.
      {:ok, %{stranded: stranded}} = Tasks.complete(other.id, "w2", held_task_id: held.id)

      # Today this waits forever for a signal that cannot arrive: one slot,
      # ~1h, freed only by a hand tmux kill-session.
      assert stranded
      assert stranded.id == held.id
      assert stranded.state == "READY", "the held task must return to the claimable pool"
      refute stranded.claimed_by, "and must not still name a holder"

      # ⭐ and the strand is a LOGGED EVENT, not lost tmux scrollback
      kinds = Tasks.events(held.id) |> Enum.map(& &1.kind)
      assert "STRANDED" in kinds

      # the completion is HONOURED — refusing it would discard real work to
      # protect a bookkeeping rule — and the missing claim is recorded rather
      # than papered over
      assert Tasks.get(other.id).state == "DONE"

      adopted =
        Tasks.events(other.id)
        |> Enum.find(&(&1.kind == "CLAIMED" and &1.detail =~ "never formally claimed"))

      assert adopted, "an adopted completion must say the claim was never made"
      assert Tasks.get(other.id).claimed_by == "w2"
    end

    test "completing the task you hold is unremarkable" do
      t = task(%{state: "READY"})
      {:ok, _} = Tasks.claim("lorem-fleet", "lorem-tasks", "w1")
      {:ok, _} = Tasks.start(t.id, "w1")

      assert {:ok, %{stranded: nil}} = Tasks.complete(t.id, "w1", held_task_id: t.id)
      assert Tasks.get(t.id).state == "DONE"
    end

    test "RELEASE is a first-class transition, not an improvisation" do
      t = task(%{state: "READY"})
      {:ok, _} = Tasks.claim("lorem-fleet", "lorem-tasks", "w1")

      assert {:ok, back} = Tasks.release(t.id, "w1", "needs the VM, which is held")
      assert back.state == "READY"
      refute back.claimed_by
      assert "RELEASED" in (Tasks.events(t.id) |> Enum.map(& &1.kind))
    end

    test "a declined task is not handed back to the slot that declined it" do
      # A seat-check decline releases the task, and it is still the top of the
      # lane. MEASURED 2026-09-27 on lorem-fleet: with no way to decline, one declining
      # validator held its seat for 2h40m because it could not close undone work.
      declined = task(%{state: "READY", priority: 9})
      other = task(%{state: "READY", priority: 1})

      {:ok, _} = Tasks.claim("lorem-fleet", "lorem-tasks", "w1")
      {:ok, _} = Tasks.release(declined.id, "w1", "seat check: w1 produced the figures")

      assert {:ok, next} = Tasks.claim("lorem-fleet", "lorem-tasks", "w1", exclude: [declined.id])
      assert next.id == other.id

      # Excluding is per caller: another slot still gets the declined task.
      assert {:ok, taken} = Tasks.claim("lorem-fleet", "lorem-tasks", "w2")
      assert taken.id == declined.id
    end

    test "excluding every READY task is an empty queue, not an error" do
      t = task(%{state: "READY"})
      assert {:error, :none_ready} = Tasks.claim("lorem-fleet", "lorem-tasks", "w1", exclude: [t.id])
      assert {:ok, _} = Tasks.claim("lorem-fleet", "lorem-tasks", "w1", exclude: [])
    end
  end

  describe "dependencies — 'do X first' is an edge, not a sentence" do
    test "a task with an unmet BLOCKS dep cannot become READY" do
      blocker = task(%{title: "land the revert"})
      dependent = task(%{title: "resume the fleet"})
      {:ok, _} = Tasks.add_dep(dependent.id, blocker.id, "BLOCKS", "orch")

      assert {:error, {:blocked_by, [id]}} = Tasks.make_ready(dependent.id, "orch")
      assert id == blocker.id
      assert Tasks.get(dependent.id).state == "DRAFT"

      # once the blocker is DONE, it goes READY
      {:ok, _} = Tasks.make_ready(blocker.id, "orch")
      {:ok, _} = Tasks.claim("lorem-fleet", "lorem-tasks", "w1")
      {:ok, _} = Tasks.start(blocker.id, "w1")
      {:ok, _} = Tasks.complete(blocker.id, "w1", held_task_id: blocker.id)

      assert {:ok, r} = Tasks.make_ready(dependent.id, "orch")
      assert r.state == "READY"
    end

    test "make_ready is idempotent — calling it on a READY task is a no-op" do
      t = task(%{state: "READY"})
      assert {:ok, again} = Tasks.make_ready(t.id, "orch")
      assert again.state == "READY"
    end

    test "a BLOCKS dep added AFTER a task is READY still prevents the claim" do
      blocker = task(%{title: "must land first"})
      dependent = task(%{state: "READY", title: "already published"})

      # ⛔ FOUND BY USING IT. make_ready/2 refuses to publish a blocked task, but
      # adding the edge to an ALREADY-READY task does not demote it — so the
      # dependency was advisory exactly when it mattered. Task #4 read as READY
      # while displaying "blocked by: 6".
      {:ok, _} = Tasks.add_dep(dependent.id, blocker.id, "BLOCKS", "orch")

      assert Tasks.get(dependent.id).state == "READY", "the state is unchanged, by design"
      assert {:error, :none_ready} = Tasks.claim("lorem-fleet", "lorem-tasks", "w1"),
             "but it must NOT be claimable while its blocker is open"

      # once the blocker completes, it becomes claimable without further action
      {:ok, _} = Tasks.make_ready(blocker.id, "orch")
      {:ok, _} = Tasks.claim("lorem-fleet", "lorem-tasks", "w9")
      {:ok, _} = Tasks.complete(blocker.id, "w9", held_task_id: blocker.id)

      assert {:ok, got} = Tasks.claim("lorem-fleet", "lorem-tasks", "w1")
      assert got.id == dependent.id
    end

    test "INFORMS does not block" do
      a = task()
      b = task()
      {:ok, _} = Tasks.add_dep(b.id, a.id, "INFORMS", "orch")
      assert {:ok, r} = Tasks.make_ready(b.id, "orch")
      assert r.state == "READY"
    end

    test "a task cannot depend on itself" do
      a = task()
      assert {:error, cs} = Tasks.add_dep(a.id, a.id, "BLOCKS", "orch")
      assert errors_on(cs).depends_on_task_id |> hd() =~ "cannot depend on itself"
    end
  end

  describe "E-3 — starvation is computable" do
    test "a lane with a live runner and zero READY tasks is STARVED" do
      task(%{state: "READY", lane: "lorem-tasks"})

      # ⚠️ Zero-READY alone is ambiguous: a claimed task leaves the ready set, so
      # a fed-and-working lane and a starving one produce the identical count.
      # Liveness comes from the caller.
      assert Tasks.starving_lanes("lorem-fleet", ["lorem-tasks", "lorem-analysis"]) == ["lorem-analysis"]

      {:ok, _} = Tasks.claim("lorem-fleet", "lorem-tasks", "w1")

      # now BOTH are starved — and this is the state that read as healthy
      assert Tasks.starving_lanes("lorem-fleet", ["lorem-tasks", "lorem-analysis"]) ==
               ["lorem-tasks", "lorem-analysis"]
    end

    test "stranded_tasks finds a claim whose worker is gone" do
      t = task(%{state: "READY"})
      {:ok, _} = Tasks.claim("lorem-fleet", "lorem-tasks", "w1")

      assert Tasks.stranded_tasks("lorem-fleet", ["w1"]) == []
      assert [found] = Tasks.stranded_tasks("lorem-fleet", ["w2"])
      assert found.id == t.id
    end
  end

  describe "E-5 — the validation graph is traversable" do
    test "a chain is walked in one call" do
      a = task(%{title: "measure"})
      b = task(%{title: "validate a", validates_task_id: a.id})
      c = task(%{title: "validate b", validates_task_id: b.id})

      # Today this is title convention, and tracing one result meant hand-walking
      # #22585 -> #22443 -> #22538 -> #22726 -> #22771.
      assert Tasks.validation_chain(c.id) |> Enum.map(& &1.id) == [a.id, b.id, c.id]
    end
  end

  describe "state model" do
    test "a forbidden jump is refused, naming both ends" do
      t = task()
      assert {:error, cs} = Tasks.start(t.id, "w1")
      assert errors_on(cs).state |> hd() =~ "DRAFT -> RUNNING"
    end

    test "a CLAIMED task must name its holder" do
      t = task(%{state: "READY"})

      assert {:error, cs} =
               t
               |> ClaudiverseServer.Tasks.Task.transition_changeset("CLAIMED", %{})
               |> Repo.update()

      assert errors_on(cs).claimed_by |> hd() =~ "must name its holder"
    end
  end

  describe "E-9 — a brief can be corrected before it is claimed, never after" do
    test "a DRAFT's brief can be edited, and the edit is recorded as an event" do
      t = task(%{body_md: "read the plate"})

      {:ok, edited} = Tasks.update_draft(t.id, %{body_md: "STEP 1: cv_address first"}, "orch")
      assert edited.body_md == "STEP 1: cv_address first"
      assert edited.title == t.title

      # The audit record is the point of the guard. log/4 ignores its own insert
      # result, so an unvalidated event kind would vanish with no error and the
      # edit would be unattributable — the defect this assertion exists to catch.
      kinds = ClaudiverseServer.Repo.all(ClaudiverseServer.Tasks.TaskEvent) |> Enum.map(& &1.kind)
      assert "EDITED" in kinds
    end

    test "a CLAIMED task refuses the edit — its worker is already reading the brief" do
      t = task(%{body_md: "original"})
      {:ok, _} = Tasks.make_ready(t.id, "orch")
      {:ok, _} = Tasks.claim("lorem-fleet", "lorem-tasks", "w1")

      assert {:error, {:not_editable, "CLAIMED"}} = Tasks.update_draft(t.id, %{body_md: "rewritten"}, "orch")
      assert Tasks.get(t.id).body_md == "original"
    end

    test "state and claim are the state machine's — an edit cannot reach them" do
      t = task()

      {:ok, edited} =
        Tasks.update_draft(t.id, %{state: "DONE", claimed_by: "nobody", title: "retitled"}, "orch")

      assert edited.title == "retitled"
      assert edited.state == "DRAFT"
      assert is_nil(edited.claimed_by)
    end

    test "an edit naming no editable field is refused, not silently a no-op" do
      t = task()
      assert {:error, :nothing_to_update} = Tasks.update_draft(t.id, %{state: "DONE"}, "orch")
    end
  end


  describe "E-10 — anonymous authority is refused, not silently accepted" do
    test "publishing a task without an actor is refused" do
      t = task()
      assert {:error, :actor_required} = Tasks.make_ready(t.id, nil)
      assert {:error, :actor_required} = Tasks.make_ready(t.id, "   ")
      assert Tasks.get(t.id).state == "DRAFT"

      # #18 was published to the fleet by a blank actor and the log could only
      # record THAT it happened. make_ready/2 defaulted actor to nil and took it.
      {:ok, r} = Tasks.make_ready(t.id, "orch")
      assert r.state == "READY"
    end

    test "a BLOCKS edge without an actor is refused — it decides what may be claimed" do
      a = task()
      b = task()
      assert {:error, :actor_required} = Tasks.add_dep(b.id, a.id, "BLOCKS")
      assert Tasks.unmet_blockers(b.id) == []

      {:ok, _} = Tasks.add_dep(b.id, a.id, "BLOCKS", "orch")
      assert [_] = Tasks.unmet_blockers(b.id)

      kinds = ClaudiverseServer.Repo.all(ClaudiverseServer.Tasks.TaskEvent) |> Enum.map(& &1.kind)
      assert "DEP_ADDED" in kinds
    end
  end


  describe "E-11 — an unclaimed brief can be corrected; a claimed one cannot" do
    test "a READY task is editable — gating a task must not freeze it" do
      t = task(%{body_md: "control that cannot fail"})
      {:ok, _} = Tasks.make_ready(t.id, "orch")

      # The defect this kills: restricting edits to DRAFT froze every READY task.
      # Nine REF-TRIAGE briefs carrying a vacuous control sat unrepairable behind
      # a gate precisely BECAUSE gating them had made them READY.
      {:ok, edited} = Tasks.update_draft(t.id, %{body_md: "patch-id landing map"}, "orch")
      assert edited.body_md == "patch-id landing map"
      assert edited.state == "READY"
    end

    test "a CLAIMED task still refuses — that is the property being protected" do
      t = task(%{body_md: "original"})
      {:ok, _} = Tasks.make_ready(t.id, "orch")
      {:ok, _} = Tasks.claim("lorem-fleet", "lorem-tasks", "w1")

      assert {:error, {:not_editable, "CLAIMED"}} =
               Tasks.update_draft(t.id, %{body_md: "rewritten"}, "orch")

      assert Tasks.get(t.id).body_md == "original"
    end
  end

  describe "E-12 — a task that should not be done is retired, not falsely completed" do
    test "supersede records what replaced it and makes the task unclaimable" do
      done_by = task()
      dup = task()
      {:ok, _} = Tasks.make_ready(dup.id, "orch")

      {:ok, s} = Tasks.supersede(dup.id, done_by.id, "lorem-admin")
      assert s.state == "SUPERSEDED"
      assert s.superseded_by == done_by.id

      # The point: it leaves the ready set without wearing a DONE nobody earned.
      assert {:error, :none_ready} = Tasks.claim("lorem-fleet", "lorem-tasks", "w1")
    end

    test "supersede refuses without a replacement, and without an actor" do
      t = task()
      assert {:error, :superseded_by_required} = Tasks.supersede(t.id, nil, "lorem-admin")
      assert {:error, :actor_required} = Tasks.supersede(t.id, 1, nil)
      assert Tasks.get(t.id).state == "DRAFT"
    end
  end

end
