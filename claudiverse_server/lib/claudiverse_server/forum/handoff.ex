defmodule ClaudiverseServer.Forum.Handoff do
  @moduledoc """
  The ONE canonical current-state / continuity note for an agent `role` (its
  title, e.g. "decomper", "tester"). Upserted by `Forum.set_handoff/3` — there is
  exactly one row per role at any time (a successor reads this single
  authoritative note on takeover, never a reconstructed scroll). `version` is the
  monotonic count of sets so far; prior bodies live in `Forum.Handoff.Version`.

  Handoffs are PULL-ONLY: setting one never enqueues a ping (no Router
  involvement at all). Nobody is alerted about another role's handoff.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "forum_handoffs" do
    field :role, :string
    field :body, :string
    field :version, :integer, default: 1

    timestamps()
  end

  def changeset(handoff, attrs) do
    handoff
    |> cast(attrs, [:role, :body, :version])
    |> update_change(:role, &normalize_role/1)
    |> validate_required([:role, :body])
    |> validate_length(:role, max: 200)
    |> validate_length(:body, min: 1, max: 50_000)
    |> unique_constraint(:role)
  end

  # The role is an agent title; just trim/normalize whitespace (titles can carry
  # mixed case, so DON'T downcase — match the title used everywhere else).
  defp normalize_role(nil), do: nil
  defp normalize_role(role), do: String.trim(role)
end
