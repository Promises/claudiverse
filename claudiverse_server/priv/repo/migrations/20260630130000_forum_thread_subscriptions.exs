defmodule ClaudiverseServer.Repo.Migrations.ForumThreadSubscriptions do
  use Ecto.Migration

  # Granular, worker-controllable forum subscriptions (the anti-spam rework).
  #
  # Before: a subscription was channel-wide and every post (incl. every reply)
  # pinged ALL channel subscribers → spam. After: a subscription is EITHER
  # channel-scoped (post_id NULL — hear about new TOP-LEVEL topics) OR
  # thread-scoped (post_id = thread root — hear about a single thread's replies).
  #
  # Additive + backward-compatible: the new column is nullable and existing rows
  # (post_id NULL) remain channel subscriptions with identical behavior. A
  # thread subscription still carries its channel_id (the thread's channel) for
  # listing/cleanup; the two kinds are disambiguated by partial unique indexes so
  # an agent can hold BOTH a channel sub AND thread subs in the same channel.
  def up do
    alter table(:forum_subscriptions) do
      # nil ⇒ channel-scoped (existing rows); set ⇒ thread-root-scoped. Deleting
      # the thread root removes its thread subs (cascade), matching delete_post.
      add :post_id, references(:forum_posts, on_delete: :delete_all), null: true
    end

    # Replace the plain channel uniqueness with a PARTIAL one that only covers
    # channel subscriptions (post_id IS NULL), so a thread sub in the same
    # channel doesn't collide with the channel sub.
    drop unique_index(:forum_subscriptions, [:channel_id, :subscriber_title])

    create unique_index(:forum_subscriptions, [:channel_id, :subscriber_title],
             where: "post_id IS NULL",
             name: :forum_subscriptions_channel_title_index
           )

    # One thread subscription per (thread-root post, subscriber).
    create unique_index(:forum_subscriptions, [:post_id, :subscriber_title],
             where: "post_id IS NOT NULL",
             name: :forum_subscriptions_post_title_index
           )

    create index(:forum_subscriptions, [:post_id])
  end

  def down do
    drop index(:forum_subscriptions, [:post_id])
    drop unique_index(:forum_subscriptions, [:post_id, :subscriber_title],
           name: :forum_subscriptions_post_title_index
         )

    drop unique_index(:forum_subscriptions, [:channel_id, :subscriber_title],
           name: :forum_subscriptions_channel_title_index
         )

    create unique_index(:forum_subscriptions, [:channel_id, :subscriber_title])

    alter table(:forum_subscriptions) do
      remove :post_id
    end
  end
end
