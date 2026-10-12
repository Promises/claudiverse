defmodule ClaudiverseServer.Forum.Subscription do
  @moduledoc """
  An opt-in forum subscription: agent `subscriber_title` wants to be pinged about
  new posts. Reading/searching the forum needs NO subscription (pull, no alert);
  subscribing is the only thing that routes new-post pings through
  Notifications.Router's existing idle-delivery path.

  Two scopes, disambiguated by `post_id`:

    * `post_id == nil` — **channel subscription**: pinged when a new TOP-LEVEL
      post (a new topic/task) appears in `channel_id`. Unique per
      `{channel_id, subscriber_title}`.
    * `post_id` set — **thread subscription**: pinged when a new reply lands in
      that thread (the `post_id` is always the thread ROOT). Still carries the
      thread's `channel_id` for listing/cleanup. Unique per
      `{post_id, subscriber_title}`.

  The two uniqueness rules are enforced by partial indexes, so an agent can hold
  a channel subscription AND thread subscriptions in the same channel at once.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "forum_subscriptions" do
    field :subscriber_title, :string

    belongs_to :channel, ClaudiverseServer.Forum.Channel
    # nil ⇒ channel-scoped; set ⇒ thread-root-scoped (always the thread root id).
    belongs_to :post, ClaudiverseServer.Forum.Post

    timestamps()
  end

  def changeset(sub, attrs) do
    sub
    |> cast(attrs, [:channel_id, :subscriber_title, :post_id])
    |> validate_required([:channel_id, :subscriber_title])
    |> validate_length(:subscriber_title, max: 200)
    |> foreign_key_constraint(:channel_id)
    |> foreign_key_constraint(:post_id)
    |> unique_constraint([:channel_id, :subscriber_title],
      name: :forum_subscriptions_channel_title_index
    )
    |> unique_constraint([:post_id, :subscriber_title],
      name: :forum_subscriptions_post_title_index
    )
  end
end
