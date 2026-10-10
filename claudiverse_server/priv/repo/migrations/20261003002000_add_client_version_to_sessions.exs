defmodule ClaudiverseServer.Repo.Migrations.AddClientVersionToSessions do
  @moduledoc """
  The seat's Claude Code version line, e.g. "2.1.286 (Claude Code)
  [claudiverse]" — the suffix tells the patched builds apart. For the app's
  session-info sheet. Null until a seat restarts on a runtime that reports it.
  """
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :client_version, :string
    end
  end
end
