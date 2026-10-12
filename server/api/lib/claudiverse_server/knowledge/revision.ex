defmodule ClaudiverseServer.Knowledge.Revision do
  @moduledoc """
  One version of a document's body. APPEND-ONLY: history and diff come from the
  `parent_revision_id` chain, the way git derives them from commits.

  ## Promoted FACT fields

  `fact_command`, `fact_fails_when` and `fact_fails_when_status` are real
  columns rather than keys inside `front_matter`. That is the whole reason a
  staleness sweep can exist here and cannot exist in the current ledger, where
  `command` is prose inside a post body and therefore unqueryable.

  `fact_fails_when_status`:

    * `DEMONSTRATED` — the failing arm has been SEEN, and `demonstrated_by` in
      `front_matter` says how.
    * `ASSERTED`     — only believed to be able to fail. ⛔ Never swept green;
      reported as untested, permanently, until someone demonstrates it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(DEMONSTRATED ASSERTED)
  def statuses, do: @statuses

  schema "kb_revisions" do
    field :body_md, :string
    field :front_matter, :map, default: %{}
    field :author, :string
    field :parent_revision_id, :integer

    field :fact_command, :string
    field :fact_fails_when, :string
    field :fact_fails_when_status, :string

    belongs_to :document, ClaudiverseServer.Knowledge.Document
    timestamps()
  end

  def changeset(rev, attrs) do
    rev
    |> cast(attrs, [
      :document_id,
      :body_md,
      :front_matter,
      :author,
      :parent_revision_id,
      :fact_command,
      :fact_fails_when,
      :fact_fails_when_status
    ])
    |> validate_required([:document_id, :body_md, :author])
    |> validate_inclusion(:fact_fails_when_status, @statuses)
  end

  @doc """
  A FACT needs a command that CAN FAIL. Applied only to FACT documents — a NOTE
  has nothing to re-derive.
  """
  def validate_fact_fields(cs) do
    cs
    |> validate_required([:fact_command, :fact_fails_when, :fact_fails_when_status],
      message: "a FACT requires a command that re-derives it and the output that would show it FALSE"
    )
  end
end
