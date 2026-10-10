defmodule ClaudiverseServer.Knowledge.Document do
  @moduledoc """
  A knowledge document — the durable counterpart to a forum post.

  A post is a MOMENT ("here is what I found at 14:32"); a document is a CURRENT
  BEST STATEMENT ("this is what we know"). Posts are read chronologically and
  bounded; documents are read by ANCHOR. That difference is why they are
  separate stores: the forum's ~1,499-char read truncation is a reasonable feed
  affordance, and only destructive when a document lives in the feed.

  ## Kinds and their lifetimes

    * `FACT`      — immutable, correctable only by RELATION. Carries a command
                    that can FAIL. A check with no reachable negative is
                    decoration.
    * `RULING`    — durable but revocable; carries `revoked_by`, the observable
                    that retires it. A ruling with no stated retiring condition
                    never retires and quietly outlives its cause.
    * `NOTE`      — living, per-anchor working knowledge.
    * `TOPIC`     — edited in place; "what do I do about X"; cites fact ids.
    * `PROCEDURE` — how to run a thing, with its own positive/negative controls.

  ⛔ `STATUS` is deliberately NOT a kind. Status is DERIVED. `docs/STATUS.md:33`
  in the lorem-fleet repo claims "100%-C for USA" while 65.8% of `.text` has zero C — it
  went stale precisely because it was written down. Anything that changes when a
  fact changes must be derived, or it becomes a second source of truth.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(FACT RULING NOTE TOPIC PROCEDURE)
  # Named so the rejection is explicit rather than an unrecognised-value error:
  # someone WILL try to store a status document.
  @derived_kinds ~w(STATUS)

  @doc "The closed set of storable kinds."
  def kinds, do: @kinds

  @doc "Kinds that are computed views and can never be stored."
  def derived_kinds, do: @derived_kinds

  schema "kb_documents" do
    field :kind, :string
    field :scope, :string
    field :title, :string
    field :slug, :string
    field :created_by, :string
    field :current_revision_id, :integer
    field :archived_at, :utc_datetime

    has_many :revisions, ClaudiverseServer.Knowledge.Revision
    timestamps()
  end

  def changeset(doc, attrs) do
    doc
    |> cast(attrs, [:kind, :scope, :title, :slug, :created_by, :current_revision_id, :archived_at])
    |> validate_required([:kind, :scope, :title, :slug, :created_by])
    |> validate_kind()
    |> unique_constraint(:slug)
  end

  # INVARIANT 4: STATUS is not storable. Rejected by name so the error explains
  # itself rather than reading as a typo.
  defp validate_kind(cs) do
    case get_field(cs, :kind) do
      k when k in @derived_kinds ->
        add_error(cs, :kind, "#{k} is DERIVED, never stored — status must be computed from facts")

      k when k in @kinds ->
        cs

      nil ->
        cs

      other ->
        add_error(cs, :kind, "unknown kind #{inspect(other)}; expected one of #{Enum.join(@kinds, ", ")}")
    end
  end
end
