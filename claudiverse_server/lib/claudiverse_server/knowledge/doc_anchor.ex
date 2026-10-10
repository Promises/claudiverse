defmodule ClaudiverseServer.Knowledge.DocAnchor do
  @moduledoc "Join: which documents concern which anchors, and how."
  use Ecto.Schema
  import Ecto.Changeset

  @relations ~w(about cites derived_from)
  def relations, do: @relations

  schema "kb_doc_anchors" do
    field :relation, :string, default: "about"
    belongs_to :document, ClaudiverseServer.Knowledge.Document
    belongs_to :anchor, ClaudiverseServer.Knowledge.Anchor
    timestamps()
  end

  def changeset(da, attrs) do
    da
    |> cast(attrs, [:document_id, :anchor_id, :relation])
    |> validate_required([:document_id, :anchor_id, :relation])
    |> validate_inclusion(:relation, @relations)
    |> unique_constraint([:document_id, :anchor_id, :relation],
      name: :kb_doc_anchors_document_id_anchor_id_relation_index
    )
  end
end
