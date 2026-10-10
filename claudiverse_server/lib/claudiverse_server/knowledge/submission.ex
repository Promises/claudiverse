defmodule ClaudiverseServer.Knowledge.Submission do
  @moduledoc """
  One delivered match, durable the instant it is accepted.

  ## States

      SUBMITTED → GATING → GATE_PASS | GATE_FAIL → INTEGRATED → AUDITED | RETRACTED
                                                 └ SUPERSEDED (a better one arrived)

  ⛔ `GATE_PASS` is not `INTEGRATED`, and `INTEGRATED` is not `AUDITED`. Collapsing
  them is how "a gate returned green" silently becomes "this is in master and
  someone checked it" — three different claims with three different amounts of
  evidence behind them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(SUBMITTED GATING GATE_PASS GATE_FAIL INTEGRATED AUDITED RETRACTED SUPERSEDED)
  def states, do: @states

  @tiers ~w(T1 T2 T3)
  def tiers, do: @tiers

  # Which state may follow which. Written down rather than left to callers,
  # because an unconstrained state column drifts into meaning whatever the last
  # writer assumed.
  @transitions %{
    "SUBMITTED" => ~w(GATING SUPERSEDED RETRACTED),
    # Gate results move freely among the gating states: a later FAIL must be
    # able to DEMOTE a GATE_PASS, or a submission with "3 passed, 1 failed"
    # keeps whichever verdict happened to be written last.
    "GATING" => ~w(GATE_PASS GATE_FAIL GATING SUPERSEDED RETRACTED),
    "GATE_FAIL" => ~w(GATING GATE_PASS GATE_FAIL SUPERSEDED RETRACTED),
    "GATE_PASS" => ~w(INTEGRATED GATING GATE_PASS GATE_FAIL SUPERSEDED RETRACTED),
    "INTEGRATED" => ~w(AUDITED RETRACTED),
    "AUDITED" => ~w(RETRACTED),
    "RETRACTED" => [],
    "SUPERSEDED" => []
  }
  def transitions, do: @transitions

  schema "kb_submissions" do
    field :address, :string
    field :unit, :string
    field :build, :string
    field :tier, :string
    field :base_sha, :string
    field :compiler, :string
    field :flags, :string
    field :body_c, :string
    field :body_hash, :string
    field :notes, :string
    field :submitted_by, :string
    field :state, :string, default: "SUBMITTED"
    field :superseded_by, :id

    has_many :gates, ClaudiverseServer.Knowledge.SubmissionGate
    timestamps()
  end

  def changeset(sub, attrs) do
    sub
    |> cast(attrs, [
      :address,
      :unit,
      :build,
      :tier,
      :base_sha,
      :compiler,
      :flags,
      :body_c,
      :body_hash,
      :notes,
      :submitted_by,
      :state,
      :superseded_by
    ])
    |> validate_required([:address, :build, :body_hash, :submitted_by, :state])
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:tier, @tiers)
    |> normalise_address()
  end

  @doc "Only a declared transition. Anything else is rejected with both ends named."
  def transition_changeset(%__MODULE__{state: from} = sub, to) do
    allowed = Map.get(@transitions, from, [])

    if to in allowed do
      change(sub, state: to)
    else
      sub
      |> change()
      |> add_error(
        :state,
        "cannot go #{from} -> #{to}" <>
          if(allowed == [],
            do: " (#{from} is terminal)",
            else: " (from #{from}, only: #{Enum.join(allowed, ", ")})"
          )
      )
    end
  end

  # Addresses arrive spelled every way this project spells them — `0x00336B88`,
  # `00336b88`, `func_00336B88`. Storing them as typed means the same function
  # occupies several identities and a supersede silently fails to find its
  # predecessor.
  defp normalise_address(cs) do
    case get_change(cs, :address) do
      nil -> cs
      addr -> put_change(cs, :address, normalise(addr))
    end
  end

  def normalise(addr) do
    addr
    |> String.trim()
    |> String.replace(~r/^(func_|FUN_|0x)/i, "")
    |> String.downcase()
    |> String.pad_leading(8, "0")
  end
end
