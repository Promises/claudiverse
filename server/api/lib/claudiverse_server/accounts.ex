defmodule ClaudiverseServer.Accounts do
  import Ecto.Query

  alias ClaudiverseServer.Repo
  alias ClaudiverseServer.Accounts.{User, UserToken}

  # "api": the shared fleet token every seat carries, and what a web login
  # issues. "app": the operator's app — the only caller allowed to force a
  # message into a busy seat (NotifyController.send). Neither expires; a token
  # lives until it is deleted.
  # "api": seats and the web (the fleet shares one). "app": the operator's
  # app — force send, permission mode, New seat, stop/resume. "super": all of
  # "app" plus managing the machines and the tokens themselves (the desktop).
  @token_contexts ["api", "app", "super"]
  @app_contexts ["app", "super"]

  @doc "May this token context use the operator-app endpoints?"
  def app_powers?(context), do: context in @app_contexts

  @doc "May this token context manage machines and tokens?"
  def super_powers?(context), do: context == "super"

  def get_user!(id), do: Repo.get!(User, id)

  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  def authenticate_user(email, password) do
    user = get_user_by_email(email)

    if User.valid_password?(user, password) do
      {:ok, user}
    else
      {:error, :invalid_credentials}
    end
  end

  def create_user_api_token(user, context \\ "api", label \\ nil) when context in @token_contexts do
    {token, user_token} = UserToken.build_token(user, context, label)
    Repo.insert!(user_token)
    Base.url_encode64(token)
  end

  # For the HTTP API and the proxy: a "host:<name>" token is NOT accepted
  # there. It exists only to join that host's own channel (HostChannel).
  def fetch_user_by_api_token(token) do
    case fetch_api_token(token) do
      {:ok, _user, "host:" <> _} -> {:error, :host_token}
      {:ok, user, _context} -> {:ok, user}
      error -> error
    end
  end

  @doc """
  Mint a per-machine token for a host agent, context "host:<name>". It is
  BOUND to that name: it can join only "host:<name>" and is refused
  everywhere else, so a seat (which carries the shared "api" token) can never
  pose as a host, and one host cannot pose as another.
  """
  def create_host_token(user, name) when is_binary(name) do
    if Regex.match?(~r/\A[A-Za-z0-9._-]{1,128}\z/, name) do
      {token, user_token} = UserToken.build_token(user, "host:" <> name)
      Repo.insert!(user_token)
      {:ok, Base.url_encode64(token)}
    else
      {:error, :bad_host_name}
    end
  end

  @doc """
  The two tokens a new machine's setup needs, minted together: a seat token
  ("api", labelled with the machine's name, so the token list shows whose it
  is) for its mod and host agent, and a host token bound to `name` for its
  host agent. `{:ok, %{seat_token: t, host_token: t}}` or
  `{:error, :bad_host_name}`.
  """
  def connect_machine(user, name) when is_binary(name) do
    with {:ok, host_token} <- create_host_token(user, name) do
      {:ok, %{seat_token: create_user_api_token(user, "api", name), host_token: host_token}}
    end
  end

  @doc "The user a bearer token belongs to, and the token's context (\"api\", \"app\" or \"super\")."
  def fetch_api_token(token) do
    with {:ok, decoded} <- Base.url_decode64(token),
         {%User{} = user, context} <- Repo.one(UserToken.by_token_and_contexts_query(decoded, @token_contexts)) do
      {:ok, user, context}
    else
      _ -> {:error, :invalid_token}
    end
  end

  @doc """
  Revoke the ONE token presented, never the user's others. The shared fleet
  token is an "api" token of the same user, so revoking all of them on a
  logout took every seat offline at once. An "app" or "super" token is
  revoked only if a sign-in handed it out (it has a label): one minted out of
  band (`mint_app_token`) is never revoked by a logout.
  """
  def delete_api_token(token) do
    case Base.url_decode64(token) do
      {:ok, decoded} ->
        Repo.delete_all(
          from t in UserToken,
            where: t.token == ^decoded and (t.context == "api" or (t.context in @app_contexts and not is_nil(t.label)))
        )

      :error ->
        {0, nil}
    end
  end

  @doc "The id of the token with this bearer value, if it exists."
  def token_id(token) when is_binary(token) do
    with {:ok, decoded} <- Base.url_decode64(token),
         id when is_integer(id) <- Repo.one(from t in UserToken, where: t.token == ^decoded, select: t.id) do
      {:ok, id}
    else
      _ -> :error
    end
  end

  def token_id(_), do: :error

  @doc "The user's tokens, newest first — never their values."
  def list_tokens(user) do
    from(t in UserToken,
      where: t.user_id == ^user.id,
      order_by: [desc: t.inserted_at, desc: t.id],
      select: %{id: t.id, context: t.context, label: t.label, inserted_at: t.inserted_at}
    )
    |> Repo.all()
  end

  @doc """
  Revoke one of the user's tokens by id: a lost phone's app token, a
  sign-in, a machine's host token. Only an unlabelled "api" token is refused:
  it may be the fleet's shared seat token, whose loss takes every seat
  offline. Revoke that one on the server.
  """
  def revoke_token(user, id) do
    case Repo.get_by(UserToken, id: id, user_id: user.id) do
      nil ->
        {:error, :not_found}

      %UserToken{context: "host:" <> _} = t ->
        Repo.delete!(t)
        :ok

      %UserToken{context: "api", label: nil} ->
        {:error, :protected}

      t ->
        Repo.delete!(t)
        :ok
    end
  end
end
