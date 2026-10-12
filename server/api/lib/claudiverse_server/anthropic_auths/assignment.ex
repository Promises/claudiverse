defmodule ClaudiverseServer.AnthropicAuths.Assignment do
  @moduledoc """
  One row per seat: which Anthropic account it was last handed.

  Written at lease time by `AnthropicAuths.record_assignment/3`, never by a
  client push — see the migration for why the decision point beats a heartbeat.

  ⚠️ `assigned_at` is when the account was HANDED OVER, not when the seat was
  last alive. Nothing here can observe a seat dying, so a reader must age this
  out rather than treat a row as proof of a running seat.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "anthropic_auth_assignments" do
    field :title, :string
    field :claude_session_id, :string
    # Minted by the sidecar at module load. The only value present on a seat's
    # FIRST request that is still the same on its last — see the migration.
    field :instance_id, :string
    field :assigned_at, :utc_datetime
    field :via, :string

    belongs_to :anthropic_auth, ClaudiverseServer.AnthropicAuths.AnthropicAuth

    timestamps()
  end

  # proxy-*: the decision was made by the API proxy for a pooled seat
  # (ClaudiverseServer.Proxy.Credentials), not by the seat's sidecar.
  @vias ~w(lease failover upgrade renewal proxy-lease proxy-failover proxy-renewal)

  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:title, :claude_session_id, :instance_id, :anthropic_auth_id, :assigned_at, :via])
    |> validate_required([:title, :anthropic_auth_id, :assigned_at])
    # Not validate_inclusion: an unknown `via` from a newer client should be
    # RECORDED, not rejected. Refusing the write would lose the assignment
    # itself — the far more valuable half — to protect a label.
    |> update_change(:via, fn
      v when v in @vias -> v
      nil -> nil
      other -> "other:#{other}"
    end)
    |> foreign_key_constraint(:anthropic_auth_id)
    |> unique_constraint(:instance_id, name: :anthropic_auth_assignments_instance_id_index)
    |> unique_constraint(:title, name: :anthropic_auth_assignments_title_legacy_index)
  end
end
