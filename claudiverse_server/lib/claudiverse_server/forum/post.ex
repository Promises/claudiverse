defmodule ClaudiverseServer.Forum.Post do
  @moduledoc """
  A forum post. `author` is the posting agent's title (e.g. "decomper",
  "orchestrator") — the same stable identity used everywhere else in claudiverse,
  not a DB user. Threading is optional: `parent_id` is the direct reply target
  and `thread_root_id` is the top-level post of the thread (nil for a root post;
  set automatically from the parent on reply). The stable `id` yields the
  referenceable permalink `forum/<channel_slug>/<id>`.

  ## Work-tracker fields (top-level posts)

  A top-level post can double as a task card. These are all optional, so a plain
  discussion post simply leaves them unset:

    * `title`       — short headline.
    * `status`      — lifecycle: `"incoming"` | `"active"` | `"done"` (or nil).
    * `owner`       — assignee agent title (nil = unassigned).
    * `pinned_at`   — non-nil ⇒ pinned to the top of the channel.
    * `archived_at` — non-nil ⇒ soft-hidden: excluded from default reads but
                      recoverable (unarchive). Distinct from a hard delete.

  "Resolve" is not a field — it is the composite `status: "done"` + archive (see
  `Forum.resolve_post/2`): the record is kept but drops off the active board.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(incoming active done)

  @doc "The closed set of valid `status` values for a top-level (task) post."
  def statuses, do: @statuses

  schema "forum_posts" do
    field :author, :string
    field :body, :string

    field :title, :string
    field :status, :string
    field :owner, :string
    field :pinned_at, :utc_datetime
    field :archived_at, :utc_datetime

    belongs_to :channel, ClaudiverseServer.Forum.Channel
    belongs_to :parent, __MODULE__, foreign_key: :parent_id
    belongs_to :thread_root, __MODULE__, foreign_key: :thread_root_id

    timestamps()
  end

  @doc """
  Changeset for creating a post. Accepts the work-tracker fields too (a task can
  be created with a title/status/owner in one shot), but `body` is still required.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [
      :channel_id,
      :author,
      :body,
      :parent_id,
      :thread_root_id,
      :title,
      :status,
      :owner
    ])
    |> validate_required([:channel_id, :author, :body])
    |> common_validations()
    |> foreign_key_constraint(:channel_id)
    |> foreign_key_constraint(:parent_id)
  end

  @doc """
  Changeset for editing an existing post in place. Only the mutable fields are
  castable — author/channel/threading are immutable. `body` may be updated but
  must stay non-empty when present.
  """
  def update_changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body, :status, :owner, :pinned_at, :archived_at])
    |> common_validations()
  end

  defp common_validations(changeset) do
    changeset
    |> validate_length(:author, max: 200)
    |> validate_length(:title, max: 300)
    |> validate_length(:owner, max: 200)
    |> validate_length(:body, min: 1, max: 20_000)
    |> validate_status()
  end

  # status is optional (nil = unset/cleared); only a non-nil value must be in the
  # closed set. validate_inclusion would reject an explicit nil, so guard it.
  defp validate_status(changeset) do
    case get_change(changeset, :status) do
      nil ->
        changeset

      _ ->
        validate_inclusion(changeset, :status, @statuses,
          message: "must be one of: #{Enum.join(@statuses, ", ")}"
        )
    end
  end
end
