defmodule ClaudiverseServer.Repo.Migrations.CreateAnthropicAuthAssignments do
  @moduledoc """
  Which SEAT is on which Anthropic account.

  ⭐ WHY THIS EXISTS. The pool's bearer token is SHARED by every seat, so a lease
  request carried no identity: the server chose which account a seat got and then
  could not say which seat got it. "Which seat is on Work?" was unanswerable three
  times in one day. The only fallback was correlating `last_leased_at` against
  process start times, which works for one seat starting alone and collapses the
  moment two start together — exactly when a fleet of workers comes up.

  ⭐ WHY LEASE-TIME AND NOT A HEARTBEAT. Every account change already makes a
  server call: the startup lease, the 429 failover via /rate_limited, the
  server-push upgrade, and the 401 renewal all hit the API. The server is present
  at every transition, so it can record the mapping AT THE MOMENT IT DECIDES
  rather than learn it seconds later from a client report. Clients send
  X-Claudiverse-Client (see Plugs.Auth); nothing here trusts a client to volunteer
  state on its own schedule.

  🔴 KEYED ON TITLE, AND TITLE IS NOT GUARANTEED UNIQUE. CLAUDIVERSE_TITLE is the
  only field present on the FIRST request — the startup lease runs before Claude's
  session hook fires, so `claude_session_id` is null there and fills in from the
  first switch onward. A restarted seat legitimately reuses its title, which is
  what makes it the right key. But two seats CAN share one by misconfiguration: a
  copied mcp.json that keeps a hardcoded CLAUDIVERSE_SELF has done exactly that
  before. Such a pair overwrites each other's row and reads as one flip-flopping
  seat. `claude_session_id` is stored precisely so that case is VISIBLE — two
  distinct ids alternating on one title is the tell — rather than silently
  averaging into a wrong answer.

  ⚠️ THIS RECORD CANNOT SEE A SEAT DIE. It is written when an account is handed
  out and never again, so a killed seat leaves its last mapping sitting there
  looking current. `assigned_at` is the defence: a reader can age it out instead
  of believing it. Same failure class as a `cooldown_reason` still reading
  "session at 100%" hours after the cooldown expired — a stored value that
  nothing re-checks starts lying, and the fix is to make the staleness legible,
  not to pretend it cannot happen.
  """
  use Ecto.Migration

  def change do
    create table(:anthropic_auth_assignments) do
      # CLAUDIVERSE_TITLE, e.g. "ipsum-admin" / "lorem-admin". Always present.
      add :title, :string, null: false

      # Claude's own session UUID. NULL until the seat's first post-startup call,
      # by design — see the note above. The server already matches sessions on
      # this column elsewhere (sessions.claude_session_id), so it joins to a row.
      add :claude_session_id, :string

      # ⛔ delete_all, not nilify: a row whose account is gone describes nothing.
      # Keeping it would leave a seat pointing at an account that no longer
      # exists, which reads as data rather than as absence.
      add :anthropic_auth_id,
          references(:anthropic_auths, on_delete: :delete_all),
          null: false

      # When this mapping was established. NOT a timestamp of last contact —
      # see the staleness note above. Named `assigned_at` rather than
      # `last_seen_at` so nobody reads it as liveness.
      add :assigned_at, :utc_datetime, null: false

      # Which call produced it: "lease" | "failover" | "upgrade" | "renewal".
      # A seat that keeps arriving via "failover" is churning, and that is
      # invisible if every row looks the same.
      add :via, :string

      timestamps()
    end

    # One row per seat. The upsert in AnthropicAuths.record_assignment/3 depends
    # on this constraint existing — without it a busy seat accumulates a row per
    # lease and the table becomes a log nobody asked for.
    create unique_index(:anthropic_auth_assignments, [:title])

    # The actual question: "who is on Work right now."
    create index(:anthropic_auth_assignments, [:anthropic_auth_id])
  end
end
