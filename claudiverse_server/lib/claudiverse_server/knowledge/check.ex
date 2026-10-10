defmodule ClaudiverseServer.Knowledge.Check do
  @moduledoc """
  One run of a FACT's `command` — the staleness-sweep log.

  ## The verdicts say what was OBSERVED, never what is TRUE

  ⛔ There is deliberately no `PASS`. Measured over `#ledger-proto2`'s 5,219
  posts, only **46 of 4,099** `FAILS WHEN` fields are output-shaped — ~99% are
  prose describing what a failure would look like ("the include array contains
  only …", "a count > 0 for any of the three names"). Nothing can mechanically
  decide those, so a sweep emitting PASS would be **fabricating a verdict**,
  and the fabrication would be indistinguishable from a real one.

  What a sweep genuinely establishes is whether the evidence MOVED:

    * `BASELINE`  — first successful run. Output recorded; nothing to compare
      against yet. Not evidence of anything except that the command runs.
    * `UNCHANGED` — ran, and printed exactly what it printed last time. The
      claim is **corroborated, not verified** — its evidence is still there.
    * `CHANGED`   — ran, and printed something different. ⭐ The actionable
      signal: whatever this fact was derived from has moved underneath it.
    * `ERROR`     — could not run (missing tool, absent host, non-zero exit).
      A distinct verdict on purpose: a command that cannot execute is not a
      corroborated one, and collapsing the two is how a blind instrument
      reports green.
    * `MANUAL`    — the command is a prose procedure, not a shell command
      (1,138 of 5,116 measured). It must be re-derived by hand. Recording this
      is what stops 22% of the corpus from being silently skipped and counted
      as covered.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @verdicts ~w(BASELINE UNCHANGED CHANGED ERROR MANUAL)
  def verdicts, do: @verdicts

  @doc "Verdicts that mean the command actually executed."
  def ran, do: ~w(BASELINE UNCHANGED CHANGED)

  schema "kb_checks" do
    field :ran_at, :utc_datetime
    field :verdict, :string
    field :output, :string
    field :output_hash, :string
    field :exit_status, :integer
    field :environment, :string
    field :runner, :string
    belongs_to :document, ClaudiverseServer.Knowledge.Document
    timestamps()
  end

  def changeset(check, attrs) do
    check
    |> cast(attrs, [
      :document_id,
      :ran_at,
      :verdict,
      :output,
      :output_hash,
      :exit_status,
      :environment,
      :runner
    ])
    |> validate_required([:document_id, :ran_at, :verdict])
    |> validate_inclusion(:verdict, @verdicts)
    |> require_hash_when_ran()
  end

  # A run that executed but recorded no output hash cannot be compared against
  # the next one — it would make every subsequent run look like a BASELINE, so
  # nothing would ever be detected as CHANGED. Silent, and permanent.
  defp require_hash_when_ran(cs) do
    if get_field(cs, :verdict) in ran() and is_nil(get_field(cs, :output_hash)) do
      add_error(cs, :output_hash, "is required when the command actually ran")
    else
      cs
    end
  end
end
