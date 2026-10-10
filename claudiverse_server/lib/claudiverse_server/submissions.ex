defmodule ClaudiverseServer.Submissions do
  @moduledoc """
  Component B — a worker delivers a matched function by calling one tool.

  ## The invariants, and why each exists

  1. **Durability is the acceptance, not a git ref.** `submit/1` returns only
     after the row is committed. Killing the worker one instruction later loses
     nothing. This is the whole point: the rescue-ref generator exists because
     durability currently depends on a branch surviving a reap.

  2. **State moves only along declared transitions** (`Submission.transitions/0`).
     An unconstrained state column drifts into meaning whatever the last writer
     assumed, and `GATE_PASS`, `INTEGRATED` and `AUDITED` are three different
     claims with three different amounts of evidence.

  3. **A PASS must carry its raw output.** Enforced in the gate changeset.
     Every single-instrument gate in this project has been observed lying, so a
     verdict has to remain re-derivable from evidence.

  4. **A stale `base_sha` cannot be integrated.** `integrate/3` refuses unless
     the submission's most recent PASS was gated at the sha being integrated
     into. A submission judged on evidence from an older tree is judged on the
     wrong tree.

  5. **`body_c` is dropped at integration.** Keeping it would put the C in two
     places — the second-source-of-truth failure this design exists to avoid.
     `body_hash` remains, so the claim "this is what was integrated" stays
     checkable.
  """

  import Ecto.Query

  alias ClaudiverseServer.Knowledge.{Integration, Submission, SubmissionGate}
  alias ClaudiverseServer.Repo

  # ── submit ─────────────────────────────────────────────────────────────────

  @doc """
  Accept a match. Durable when this returns `{:ok, submission}`.

  A prior active submission for the same address+build is marked SUPERSEDED and
  linked, so history is preserved rather than overwritten — "what did we try
  before" is a question the branch explosion could never answer.
  """
  def submit(attrs) do
    attrs = normalise(attrs)
    body = attrs[:body_c] || ""
    hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    attrs = Map.put(attrs, :body_hash, hash)

    Repo.transaction(fn ->
      case %Submission{} |> Submission.changeset(attrs) |> Repo.insert() do
        {:ok, sub} ->
          supersede_previous(sub)
          sub

        {:error, cs} ->
          Repo.rollback(cs)
      end
    end)
  end

  defp supersede_previous(%Submission{} = new) do
    open = ~w(SUBMITTED GATING GATE_PASS GATE_FAIL)

    from(s in Submission,
      where:
        s.address == ^new.address and s.build == ^new.build and s.id != ^new.id and
          s.state in ^open
    )
    |> Repo.update_all(set: [state: "SUPERSEDED", superseded_by: new.id, updated_at: now()])
  end

  # ── read ───────────────────────────────────────────────────────────────────

  def get(id) do
    case Repo.get(Submission, id) do
      nil -> nil
      sub -> %{submission: sub, gates: gates_for(sub.id), integration: integration_for(sub.id)}
    end
  end

  @doc "Filter by address (any spelling), build, unit, state or submitter."
  def list(opts \\ []) do
    Submission
    |> filter(:address, opts[:address] && Submission.normalise(opts[:address]))
    |> filter(:build, opts[:build])
    |> filter(:unit, opts[:unit])
    |> filter(:state, opts[:state])
    |> filter(:submitted_by, opts[:submitted_by])
    |> order_by([s], desc: s.id)
    |> limit(^(opts[:limit] || 50))
    |> Repo.all()
  end

  defp filter(q, _field, nil), do: q
  defp filter(q, field, value), do: where(q, [s], field(s, ^field) == ^value)

  def gates_for(id),
    do: from(g in SubmissionGate, where: g.submission_id == ^id, order_by: [desc: g.ran_at]) |> Repo.all()

  def integration_for(id), do: Repo.get_by(Integration, submission_id: id)

  # ── gate ───────────────────────────────────────────────────────────────────

  @doc """
  Record a gate run and move the submission to GATE_PASS / GATE_FAIL.

  ⚠️ The submission's state follows the WORST verdict among the gates of this
  run, not the last one written. A pipeline that reports the final gate would
  turn "3 passed, 1 failed" into a pass purely through ordering.
  """
  def record_gate(submission_id, attrs) do
    attrs =
      attrs
      |> normalise()
      |> Map.put(:submission_id, submission_id)
      |> Map.put_new(:ran_at, DateTime.utc_now() |> DateTime.truncate(:second))

    with {:ok, gate} <- %SubmissionGate{} |> SubmissionGate.changeset(attrs) |> Repo.insert(),
         sub when not is_nil(sub) <- Repo.get(Submission, submission_id) do
      target = if all_passed?(submission_id), do: "GATE_PASS", else: "GATE_FAIL"

      # ⛔ NOT `_ = force_state(...)`. Discarding this hid a rejected transition
      # completely: a FAIL gate was recorded while the submission stayed
      # GATE_PASS, because GATE_PASS -> GATE_FAIL was not a declared move. The
      # gate row existed, the state lied, and nothing said so. Caught by a test,
      # not by review.
      case force_state(sub, target) do
        {:ok, _} ->
          {:ok, gate}

        {:error, cs} ->
          {:error,
           Ecto.Changeset.add_error(
             cs,
             :state,
             "gate #{attrs[:gate_name]} recorded as #{attrs[:verdict]}, but the submission could not move to #{target}"
           )}
      end
    else
      {:error, cs} -> {:error, cs}
      nil -> {:error, :no_such_submission}
    end
  end

  defp all_passed?(submission_id) do
    verdicts =
      from(g in SubmissionGate,
        where: g.submission_id == ^submission_id,
        distinct: true,
        select: g.verdict
      )
      |> Repo.all()

    verdicts != [] and Enum.all?(verdicts, &(&1 == "PASS"))
  end

  # A gate result may arrive while the row is still SUBMITTED (nobody called
  # start_gating/1). Route through GATING rather than rejecting the evidence —
  # losing a real gate run to a bookkeeping technicality is the worse outcome.
  defp force_state(sub, target) do
    sub =
      if sub.state == "SUBMITTED" do
        {:ok, s} = sub |> Submission.transition_changeset("GATING") |> Repo.update()
        s
      else
        sub
      end

    sub |> Submission.transition_changeset(target) |> Repo.update()
  end

  def start_gating(id), do: transition(id, "GATING")

  # ── integrate ──────────────────────────────────────────────────────────────

  @doc """
  Mark a submission integrated at `sha`.

  ⛔ REFUSES unless the passing gate ran against that same sha. A submission
  gated on an older tree was judged on the wrong tree, and integrating it
  anyway means the evidence in `kb_submission_gates` describes something other
  than what landed.
  """
  def integrate(id, sha, by, opts \\ []) do
    with %Submission{} = sub <- Repo.get(Submission, id),
         :ok <- check_gated_at(sub, sha, opts[:force]),
         {:ok, sub} <- sub |> Submission.transition_changeset("INTEGRATED") |> Repo.update(),
         {:ok, int} <-
           %Integration{}
           |> Integration.changeset(%{
             submission_id: sub.id,
             integrated_sha: sha,
             integrated_at: DateTime.utc_now() |> DateTime.truncate(:second),
             integrated_by: by
           })
           |> Repo.insert() do
      # INVARIANT 5: the repo is authoritative from here. Keeping body_c would
      # put the C in two places.
      {:ok, _} = sub |> Ecto.Changeset.change(body_c: nil) |> Repo.update()
      {:ok, int}
    else
      nil -> {:error, :no_such_submission}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_gated_at(_sub, _sha, true), do: :ok

  defp check_gated_at(sub, sha, _) do
    cond do
      sub.state != "GATE_PASS" ->
        {:error, "state is #{sub.state}, not GATE_PASS — nothing has passed a gate"}

      sub.base_sha && sub.base_sha != sha ->
        {:error,
         "gated at #{String.slice(sub.base_sha, 0, 12)} but integrating into #{String.slice(sha, 0, 12)} — " <>
           "re-gate at HEAD; a submission judged on an older tree was judged on the wrong tree"}

      true ->
        :ok
    end
  end

  def revert(id, reason, opts \\ []) do
    with %Integration{} = int <- Repo.get_by(Integration, submission_id: id),
         {:ok, int} <-
           int
           |> Integration.changeset(%{
             submission_id: id,
             integrated_sha: int.integrated_sha,
             integrated_at: int.integrated_at,
             reverted_at: DateTime.utc_now() |> DateTime.truncate(:second),
             revert_reason: reason
           })
           |> Repo.update() do
      _ = transition(id, opts[:state] || "RETRACTED")
      {:ok, int}
    else
      nil -> {:error, :not_integrated}
      other -> other
    end
  end

  # ── state ──────────────────────────────────────────────────────────────────

  def transition(id, to) do
    case Repo.get(Submission, id) do
      nil -> {:error, :no_such_submission}
      sub -> sub |> Submission.transition_changeset(to) |> Repo.update()
    end
  end

  @doc """
  Gate runs whose positive control did NOT fire.

  ⭐ The acceptance criterion names this query and says the set must be empty.
  A gate that cannot fail reports PASS forever, and nothing else distinguishes
  it from one that is working.
  """
  def gates_without_positive_control(opts \\ []) do
    from(g in SubmissionGate,
      where: is_nil(g.positive_control_output) or g.positive_control_output == "",
      order_by: [desc: g.ran_at],
      limit: ^(opts[:limit] || 100)
    )
    |> Repo.all()
  end

  defp normalise(attrs) when is_map(attrs) do
    for {k, v} <- attrs, into: %{} do
      {if(is_binary(k), do: String.to_existing_atom(k), else: k), v}
    end
  rescue
    ArgumentError -> attrs
  end

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
end
