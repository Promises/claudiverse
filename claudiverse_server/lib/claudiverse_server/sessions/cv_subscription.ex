defmodule ClaudiverseServer.Sessions.CvSubscription do
  @moduledoc """
  Persisted Router subscription: a listener (by title) and the titles it watches.
  Survives restarts; the live session id is NOT stored (it changes per relaunch)
  and is rebound on the listener's next idle. `watch` is `%{"titles" => [...]}`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:listener_title, :string, autogenerate: false}
  schema "cv_subscriptions" do
    field :watch, :map

    timestamps()
  end

  def changeset(sub, attrs) do
    sub
    |> cast(attrs, [:listener_title, :watch])
    |> validate_required([:listener_title, :watch])
  end
end
