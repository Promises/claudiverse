defmodule ClaudiverseServer.Sessions.Message do
  use Ecto.Schema
  import Ecto.Changeset

  schema "messages" do
    field :type, :string
    field :payload, :map
    field :sequence, :integer

    belongs_to :session, ClaudiverseServer.Sessions.Session

    timestamps(updated_at: false)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:type, :payload, :sequence, :session_id])
    |> validate_required([:type, :payload, :sequence, :session_id])
    |> foreign_key_constraint(:session_id)
  end
end
