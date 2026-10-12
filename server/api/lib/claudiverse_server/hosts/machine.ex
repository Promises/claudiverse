defmodule ClaudiverseServer.Hosts.Machine do
  @moduledoc """
  A machine a host agent has joined as: its name and when it was last seen
  (its agent joined or left).
  """
  use Ecto.Schema

  schema "machines" do
    field :name, :string
    field :last_seen_at, :utc_datetime

    belongs_to :user, ClaudiverseServer.Accounts.User
    timestamps()
  end
end
