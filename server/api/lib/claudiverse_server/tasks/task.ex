defmodule ClaudiverseServer.Tasks.Task do
  @moduledoc """
  One unit of claimable work.

  ## States

      DRAFT -> READY -> CLAIMED -> RUNNING -> DONE -> VALIDATED
                 ^         |
                 +---------+  RELEASED (handed back un-started)
      any -> SUPERSEDED

  READY is the ONLY claimable state, and it is a state rather than a nullable
  string a caller can forget to set. That makes E-1 — "a post created without
  status=incoming is invisible to the claim query and fails silently", warned
  about in five channel descriptions — structurally impossible.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(DRAFT READY CLAIMED RUNNING DONE VALIDATED RELEASED SUPERSEDED)
  def states, do: @states

  @claimable "READY"
  def claimable_state, do: @claimable

  @transitions %{
    "DRAFT" => ~w(READY SUPERSEDED),
    "READY" => ~w(CLAIMED SUPERSEDED DRAFT),
    # RELEASED returns to READY: a worker handing a task back un-started is a
    # first-class transition, not an improvisation. #22557 did exactly this and
    # had no way to express it.
    "CLAIMED" => ~w(RUNNING RELEASED SUPERSEDED READY),
    "RUNNING" => ~w(DONE RELEASED SUPERSEDED READY),
    "DONE" => ~w(VALIDATED SUPERSEDED),
    "VALIDATED" => ~w(SUPERSEDED),
    "RELEASED" => ~w(READY SUPERSEDED),
    "SUPERSEDED" => []
  }
  def transitions, do: @transitions

  schema "tasks" do
    field :fleet, :string
    field :lane, :string
    field :title, :string
    field :body_md, :string
    field :state, :string, default: "DRAFT"
    field :priority, :integer, default: 0
    field :claimed_by, :string
    field :claimed_at, :utc_datetime
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :validates_task_id, :id
    field :superseded_by, :id
    field :vm_required, :boolean, default: false
    field :created_by, :string

    has_many :events, ClaudiverseServer.Tasks.TaskEvent
    timestamps()
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :fleet, :lane, :title, :body_md, :state, :priority, :claimed_by,
      :claimed_at, :started_at, :completed_at, :validates_task_id,
      :superseded_by, :vm_required, :created_by
    ])
    |> validate_required([:fleet, :lane, :title, :created_by, :state])
    |> validate_inclusion(:state, @states)
    |> claimed_requires_holder()
  end

  # A CLAIMED or RUNNING task with no claimed_by is a slot nobody can be shown
  # to hold — exactly the ambiguity that made the #22557 strand invisible.
  defp claimed_requires_holder(cs) do
    if get_field(cs, :state) in ["CLAIMED", "RUNNING"] and
         blank?(get_field(cs, :claimed_by)) do
      add_error(cs, :claimed_by, "a CLAIMED or RUNNING task must name its holder")
    else
      cs
    end
  end

  def transition_changeset(%__MODULE__{state: from} = task, to, attrs \\ %{}) do
    allowed = Map.get(@transitions, from, [])

    if to in allowed do
      # ⚠️ Stringify BOTH sides. Callers pass string-keyed attrs, and merging an
      # atom :state produced a mixed-key map, which Ecto rejects outright.
      attrs = for {k, v} <- attrs, into: %{}, do: {to_string(k), v}
      task |> changeset(Map.put(attrs, "state", to))
    else
      task
      |> change()
      |> add_error(
        :state,
        "cannot go #{from} -> #{to}" <>
          if(allowed == [],
            do: " (#{from} is terminal)",
            else: " (from #{from}, only: #{Enum.join(allowed, ", ")})"
          )
      )
    end
  end

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
