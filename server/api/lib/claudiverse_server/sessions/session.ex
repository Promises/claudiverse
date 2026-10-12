defmodule ClaudiverseServer.Sessions.Session do
  use Ecto.Schema
  import Ecto.Changeset

  schema "sessions" do
    field :title, :string
    # :proxy rows are fed by ClaudiverseServer.Proxy.Observer from API traffic,
    # titled "proxy:<seat>" so they never answer a lookup for the real seat.
    field :type, Ecto.Enum, values: [:sidecar, :spawned, :proxy], default: :spawned
    field :mode, Ecto.Enum, values: [:json, :pty], default: :json
    field :status, Ecto.Enum, values: [:running, :stopped, :crashed], default: :running
    field :working_directory, :string
    # What the seat runs, from its replies (Room) or, before the first, its
    # profile's model. No default: a "sonnet" default was shown as every new
    # seat's model, a Haiku one's included.
    field :model, :string
    field :permission_mode, :string, default: "default"
    # Claude Code's own session UUID, reported by the sidecar. Stable across
    # reconnects, so the server can REUSE this row on a blip instead of
    # inserting a new one. NULL for legacy sidecars and :spawned sessions.
    field :claude_session_id, :string
    # The name Claude Code's own picker shows, sentence case. DISPLAY ONLY —
    # never resolve or address a seat by it; see the migration.
    field :display_title, :string
    # Where the seat runs and how it was started (app: machine picker, fleet
    # grouping, runner filter; runner seats may not request a human).
    field :host, :string
    field :fleet, :string
    field :origin, :string
    # May this seat ask for the operator (cv_request_human)? Opt-in, reported
    # by the seat from CLAUDIVERSE_NOTIFY=1.
    field :can_notify, :boolean, default: false
    # Claude Code's version line, as the seat reports it (app session info).
    field :client_version, :string
    # The conversation `claude --resume` must continue, when it is not
    # claude_session_id: a resumed seat reports a placeholder id. Set only by
    # the server (Sessions.adopt_conversation/5), never by the seat's POST.
    field :conversation_id, :string
    # A seat started from a profile (Profiles): which, at which revision (a
    # client shows "restart needed" when the profile has moved on), and the
    # tmux session it runs in.
    field :profile_id, :integer
    field :profile_revision, :integer
    field :tmux_session, :string
    # Set from the apps (Sessions.Access); nil = derived.
    field :access, :string
    # The operator's paging switch (Sessions.Access): nil = derived; with
    # notify_until it lapses back to derived at that time.
    field :notify_grant, :boolean
    field :notify_until, :utc_datetime

    # Not a column: populated by list_sessions/2 from the newest message, so the
    # list can be ordered and rendered by when a session last DID something.
    field :last_activity_at, :naive_datetime, virtual: true

    belongs_to :user, ClaudiverseServer.Accounts.User
    has_many :messages, ClaudiverseServer.Sessions.Message

    timestamps()
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :title,
      :type,
      :mode,
      :status,
      :working_directory,
      :model,
      :permission_mode,
      :claude_session_id,
      :display_title,
      :host,
      :fleet,
      :origin,
      :can_notify,
      :client_version,
      :profile_id,
      :profile_revision,
      :tmux_session,
      :user_id
    ])
    |> validate_required([:type, :status, :user_id])
    |> validate_inclusion(:type, [:sidecar, :spawned, :proxy])
    |> validate_inclusion(:mode, [:json, :pty])
    |> validate_inclusion(:status, [:running, :stopped, :crashed])
    |> validate_inclusion(:origin, ~w(manual spawn runner profile plain))
    |> validate_inclusion(:access, ClaudiverseServer.Sessions.Access.levels())
    |> foreign_key_constraint(:user_id)
  end
end
