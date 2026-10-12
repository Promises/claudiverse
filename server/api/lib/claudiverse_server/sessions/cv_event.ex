defmodule ClaudiverseServer.Sessions.CvEvent do
  @moduledoc """
  A structured observability event for a session — currently idle/busy
  transitions (`kind: "idle_transition"`), with room for client diagnostic
  snapshots (`kind: "cvdebug"`, payload in `detail`). Queryable history that
  survives restarts, unlike the in-memory Room/Router state.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "cv_events" do
    field :kind, :string
    field :from_state, :string
    field :to_state, :string
    field :trigger, :string
    field :detail, :map

    belongs_to :session, ClaudiverseServer.Sessions.Session

    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:session_id, :kind, :from_state, :to_state, :trigger, :detail])
    |> validate_required([:session_id, :kind])
    |> foreign_key_constraint(:session_id)
  end
end
