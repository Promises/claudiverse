defmodule ClaudiverseServer.Repo.Migrations.CreateGithubTokens do
  @moduledoc """
  The operator's GitHub tokens (GitHub): one per resource owner, read-only,
  stored encrypted (Vault, "github_tokens.v1"). What GitHub said about each at
  its last check: the account, the kind, a classic token's scopes, the expiry,
  how many repos it reaches.
  """
  use Ecto.Migration

  def change do
    create table(:github_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :label, :string, null: false
      add :token, :binary, null: false
      add :kind, :string, null: false
      add :login, :string
      add :scopes, :string
      add :expires_at, :utc_datetime
      add :repos_count, :integer
      add :status, :string, null: false, default: "ok"
      add :last_error, :string
      add :checked_at, :utc_datetime
      timestamps()
    end

    create unique_index(:github_tokens, [:user_id, :label])
  end
end
