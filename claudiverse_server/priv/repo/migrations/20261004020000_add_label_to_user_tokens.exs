defmodule ClaudiverseServer.Repo.Migrations.AddLabelToUserTokens do
  @moduledoc """
  Which client a sign-in token was handed to ("desktop", "android", "web"),
  so the operator can tell signed-in devices apart and revoke one. Null for
  tokens minted out of band (the fleet's shared seat token, `mint_app_token`,
  host tokens): those are never revoked by a logout or from the token list.
  """
  use Ecto.Migration

  def change do
    alter table(:user_tokens) do
      add :label, :string
    end
  end
end
