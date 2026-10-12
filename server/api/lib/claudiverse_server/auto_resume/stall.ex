defmodule ClaudiverseServer.AutoResume.Stall do
  @moduledoc """
  One seat as auto-resume knows it, by title, from its model calls through the
  API proxy.

  `in_flight`: a model response is streaming to the seat now. A row still in
  flight when the server boots had its stream cut by the restart.

  `state`:
  - `clear`: the seat's last model call got an answer.
  - `stalled`: its last model call died (`reason`: `no_available_auth`, the
    pool had no account to lease; `server_restart`, a restart cut the
    stream), and the `continue` has not gone out. `waiting` says on what:
    `grace` (after boot), `pool` (an account to become leasable), `seat` (no
    running seat with this title and Claude session), `busy` (the seat is
    busy; sent when it goes idle).
  - `nudged`: the `continue` was delivered (`nudged_at`, `nudged_session_id`).
    The incident stays open until the seat's next model call is answered,
    and it is never nudged twice in one incident.
  """
  use Ecto.Schema

  schema "seat_stalls" do
    field :seat_title, :string
    field :claude_session_id, :string
    field :in_flight, :boolean, default: false
    field :state, :string, default: "clear"
    field :reason, :string
    field :detail, :string
    field :stalled_at, :utc_datetime
    field :waiting, :string
    field :nudged_at, :utc_datetime
    field :nudged_session_id, :integer

    belongs_to :user, ClaudiverseServer.Accounts.User
    timestamps()
  end
end
