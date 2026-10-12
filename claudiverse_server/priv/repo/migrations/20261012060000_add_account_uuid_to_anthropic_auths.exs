defmodule ClaudiverseServer.Repo.Migrations.AddAccountUuidToAnthropicAuths do
  @moduledoc """
  The Anthropic account a pool row's credentials belong to, by its stable id
  (the token response's `account.uuid`), beside its email: what re-authorization
  checks a login against.
  """
  use Ecto.Migration

  def change do
    alter table(:anthropic_auths) do
      add :account_uuid, :string
    end
  end
end
