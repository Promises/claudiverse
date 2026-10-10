defmodule ClaudiverseServer.Forum.Handoff.Version do
  @moduledoc """
  An append-only historical snapshot of a `role`'s handoff body at a given
  `version`. One row is written on every `Forum.set_handoff/3` so an earlier
  current-state is recoverable (cheap; fits the forum's searchable-history
  ethos). The live canonical state is `Forum.Handoff`; these are history only.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "forum_handoff_versions" do
    field :role, :string
    field :body, :string
    field :version, :integer

    timestamps(updated_at: false)
  end

  def changeset(version, attrs) do
    version
    |> cast(attrs, [:role, :body, :version])
    |> validate_required([:role, :body, :version])
  end
end
