defmodule ClaudiverseServer.Tasks do
  @moduledoc """
  Component E — claimable work with a real state model.

  Preserved unchanged because they are sound: atomic claim, one worker per
  task, ephemeral workers, reap on exactly one signal, lane-as-routing.

  ## The reap contract, bound

  The runner reaps on `task_done` FOR THE TASK IT CLAIMED. Today a worker
  completing a *different* task produces a permanent strand with no error
  anywhere: `#22557`'s body said "TAKE #22445 FIRST", the worker complied,
  completed `#22445`, and the runner waited on `#22557` for a signal that could
  never arrive. One slot, ~1h, freed only by a hand `tmux kill-session`.

  Here that is a DETECTABLE PROTOCOL VIOLATION: `complete/3` called by a worker
  holding a different task records a STRANDED event, releases the held task
  back to READY, and frees the slot — automatically.
  """
  import Ecto.Query

  alias ClaudiverseServer.Repo
  alias ClaudiverseServer.Tasks.{Task, TaskDep, TaskEvent}

  # ── create ─────────────────────────────────────────────────────────────────

  def create(attrs) do
    attrs = stringify(attrs)

    Repo.transaction(fn ->
      case %Task{} |> Task.changeset(attrs) |> Repo.insert() do
        {:ok, task} ->
          log(task, "CREATED", attrs["created_by"])
          if task.state == "READY", do: log(task, "READY", attrs["created_by"])
          task

        {:error, cs} ->
          Repo.rollback(cs)
      end
    end)
  end

  @doc """
  Move a task to READY, refusing while a BLOCKS dependency is unmet.

  A task with an unmet BLOCKS dep is never claimable — so "do X first" stops
  being prose a worker can misread and becomes a condition the scheduler
  enforces.
  """
  def make_ready(id, actor \\ nil) do
    with :ok <- require_actor(actor),
         %Task{} = task <- get(id),
         [] <- unmet_blockers(id) do
      # Idempotent: "make this claimable" called on an already-claimable task is
      # a no-op, not an error. Otherwise every caller has to check first, and
      # the one that forgets gets a state-machine error for doing nothing wrong.
      if task.state == "READY", do: {:ok, task}, else: transition(task, "READY", actor)
    else
      nil -> {:error, :no_such_task}
      blockers when is_list(blockers) -> {:error, {:blocked_by, Enum.map(blockers, & &1.id)}}
      other -> other
    end
  end

  def unmet_blockers(task_id) do
    from(d in TaskDep,
      join: t in Task,
      on: t.id == d.depends_on_task_id,
      where: d.task_id == ^task_id and d.kind == "BLOCKS" and t.state not in ["DONE", "VALIDATED"],
      select: t
    )
    |> Repo.all()
  end

  def add_dep(task_id, depends_on_id, kind \\ "BLOCKS", actor \\ nil) do
    with :ok <- require_actor(actor),
         {:ok, dep} <-
           %TaskDep{}
           |> TaskDep.changeset(%{task_id: task_id, depends_on_task_id: depends_on_id, kind: kind})
           |> Repo.insert() do
      # A BLOCKS edge decides what a worker may claim, so it is an authority
      # change and needs the same attribution as a state change. Every edge on
      # the board today is unattributed because this took no actor at all.
      if t = get(task_id), do: log(t, "DEP_ADDED", actor, "#{kind} <- ##{depends_on_id}")
      {:ok, dep}
    end
  end

  # An actor-less mutation is anonymous authority: it changes what workers may
  # claim and leaves no one to ask about it. #18 was published to the fleet by a
  # blank actor and the event log could only say that it happened, not who. nil
  # was accepted silently because the parameter defaulted to it.
  defp require_actor(actor) do
    if is_binary(actor) and String.trim(actor) != "", do: :ok, else: {:error, :actor_required}
  end

  # ── claim ──────────────────────────────────────────────────────────────────

  @doc """
  Atomically claim the highest-priority READY task in a lane.

  Priority is an INTEGER here. That is E-2's fix at the cause: with no priority
  field, ordering was expressed as prose in a body, and prose can redirect a
  worker away from the task the runner is tracking.

  `vm_required` tasks are skipped when `vm_busy: true`, so the single-owner
  colima VM stops being managed by convention.

  `exclude: [id]` skips tasks the CALLER has declined. A decline releases the
  task to READY, where it is still the top of its lane — so without this the
  declining slot re-claims it on its next poll, and the seat that could take
  it waits behind a loop.
  """
  def claim(fleet, lane, worker, opts \\ []) do
    # 🔴 `mode: :immediate` — same defect as Forum.set_handoff: this READS the
    # next claimable task and then UPDATEs it, and a DEFERRED read->write upgrade
    # fails instantly with SQLITE_BUSY in WAL mode when another connection
    # committed in between. MEASURED: 5 of 29 "Database busy" errors in 30 h of
    # the live log were this UPDATE (tasks.ex claim). The row-level re-check of
    # `state == READY` below still decides a race between two runners; this only
    # stops the loser from getting an exception instead of :lost_race.
    Repo.transaction(fn ->
      # ⛔ EXCLUDE tasks with an unmet BLOCKS dependency, at CLAIM time.
      #
      # make_ready/2 already refuses to publish a blocked task, but that only
      # guarantees "cannot be made ready while blocked" — not "cannot be claimed
      # while blocked". Adding a BLOCKS edge to an ALREADY-READY task does not
      # demote it, so the dependency was advisory in practice. Found by using
      # it: task #4 read as READY while displaying "blocked by: 6".
      #
      # Claim time is the right gate because it is the moment the guarantee is
      # needed, and it holds however the task reached READY.
      blocked =
        from(d in TaskDep,
          join: b in Task,
          on: b.id == d.depends_on_task_id,
          where: d.kind == "BLOCKS" and b.state not in ["DONE", "VALIDATED"],
          select: d.task_id
        )

      q =
        from(t in Task,
          where: t.fleet == ^fleet and t.lane == ^lane and t.state == ^Task.claimable_state(),
          where: t.id not in subquery(blocked),
          order_by: [desc: t.priority, asc: t.id],
          limit: 1
        )

      q = if opts[:vm_busy], do: where(q, [t], t.vm_required == false), else: q

      q =
        case opts[:exclude] do
          [_ | _] = ids -> where(q, [t], t.id not in ^ids)
          _ -> q
        end

      case Repo.one(q) do
        nil ->
          Repo.rollback(:none_ready)

        task ->
          # The UPDATE re-asserts state == READY, so two runners racing cannot
          # both win: the loser updates 0 rows.
          {n, _} =
            from(t in Task, where: t.id == ^task.id and t.state == ^Task.claimable_state())
            |> Repo.update_all(
              set: [
                state: "CLAIMED",
                claimed_by: worker,
                claimed_at: DateTime.utc_now() |> DateTime.truncate(:second),
                updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
              ]
            )

          if n == 1 do
            task = Repo.get(Task, task.id)
            log(task, "CLAIMED", worker)
            task
          else
            Repo.rollback(:lost_race)
          end
      end
    end, mode: :immediate)
  end

  def start(id, worker), do: id |> get() |> transition("RUNNING", worker, started_at: now())

  def progress(id, worker, detail \\ nil) do
    case get(id) do
      nil -> {:error, :no_such_task}
      task -> log(task, "PROGRESS", worker, detail)
    end
  end

  @doc """
  Hand a task back un-started. A first-class transition, not an improvisation.
  """
  def release(id, worker, reason \\ nil) do
    case get(id) do
      nil ->
        {:error, :no_such_task}

      task ->
        with {:ok, t} <- transition(task, "RELEASED", worker, claimed_by: nil, claimed_at: nil) do
          log(t, "RELEASED", worker, reason)
          transition(t, "READY", worker)
        end
    end
  end

  # ── complete, and the protocol violation it can detect ─────────────────────

  @doc """
  Complete a task.

  `held_task_id` is what the RUNNER believes this worker is holding. When it
  disagrees with `id`, that is the `#22557`/`#22445` sequence: the completion
  is honoured (the work is real), and the held task is STRANDED and released so
  the slot frees itself instead of waiting forever for a signal that cannot
  arrive.
  """
  def complete(id, worker, opts \\ []) do
    held = opts[:held_task_id]

    case get(id) do
      nil ->
        {:error, :no_such_task}

      task ->
        # ⭐ The worker may be completing a task it never claimed — which is
        # exactly what happened in the #22557/#22445 incident. The WORK IS REAL,
        # so refusing the completion would discard it to protect a bookkeeping
        # rule. Instead record what actually occurred: the worker ADOPTED the
        # task. That keeps the state machine honest (no READY -> DONE edge) and
        # leaves an event saying the claim was never made.
        task = adopt_if_unclaimed(task, worker)
        result = transition(task, "DONE", worker, completed_at: now())

        stranded =
          if held && held != id do
            strand(held, worker, "worker completed ##{id} while holding ##{held}")
          end

        case result do
          {:ok, t} -> {:ok, %{task: t, stranded: stranded}}
          err -> err
        end
    end
  end

  defp adopt_if_unclaimed(%Task{state: "RUNNING"} = task, worker) when not is_nil(worker), do: task

  # A worker that claimed and then completed WITHOUT emitting START is doing the
  # normal thing; only the bookkeeping step is missing. Advance it rather than
  # refusing the completion — the same reasoning as adoption below. Refusing
  # would discard real work to protect a state label.
  defp adopt_if_unclaimed(%Task{state: "CLAIMED"} = task, worker) when not is_nil(worker) do
    case transition(task, "RUNNING", worker, started_at: now()) do
      {:ok, t} -> t
      _ -> task
    end
  end

  defp adopt_if_unclaimed(%Task{state: "READY"} = task, worker) do
    log(task, "CLAIMED", worker, "adopted at completion — never formally claimed")

    with {:ok, t} <-
           transition(task, "CLAIMED", worker,
             claimed_by: worker,
             claimed_at: now()
           ),
         {:ok, t} <- transition(t, "RUNNING", worker, started_at: now()) do
      t
    else
      _ -> task
    end
  end

  defp adopt_if_unclaimed(task, _worker), do: task

  defp strand(held_id, worker, detail) do
    case get(held_id) do
      nil ->
        nil

      held ->
        log(held, "STRANDED", worker, detail)
        # Release it so the slot is reusable without a hand kill-session.
        case transition(held, "READY", worker, claimed_by: nil, claimed_at: nil) do
          {:ok, t} -> t
          _ -> held
        end
    end
  end

  # ── emitted conditions ─────────────────────────────────────────────────────

  @doc """
  Lanes with a live runner, no halt, and zero READY tasks.

  E-3: starvation is not an event today. `cv-runner` does not error, exit or
  ping on an empty queue — it simply stops claiming, which from outside is
  indistinguishable from working. Queues emptied three times over 2026-09-05/06
  and EVERY instance was found by an hourly human sweep.

  ⚠️ The caller supplies which lanes have live runners. "Zero READY" alone is
  ambiguous: a fed-and-working lane and a starving one produce the identical
  count, because a claimed task leaves the ready set.
  """
  def starving_lanes(fleet, live_lanes) do
    ready =
      from(t in Task,
        where: t.fleet == ^fleet and t.state == ^Task.claimable_state(),
        group_by: t.lane,
        select: {t.lane, count(t.id)}
      )
      |> Repo.all()
      |> Map.new()

    Enum.filter(live_lanes, fn lane -> Map.get(ready, lane, 0) == 0 end)
  end

  @doc """
  Tasks claimed but with no live worker session.

  ⚠️ The caller supplies the live session list. The server cannot see tmux, and
  inferring liveness from elapsed time alone would call a slow task dead.
  """
  def stranded_tasks(fleet, live_workers) do
    from(t in Task,
      where: t.fleet == ^fleet and t.state in ["CLAIMED", "RUNNING"] and t.claimed_by not in ^live_workers
    )
    |> Repo.all()
  end

  @doc """
  RUNNING tasks with no PROGRESS event newer than `minutes`.

  ⚠️ This samples SILENCE, which is why it is advisory only. A quota-dead seat
  reported "busy" for four and a half hours, and qemu sat at 162% and 309%
  while genuinely building. Confirm with the runner's CPU-tree sampling before
  acting — do not reap on this alone.
  """
  def stalled_tasks(fleet, minutes \\ 45) do
    cutoff = DateTime.utc_now() |> DateTime.add(-minutes * 60, :second)

    latest =
      from(e in TaskEvent,
        where: e.kind in ["PROGRESS", "STARTED", "CLAIMED"],
        group_by: e.task_id,
        select: {e.task_id, max(e.at)}
      )
      |> Repo.all()
      |> Map.new()

    from(t in Task, where: t.fleet == ^fleet and t.state == "RUNNING")
    |> Repo.all()
    |> Enum.filter(fn t ->
      case Map.get(latest, t.id) do
        nil -> true
        at -> DateTime.compare(at, cutoff) == :lt
      end
    end)
  end

  # ── read ───────────────────────────────────────────────────────────────────

  def get(id), do: Repo.get(Task, id)

  def list(opts \\ []) do
    Task
    |> filter(:fleet, opts[:fleet])
    |> filter(:lane, opts[:lane])
    |> filter(:state, opts[:state])
    |> filter(:claimed_by, opts[:claimed_by])
    |> order_by([t], desc: t.priority, asc: t.id)
    |> limit(^(opts[:limit] || 50))
    |> Repo.all()
  end

  defp filter(q, _f, nil), do: q
  defp filter(q, f, v), do: where(q, [t], field(t, ^f) == ^v)

  def events(task_id) do
    from(e in TaskEvent, where: e.task_id == ^task_id, order_by: [asc: e.at, asc: e.id])
    |> Repo.all()
  end

  @doc """
  The validation chain for a task, walked in one call.

  E-5: this was title convention ("VALIDATE #21672"), so tracing one result
  meant hand-walking #22585 -> #22443 -> #22538 -> #22726 -> #22771.
  """
  def validation_chain(task_id, acc \\ []) do
    case get(task_id) do
      nil ->
        acc

      task ->
        # Prepending as we walk toward the root already yields root-first order;
        # the reverse this used to do undid exactly that.
        acc = [task | acc]

        if task.validates_task_id && task.validates_task_id not in Enum.map(acc, & &1.id),
          do: validation_chain(task.validates_task_id, acc),
          else: acc
    end
  end

  # ── internals ──────────────────────────────────────────────────────────────

  @doc """
  Edit an UNCLAIMED task's brief.

  The safety property is "no worker is reading this", not "it is a DRAFT". Once a
  task is CLAIMED a worker may already have the brief in context, so rewriting it
  underneath would make the instructions it actually followed unrecoverable — the
  transcript would cite a body that no longer exists. A brief that needs changing
  after it is claimed is a new task, not an edit.

  DRAFT and READY are both PRE-CLAIM and both editable. Restricting this to DRAFT
  was a defect, not caution: it froze every READY task — body, title and priority
  uncorrectable — and the 409 it returned recommended superseding, which had no
  route either. Measured 2026-09-13: nine REF-TRIAGE briefs carrying a control
  that cannot fail sat unrepairable behind a gate precisely because gating them
  had made them READY.

  Only the brief fields move. State, claim and timing are the state machine's,
  and an edit route that could touch them would be a second, unguarded path
  through it.
  """
  @editable ~w(title body_md priority lane vm_required)

  def update_draft(id, attrs, actor \\ nil) do
    attrs = attrs |> stringify() |> Map.take(@editable)

    case get(id) do
      nil ->
        {:error, :no_such_task}

      %Task{state: st} = task when st in ["DRAFT", "READY"] ->
        if attrs == %{} do
          {:error, :nothing_to_update}
        else
          case task |> Task.changeset(attrs) |> Repo.update() do
            {:ok, t} ->
              log(t, "EDITED", actor, Enum.sort(Map.keys(attrs)) |> Enum.join(","))
              {:ok, t}

            err ->
              err
          end
        end

      %Task{state: state} ->
        {:error, {:not_editable, state}}
    end
  end

  @doc """
  Retire a task that should not be done, naming what replaced it.

  The alternative in practice was completing it, which puts a DONE in the record
  that no one earned and no report backs — a lie the board tells confidently.
  SUPERSEDED was already legal from every state and had no route, so the only
  honest option left was gating it behind a holder that never completes.

  `superseded_by` is required: a retirement with no replacement named is
  indistinguishable from an abandonment, and the next reader cannot tell which.
  """
  def supersede(id, superseded_by, actor \\ nil) do
    with :ok <- require_actor(actor),
         %Task{} = task <- get(id) do
      if is_nil(superseded_by) do
        {:error, :superseded_by_required}
      else
        transition(task, "SUPERSEDED", actor, superseded_by: superseded_by)
      end
    else
      nil -> {:error, :no_such_task}
      other -> other
    end
  end

  defp transition(task, to, actor), do: transition(task, to, actor, [])

  defp transition(nil, _to, _actor, _extra), do: {:error, :no_such_task}

  defp transition(%Task{} = task, to, actor, extra) do
    attrs = extra |> Map.new() |> stringify()

    case task |> Task.transition_changeset(to, attrs) |> Repo.update() do
      {:ok, t} ->
        if to in TaskEvent.kinds(), do: log(t, to, actor)
        {:ok, t}

      err ->
        err
    end
  end

  defp log(task, kind, actor, detail \\ nil) do
    %TaskEvent{}
    |> TaskEvent.changeset(%{task_id: task.id, at: now(), kind: kind, actor: actor, detail: detail})
    |> Repo.insert()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp stringify(attrs) when is_map(attrs),
    do: for({k, v} <- attrs, into: %{}, do: {to_string(k), v})
end
