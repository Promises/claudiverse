defmodule ClaudiverseServer.Repo.Migrations.CreateUsageSamples do
  @moduledoc """
  The account pool's usage history (AnthropicAuths.UsageHistory): one row per
  account per usage reading, its weekly and session percent and when each
  resets. Thinned as it ages (every reading for 48 h, then one per 15 minutes,
  then hourly after 30 days), so the per-day sums stay exact while the table
  stays small.
  """
  use Ecto.Migration

  def change do
    create table(:usage_samples) do
      add :anthropic_auth_id, references(:anthropic_auths, on_delete: :delete_all), null: false
      add :at, :utc_datetime, null: false
      add :weekly_pct, :float
      add :weekly_resets_at, :utc_datetime
      add :session_pct, :float
      add :session_resets_at, :utc_datetime
    end

    create index(:usage_samples, [:anthropic_auth_id, :at])
  end
end
