defmodule ClaudiverseServer.Repo.Migrations.AssignmentsKeyOnInstance do
  @moduledoc """
  Key a seat's account assignment on a stable instance id, not its title.

  🔴 WHY THE PREVIOUS KEY COULD NOT WORK. Assignments were keyed on title, and
  title is resolved FRESH on every request — so the same seat presents different
  ones within a second of starting:

      startup lease   title = "Claude 11:41:02 AM"   (before Claude's session
                                                      hook fires, so no id)
      session create  title = <the session UUID>     (hook has fired)
      +5s             title = <auto-derived name>
      later           title = whatever /rename sets

  The assignment row was written at the FIRST of those and the session row at the
  SECOND, so the two records never shared a single value. Every attempt to follow
  a rename tried to match on a title or a session id that the other record had
  never held, and matched nothing. Two fixes to the match ORDER could not help,
  because the defect was that there was nothing to match on.

  MEASURED on three seats: assignments frozen at "Claude 10:09:35 AM",
  "Claude 10:41:42 AM" and "Claude 11:41:02 AM" while their sessions had long
  since become "we-say-hello", "runejs-f3" and "hello-0world".

  ⭐ instance_id is minted by the sidecar at module load and is deliberately
  derived from nothing Claude Code owns — every value Claude Code has either
  arrives after the first request (the session UUID) or changes during the
  session (the title). It is present on the seat's very first call and identical
  on its last.

  Title and claude_session_id remain, as DESCRIPTIVE fields. They are what a
  human reads and what joins to a session row; they are simply no longer asked
  to be identities they cannot be.
  """
  use Ecto.Migration

  def change do
    alter table(:anthropic_auth_assignments) do
      add :instance_id, :string
    end

    # ⛔ TWO PARTIAL INDEXES, NOT ONE. A client predating instance_id still
    # reports, and its rows must stay one-per-title; a client that sends one is
    # keyed on it and may legitimately share a title with another seat while a
    # rename is in flight. A single unique index on either column alone would
    # reject one of those two cases.
    create unique_index(:anthropic_auth_assignments, [:instance_id],
             where: "instance_id IS NOT NULL",
             name: :anthropic_auth_assignments_instance_id_index
           )

    drop unique_index(:anthropic_auth_assignments, [:title])

    create unique_index(:anthropic_auth_assignments, [:title],
             where: "instance_id IS NULL",
             name: :anthropic_auth_assignments_title_legacy_index
           )
  end
end
