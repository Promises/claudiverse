defmodule ClaudiverseServer.Repo.Migrations.AddExpiryAndReposToGithubTokens do
  @moduledoc """
  `expires_on`: an expiry the operator enters, used when GitHub reports none
  (a fine-grained token's header was seen to misreport it). `repos`: the
  repositories it reaches (JSON list of owner/name), so each subscribed repo
  is read with a token that can see it.
  """
  use Ecto.Migration

  def change do
    alter table(:github_tokens) do
      add :expires_on, :date
      add :repos, :text
    end
  end
end
