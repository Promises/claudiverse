defmodule ClaudiverseServer.Repo.Migrations.IndexMessagesSessionInsertedAt do
  @moduledoc """
  Make "when did this session last do something" a single index seek.

  The session list orders by last activity. Computing that as

      SELECT session_id, max(inserted_at) FROM messages GROUP BY session_id

  groups the whole table on every call — 17.8s at limit=3 against the live DB.
  A correlated `max(inserted_at)` per session is the same answer for the cost of
  one seek, but ONLY with an index whose leading column is session_id and whose
  next column is inserted_at; the existing (session_id, sequence) index cannot
  serve it.

  ⛔ NOT (session_id, sequence). That index is why the first attempt at this
  read `inserted_at` off the highest-sequence row instead of taking max() — it
  was the index that already existed. `sequence` is seeded per ROOM from
  max(sequence)+1 and then incremented in memory, so ties and gaps are
  reachable and the highest sequence is not reliably the newest row. Observed
  live 2026-09-17: a session answered a message while the list kept reporting an
  activity time 90 seconds stale.
  """
  use Ecto.Migration

  def change do
    create index(:messages, [:session_id, :inserted_at])
  end
end
