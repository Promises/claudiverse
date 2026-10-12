defmodule ClaudiverseServer.Repo.Migrations.AddPlacementToSessions do
  @moduledoc """
  Where a seat runs and how it was started, for the app's machine picker,
  fleet grouping and runner filter.

    host    the machine (CLAUDIVERSE_HOST, else its hostname)
    fleet   e.g. "lorem-fleet" (CLAUDIVERSE_FLEET)
    origin  "manual" | "spawn" | "runner" (CLAUDIVERSE_ORIGIN)

  All nullable: seats started before this change report nothing, and a null
  origin is treated as not-a-runner.
  """
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :host, :string
      add :fleet, :string
      add :origin, :string
    end
  end
end
