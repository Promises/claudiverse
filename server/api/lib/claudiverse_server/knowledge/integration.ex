defmodule ClaudiverseServer.Knowledge.Integration do
  @moduledoc """
  The record that a submission reached the repository — and, if it came back
  out, why.

  A revert with no stated reason is indistinguishable from a mistake, so
  `revert_reason` is required whenever `reverted_at` is set.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "kb_integrations" do
    field :integrated_sha, :string
    field :integrated_at, :utc_datetime
    field :integrated_by, :string
    field :reverted_at, :utc_datetime
    field :revert_reason, :string
    belongs_to :submission, ClaudiverseServer.Knowledge.Submission
    timestamps()
  end

  def changeset(int, attrs) do
    int
    |> cast(attrs, [
      :submission_id,
      :integrated_sha,
      :integrated_at,
      :integrated_by,
      :reverted_at,
      :revert_reason
    ])
    |> validate_required([:submission_id, :integrated_sha, :integrated_at])
    |> require_revert_reason()
  end

  defp require_revert_reason(cs) do
    if get_field(cs, :reverted_at) && blank?(get_field(cs, :revert_reason)) do
      add_error(cs, :revert_reason, "a revert must say why — otherwise it is indistinguishable from a mistake")
    else
      cs
    end
  end

  defp blank?(nil), do: true
  defp blank?(s), do: String.trim(s) == ""
end
