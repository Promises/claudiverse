defmodule ClaudiverseServer.Repo.Migrations.AddDisplayTitleToSessions do
  @moduledoc """
  The name a human recognises, beside the name the fleet addresses.

  Claude Code runs two namers and they answer different questions:

    title         kebab, from ~/.claude/sessions/<pid>.json ("runejs-38").
                  ADDRESSABLE — `--resume <name>` resolves it, upstream
                  de-duplicates it across live processes, and cv_send /
                  GET /api/sessions?title= route on it.

    display_title sentence case, from an {"type":"ai-title"} record in the
                  transcript ("Knights of Ni follow-up phrase"). This is what
                  Claude Code's own session picker shows, so it is the name the
                  operator actually recognises.

  Keeping only the first meant the panel disagreed with the picker for the same
  session. Keeping only the second would put spaces and conversational drift
  into the value orchestration routes on. So: both, with the roles explicit.

  ⚠️ DISPLAY ONLY. Nothing may resolve or address a seat by this column. It is
  derived from the conversation, so it changes as the session evolves and two
  sessions can easily share one.
  """
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :display_title, :string
    end
  end
end
