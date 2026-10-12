defmodule ClaudiverseServerWeb.AuthController do
  use ClaudiverseServerWeb, :controller

  alias ClaudiverseServer.Accounts

  # There is no open registration. The first account signs up with the
  # server's one-time setup code (setup/2); later ones are created out of band
  # with `mix claudiverse.register <email> <password>`.

  alias ClaudiverseServer.{LoginThrottle, Setup}

  # What a sign-in may ask for. "api" (the default) is what the web uses;
  # "app" the phone's powers; "super" the desktop's, which also manages the
  # machines and the tokens.
  @scopes ~w(api app super)
  @label ~r/\A[A-Za-z0-9 ._-]{1,64}\z/

  @doc """
  POST /api/auth/login  %{"email", "password", "scope"?, "client"?}

  `scope` api (default) | app | super; `client` names the device, shown in
  the token list ("desktop", "pixel-10"). A sign-in token can be revoked by
  its own logout and from the token list. Failed attempts are throttled per
  address (LoginThrottle): 429 with retry_after.
  """
  def login(conn, %{"email" => email, "password" => password} = params) when is_binary(email) and is_binary(password) do
    with_sign_in(conn, params, fn conn, scope, client ->
      case Accounts.authenticate_user(email, password) do
        {:ok, user} ->
          LoginThrottle.succeeded(conn.remote_ip)
          signed_in(conn, user, scope, client)

        {:error, :invalid_credentials} ->
          LoginThrottle.failed(conn.remote_ip)

          conn
          |> put_status(:unauthorized)
          |> json(%{error: "Invalid email or password"})
      end
    end)
  end

  def login(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "email and password are required"})
  end

  @doc """
  GET /api/setup — `{"setup_needed": bool}`: does this server still need its
  first account? Public, so the web panel can open its sign-up page; it says
  nothing else about the server.
  """
  def setup_status(conn, _params), do: json(conn, %{setup_needed: Setup.needed?()})

  @doc """
  POST /api/setup  %{"email", "password", "code", "scope"?, "client"?}

  Creates the FIRST account with the setup code the server logged, and signs
  it in as login/2 does. 403 once any account exists, whatever the code;
  403 for a wrong code; 422 for an email or password the account rules
  refuse (the code stays valid). Throttled with sign-in (LoginThrottle).
  """
  def setup(conn, %{"email" => email, "password" => password, "code" => code} = params)
      when is_binary(email) and is_binary(password) and is_binary(code) do
    with_sign_in(conn, params, fn conn, scope, client ->
      case Setup.sign_up(code, %{email: email, password: password}) do
        {:ok, user} ->
          LoginThrottle.succeeded(conn.remote_ip)
          signed_in(conn, user, scope, client)

        {:error, :closed} ->
          LoginThrottle.failed(conn.remote_ip)
          conn |> put_status(:forbidden) |> json(%{error: "this server already has an account; sign in instead"})

        {:error, :bad_code} ->
          LoginThrottle.failed(conn.remote_ip)
          conn |> put_status(:forbidden) |> json(%{error: "wrong setup code; use the newest one in the server's log"})

        {:error, %Ecto.Changeset{} = cs} ->
          conn |> put_status(:unprocessable_entity) |> json(%{errors: errors(cs)})
      end
    end)
  end

  def setup(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "email, password and code are required"})
  end

  def logout(conn, _params) do
    Accounts.delete_api_token(conn.assigns.api_token)
    json(conn, %{ok: true})
  end

  def me(conn, _params) do
    user = conn.assigns.current_user
    json(conn, %{user: %{id: user.id, email: user.email}, scope: conn.assigns[:token_context]})
  end

  # The checks a sign-in shares (login/2, setup/2): the scope and client
  # asked for, and the throttle. `fun` runs only when they pass.
  defp with_sign_in(conn, params, fun) do
    scope = params["scope"] || "api"
    client = params["client"]

    cond do
      scope not in @scopes ->
        conn |> put_status(:bad_request) |> json(%{error: "scope must be one of #{Enum.join(@scopes, ", ")}"})

      not (is_nil(client) or (is_binary(client) and Regex.match?(@label, client))) ->
        conn |> put_status(:bad_request) |> json(%{error: "client must be 1-64 of A-Z a-z 0-9 space . _ -"})

      true ->
        case LoginThrottle.check(conn.remote_ip) do
          {:error, retry_after} ->
            conn
            |> put_resp_header("retry-after", Integer.to_string(retry_after))
            |> put_status(:too_many_requests)
            |> json(%{error: "too many failed sign-ins; try again in #{retry_after} s", retry_after: retry_after})

          :ok ->
            fun.(conn, scope, client)
        end
    end
  end

  defp signed_in(conn, user, scope, client) do
    token = Accounts.create_user_api_token(user, scope, client || scope)
    json(conn, %{token: token, scope: scope, user: %{id: user.id, email: user.email}})
  end

  defp errors(cs),
    do:
      Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
      end)
end
