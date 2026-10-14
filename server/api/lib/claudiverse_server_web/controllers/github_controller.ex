defmodule ClaudiverseServerWeb.GitHubController do
  @moduledoc """
  The operator's GitHub tokens (ClaudiverseServer.GitHub). App or super token
  only: a GitHub token reaches the operator's private repos.

  - `GET /api/github/tokens` → {tokens, vault_configured}
  - `POST /api/github/tokens` {label, token} → 201 {token}: checked against
    GitHub first, then stored encrypted
  - `POST /api/github/tokens/:id/check` → {token}: asks GitHub again
  - `PATCH /api/github/tokens/:id` {expires_on: "YYYY-MM-DD" | null} → {token}:
    the expiry used when GitHub reports none
  - `DELETE /api/github/tokens/:id` → 204
  - `GET /api/github/subscriptions` → {subscriptions}: what the user's seats
    watch of GitHub and the token that reads each (any token: cv_gh_subscriptions)
  - `GET /api/github/repos` → {repos}: every repository the tokens reach (any
    token: cv_gh_repos)

  A token's secret is never in a response: `serialize/2` lists its fields.
  """
  use ClaudiverseServerWeb, :controller

  alias ClaudiverseServer.AnthropicAuths.Vault
  alias ClaudiverseServer.GitHub

  # The two lists a seat reads for its own subscriptions; the tokens are the operator's.
  plug :app_only when action not in [:subscriptions, :repos]

  def index(conn, _params) do
    now = DateTime.utc_now()
    serving = conn |> user_id() |> GitHub.subscriptions() |> GitHub.serving()

    tokens = for t <- GitHub.list(user_id(conn)), do: t |> serialize(now) |> Map.put(:serving, Map.get(serving, t.id, []))
    json(conn, %{tokens: tokens, vault_configured: Vault.configured?()})
  end

  def subscriptions(conn, _params), do: json(conn, %{subscriptions: GitHub.subscriptions(user_id(conn))})

  def repos(conn, _params), do: json(conn, %{repos: GitHub.repos(user_id(conn))})

  def create(conn, params) do
    case GitHub.add(user_id(conn), params["label"], params["token"]) do
      {:ok, t} -> conn |> put_status(:created) |> json(%{token: serialize(t, DateTime.utc_now())})
      {:error, :vault} -> error(conn, :service_unavailable, "CV_VAULT_KEY is not set on the server: a token is never stored unencrypted")
      {:error, :bad_label} -> error(conn, :bad_request, "label must be 1-64 of A-Z a-z 0-9 . _ - and spaces")
      {:error, :bad_token} -> error(conn, :bad_request, "that is not a GitHub token (github_pat_… or ghp_…)")
      {:error, :taken} -> error(conn, :conflict, "a token with that label exists")
      {:error, {:github, why}} -> error(conn, :unprocessable_entity, why)
      {:error, %Ecto.Changeset{}} -> error(conn, :conflict, "a token with that label exists")
    end
  end

  def check(conn, %{"id" => id}) do
    with %GitHub.Token{} = t <- GitHub.get(user_id(conn), id),
         {:ok, t} <- GitHub.check(t) do
      json(conn, %{token: serialize(t, DateTime.utc_now())})
    else
      nil -> error(conn, :not_found, "no such token")
    end
  end

  def update(conn, %{"id" => id} = params) do
    with %GitHub.Token{} = t <- GitHub.get(user_id(conn), id),
         true <- Map.has_key?(params, "expires_on") || :nothing,
         {:ok, t} <- GitHub.set_expires_on(t, params["expires_on"]) do
      json(conn, %{token: serialize(t, DateTime.utc_now())})
    else
      nil -> error(conn, :not_found, "no such token")
      :nothing -> error(conn, :bad_request, "expires_on is the only field that can be changed")
      {:error, :bad_date} -> error(conn, :bad_request, "expires_on must be a date, YYYY-MM-DD, or null")
    end
  end

  def delete(conn, %{"id" => id}) do
    case GitHub.get(user_id(conn), id) do
      nil -> error(conn, :not_found, "no such token")
      t -> {:ok, _} = GitHub.delete(t); send_resp(conn, :no_content, "")
    end
  end

  @doc "A token as the API shows it: what GitHub said about it, never the token."
  def serialize(t, now) do
    %{
      id: t.id, label: t.label, kind: t.kind, login: t.login,
      scopes: t.scopes && t.scopes |> String.split(",", trim: true) |> Enum.map(&String.trim/1),
      expires_at: expiry_at(t), expiry_source: expiry_source(t), expires_on: t.expires_on,
      expiring: GitHub.expiring?(t, now), repos_count: t.repos_count,
      status: t.status, last_error: t.last_error, checked_at: t.checked_at
    }
  end

  defp expiry_at(t), do: with({at, _} <- GitHub.expiry_of(t), do: at)
  defp expiry_source(t), do: with({_, source} <- GitHub.expiry_of(t), do: Atom.to_string(source))

  defp app_only(conn, _opts) do
    if ClaudiverseServer.Accounts.app_powers?(conn.assigns[:token_context]),
      do: conn,
      else: conn |> error(:forbidden, "GitHub tokens are app-only") |> halt()
  end

  defp user_id(conn), do: conn.assigns.current_user.id
  defp error(conn, status, message), do: conn |> put_status(status) |> json(%{error: message})
end
