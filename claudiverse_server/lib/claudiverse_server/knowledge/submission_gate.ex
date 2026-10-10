defmodule ClaudiverseServer.Knowledge.SubmissionGate do
  @moduledoc """
  One gate run against one submission.

  ⭐ `positive_control_output` exists so that *"could this gate have failed on
  this run?"* is a QUERY, not an act of faith. A gate that quietly loses its
  ability to fail is otherwise indistinguishable from one that keeps passing —
  and this project has produced two such probes already.

  ⛔ `raw_output` is stored instead of a boolean because every single-instrument
  gate here has been observed lying. A verdict can be re-derived from output;
  it cannot be re-derived from a flag.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @verdicts ~w(PASS FAIL UNRUNNABLE)
  def verdicts, do: @verdicts

  schema "kb_submission_gates" do
    field :gate_name, :string
    field :ran_at, :utc_datetime
    field :verdict, :string
    field :raw_output, :string
    field :positive_control_output, :string
    field :runner, :string
    field :environment, :string
    belongs_to :submission, ClaudiverseServer.Knowledge.Submission
    timestamps()
  end

  def changeset(gate, attrs) do
    gate
    |> cast(attrs, [
      :submission_id,
      :gate_name,
      :ran_at,
      :verdict,
      :raw_output,
      :positive_control_output,
      :runner,
      :environment
    ])
    |> validate_required([:submission_id, :gate_name, :ran_at, :verdict])
    |> validate_inclusion(:verdict, @verdicts)
    |> require_evidence()
  end

  # A PASS with no output cannot be re-audited, and an unauditable PASS is the
  # shape every lying gate in this project has taken.
  defp require_evidence(cs) do
    if get_field(cs, :verdict) == "PASS" and blank?(get_field(cs, :raw_output)) do
      add_error(cs, :raw_output, "a PASS must carry its output — a verdict with no evidence cannot be re-checked")
    else
      cs
    end
  end

  defp blank?(nil), do: true
  defp blank?(s), do: String.trim(s) == ""
end
