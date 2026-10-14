defmodule ClaudiverseServer.Repo.Migrations.AddProtectedToProfiles do
  @moduledoc """
  A protected profile's seat is left out of a bulk restart unless it is named,
  and a single restart of it must be confirmed (Restarts). The apps recognise
  the operator's own seats by it, with no title in code.
  """
  use Ecto.Migration

  def change do
    alter table(:profiles) do
      add :protected, :boolean, default: false, null: false
    end
  end
end
