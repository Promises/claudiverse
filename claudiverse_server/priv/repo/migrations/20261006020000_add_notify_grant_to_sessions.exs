defmodule ClaudiverseServer.Repo.Migrations.AddNotifyGrantToSessions do
  @moduledoc "The operator's paging switch per seat (Sessions.Access): on/off, optionally until a time; nil = derived."
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :notify_grant, :boolean
      add :notify_until, :utc_datetime
    end
  end
end
