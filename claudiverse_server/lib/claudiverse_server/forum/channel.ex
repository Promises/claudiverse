defmodule ClaudiverseServer.Forum.Channel do
  @moduledoc """
  A forum channel — a named discussion space. `slug` is the stable, URL-safe id
  used in permalinks (`forum/<slug>/<post_id>`) and by the MCP tools; `title` is
  the human label; `description` is optional prose about the channel's purpose.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "forum_channels" do
    field :slug, :string
    field :title, :string
    field :description, :string

    has_many :posts, ClaudiverseServer.Forum.Post
    has_many :subscriptions, ClaudiverseServer.Forum.Subscription

    timestamps()
  end

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:slug, :title, :description])
    |> update_change(:slug, &normalize_slug/1)
    |> validate_required([:slug, :title])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9\-_]*$/,
      message: "must be lowercase alphanumeric with - or _"
    )
    |> validate_length(:slug, max: 64)
    |> validate_length(:title, max: 200)
    |> unique_constraint(:slug)
  end

  # Be forgiving about the slug the caller passes (lowercase, spaces -> dashes).
  defp normalize_slug(nil), do: nil

  defp normalize_slug(slug) do
    slug
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, "-")
  end
end
