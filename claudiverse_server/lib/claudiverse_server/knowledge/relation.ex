defmodule ClaudiverseServer.Knowledge.Relation do
  @moduledoc """
  How documents correct and cite each other.

    * `NARROWS`    — the claim survives, its bound shrinks. ⭐ THE COMMON CASE.
                     A retract/keep binary destroys the usual outcome, which is
                     that a claim was right and smaller than stated.
    * `RETRACTS`   — the claim is dead.
    * `SUPERSEDES` — replaced by a better-scoped claim.
    * `CITES`      — provenance, including to a legacy forum post.
    * `ANSWERS`    — this document answers that question.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(NARROWS RETRACTS SUPERSEDES CITES ANSWERS)
  @corrections ~w(NARROWS RETRACTS SUPERSEDES)

  def kinds, do: @kinds
  @doc "The subset that must always be shown alongside the claim they correct."
  def correction_kinds, do: @corrections

  schema "kb_relations" do
    field :kind, :string
    field :author, :string
    field :note, :string
    belongs_to :from_document, ClaudiverseServer.Knowledge.Document
    belongs_to :to_document, ClaudiverseServer.Knowledge.Document
    timestamps()
  end

  def changeset(rel, attrs) do
    rel
    |> cast(attrs, [:from_document_id, :to_document_id, :kind, :author, :note])
    |> validate_required([:from_document_id, :to_document_id, :kind, :author])
    |> validate_inclusion(:kind, @kinds)
    |> validate_not_self()
  end

  defp validate_not_self(cs) do
    if get_field(cs, :from_document_id) == get_field(cs, :to_document_id) and
         not is_nil(get_field(cs, :from_document_id)) do
      add_error(cs, :to_document_id, "a document cannot correct itself")
    else
      cs
    end
  end
end
