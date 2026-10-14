defmodule ClaudiverseServer.Runners.Slot do
  @moduledoc """
  A runner slot's last heartbeat (Runners.heartbeat/2): its state, where it
  runs, when it last beat (`last_seen_at`), and when its current run of beats
  began (`beating_since`; a gap longer than "missing" starts a new run). A
  slot that beat throughout a window has `beating_since` before it and
  `last_seen_at` after it.
  """
  use Ecto.Schema

  schema "runner_slots" do
    field :slot, :string
    field :fleet, :string
    field :state, :string
    field :host, :string
    field :lane, :string
    field :beating_since, :utc_datetime
    field :last_seen_at, :utc_datetime

    belongs_to :user, ClaudiverseServer.Accounts.User
    timestamps()
  end
end
