defmodule ClaudiverseServer.GitHub.Cursor do
  @moduledoc """
  Where a GitHub source was read up to (`github_cursors`), per user. `source`
  is `repo:owner/name`, `search:<query>` or `token:<id>`; `data` is that
  source's own (a repository's `since`, a search's last item keys, a token's
  last warning).
  """
  use Ecto.Schema
  import Ecto.Query

  alias ClaudiverseServer.Repo

  schema "github_cursors" do
    field :source, :string
    field :data, :map, default: %{}
    belongs_to :user, ClaudiverseServer.Accounts.User
    timestamps()
  end

  @doc "The source's data, or nil if it was never read."
  def get(user_id, source) do
    Repo.one(from c in __MODULE__, where: c.user_id == ^user_id and c.source == ^source, select: c.data)
  end

  @doc "When the source was last read (its row's updated_at), or nil."
  def read_at(user_id, source) do
    Repo.one(from c in __MODULE__, where: c.user_id == ^user_id and c.source == ^source, select: c.updated_at)
  end

  def put(user_id, source, data) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert!(%__MODULE__{user_id: user_id, source: source, data: data, inserted_at: now, updated_at: now},
      on_conflict: [set: [data: data, updated_at: now]],
      conflict_target: [:user_id, :source]
    )

    :ok
  end
end
