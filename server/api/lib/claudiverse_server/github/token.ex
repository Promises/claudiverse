defmodule ClaudiverseServer.GitHub.Token do
  @moduledoc "A stored GitHub token (`github_tokens`). `token` is the ciphertext; it never leaves the server."
  use Ecto.Schema

  schema "github_tokens" do
    field :label, :string
    field :token, :binary, redact: true
    field :kind, :string
    field :login, :string
    field :scopes, :string
    field :expires_at, :utc_datetime
    # Entered by the operator; used when GitHub reports no expiry.
    field :expires_on, :date
    # owner/name of each repository it reaches, at its last check.
    field :repos, {:array, :string}
    field :repos_count, :integer
    field :status, :string, default: "ok"
    field :last_error, :string
    field :checked_at, :utc_datetime
    belongs_to :user, ClaudiverseServer.Accounts.User
    timestamps()
  end
end
