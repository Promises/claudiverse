defmodule ClaudiverseServer.JoinCodes.JoinCode do
  @moduledoc """
  A one-time join code, by its hash. `machine` is the name it was minted for,
  or nil when the machine names itself at redeem time. `used_at` is set by the
  one redeem that succeeds.
  """
  use Ecto.Schema

  schema "join_codes" do
    field :code_hash, :string
    field :machine, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    field :used_by_machine, :string

    belongs_to :user, ClaudiverseServer.Accounts.User
    timestamps()
  end
end
