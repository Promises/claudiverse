defmodule ClaudiverseServer.Accounts.UserToken do
  use Ecto.Schema
  import Ecto.Query

  @rand_size 32

  schema "user_tokens" do
    field :token, :binary
    field :context, :string
    # The client a sign-in handed it to; nil for out-of-band tokens.
    field :label, :string

    belongs_to :user, ClaudiverseServer.Accounts.User

    timestamps(updated_at: false)
  end

  def build_token(user, context, label \\ nil) do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, %__MODULE__{token: token, context: context, label: label, user_id: user.id}}
  end

  def by_token_and_context_query(token, context) do
    from t in __MODULE__,
      where: t.token == ^token and t.context == ^context,
      join: u in assoc(t, :user),
      select: u
  end

  # `contexts`, plus any per-host "host:<name>" context (see Accounts).
  def by_token_and_contexts_query(token, contexts) do
    from t in __MODULE__,
      where: t.token == ^token and (t.context in ^contexts or like(t.context, "host:%")),
      join: u in assoc(t, :user),
      select: {u, t.context}
  end
end
