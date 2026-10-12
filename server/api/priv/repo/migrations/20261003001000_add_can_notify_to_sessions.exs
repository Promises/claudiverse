defmodule ClaudiverseServer.Repo.Migrations.AddCanNotifyToSessions do
  @moduledoc """
  Which seats may ask for the operator (cv_request_human). Opt-in per seat:
  the seat's launcher sets CLAUDIVERSE_NOTIFY=1 and the seat reports it when
  it registers. Everything else — existing rows included — may not.
  Operator decision 2026-10-03: ipsum-admin and lorem-admin.
  """
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :can_notify, :boolean, null: false, default: false
    end
  end
end
