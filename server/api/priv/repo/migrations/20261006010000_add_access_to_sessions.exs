defmodule ClaudiverseServer.Repo.Migrations.AddAccessToSessions do
  @moduledoc "A seat's access level, set from the apps (basic | notify | full); nil = derived (Sessions.Access)."
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :access, :string
    end
  end
end
