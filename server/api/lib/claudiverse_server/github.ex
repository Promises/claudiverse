defmodule ClaudiverseServer.GitHub do
  @moduledoc """
  The operator's GitHub tokens: one per resource owner (a fine-grained token
  reaches one owner's repos: their own, or an organisation's), read-only.

  A token is checked against GitHub when it is added, and on request: its
  account (`GET /user`), what kind it is (from its prefix), a classic token's
  scopes (`X-OAuth-Scopes`), its expiry (`GitHub-Authentication-Token-Expiration`,
  absent for a token that never expires) and how many repos it reaches
  (`GET /user/repos`). GitHub does not report a fine-grained token's
  permissions; only a call it refuses names the one it lacked.

  Stored encrypted (Vault, "github_tokens.v1"); never logged, never returned
  by any API.
  """
  import Ecto.Query

  alias ClaudiverseServer.AnthropicAuths.Vault
  alias ClaudiverseServer.GitHub.{Client, Cursor, Poller, Token}
  alias ClaudiverseServer.Notifications.Router
  alias ClaudiverseServer.Repo

  @aad "github_tokens.v1"
  @label ~r/\A[A-Za-z0-9._ -]{1,64}\z/
  @secret ~r/\A[A-Za-z0-9_]{20,255}\z/
  # /user/repos pages of 100: past this many a count reads "at least".
  @max_pages 20
  @warn_days 7

  def list(user_id), do: Repo.all(from t in Token, where: t.user_id == ^user_id, order_by: t.label)

  def get(user_id, id), do: Repo.one(from t in Token, where: t.user_id == ^user_id and t.id == ^id)

  @doc "The plaintext token, for a call to GitHub. Never for a response or a log."
  def secret(%Token{token: ct}), do: Vault.decrypt(ct, @aad)

  @doc """
  Check `secret` against GitHub and store it as `label`. {:ok, token},
  {:error, :vault} (no key: never stored in the clear), {:error, :bad_label},
  {:error, :bad_token} (not a GitHub token's shape), {:error, :taken}, or
  {:error, {:github, sentence}} (GitHub refused it, or could not be reached).
  """
  def add(user_id, label, secret) do
    label = if is_binary(label), do: String.trim(label), else: ""
    secret = if is_binary(secret), do: String.trim(secret), else: ""

    cond do
      not Vault.configured?() -> {:error, :vault}
      not Regex.match?(@label, label) -> {:error, :bad_label}
      not Regex.match?(@secret, secret) -> {:error, :bad_token}
      Repo.exists?(from t in Token, where: t.user_id == ^user_id and t.label == ^label) -> {:error, :taken}
      true ->
        case inspect_token(secret) do
          {:ok, facts} ->
            now = DateTime.utc_now() |> DateTime.truncate(:second)

            %Token{user_id: user_id, label: label, token: Vault.encrypt(secret, @aad), kind: kind(secret)}
            |> Ecto.Changeset.change(Map.merge(facts, %{status: "ok", last_error: nil, checked_at: now}))
            |> Repo.insert()

          {:error, {:github, why, _status}} ->
            {:error, {:github, why}}
        end
    end
  end

  @doc "Check a stored token again: its account, scopes, expiry and repos, or why GitHub refused it."
  def check(%Token{} = t) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    changes =
      case secret(t) do
        nil -> %{status: "error", last_error: "it cannot be decrypted with this server's CV_VAULT_KEY; add it again"}
        secret ->
          case inspect_token(secret) do
            {:ok, facts} -> Map.merge(facts, %{status: "ok", last_error: nil})
            {:error, {:github, why, status}} -> %{status: status, last_error: why}
          end
      end

    t |> Ecto.Changeset.change(Map.put(changes, :checked_at, now)) |> Repo.update()
  end

  def delete(%Token{} = t), do: Repo.delete(t)

  @doc """
  What `user_id`'s seats watch of GitHub, and how each is read: one entry per
  title (`gh:…`, `@github`), with the seats watching it; for a repository, the
  token that reads it (the least privileged that reaches it: GitHub.Poller)
  or nil if none does, and when it was last read.
  """
  def subscriptions(user_id) do
    usable = user_id |> list() |> Enum.reject(&(&1.status == "unauthorized"))

    by_title =
      for {seat, titles} <- Router.watchers(user_id), t <- titles, String.starts_with?(t, "gh:") or t == "@github", reduce: %{} do
        acc -> Map.update(acc, t, [seat], &[seat | &1])
      end

    for {title, seats} <- Enum.sort(by_title) do
      repo = Poller.repo_of(title)
      token = repo && Poller.route(usable, repo)

      %{
        title: title,
        seats: Enum.sort(seats),
        repo: repo,
        token: token && %{id: token.id, label: token.label, kind: token.kind},
        reached: if(repo, do: token != nil, else: usable != []),
        # Why a repository is not read: no token reaches it, or a token's list
        # of repositories was never loaded (the poller loads it on its next tick).
        unreached: cond do
          repo == nil or token != nil -> nil
          Enum.any?(usable, &(&1.repos == nil)) -> "repos_not_loaded"
          true -> "no_token"
        end,
        last_read_at: repo && Cursor.read_at(user_id, "repo:" <> repo)
      }
    end
  end

  @doc "Each token's id => the watched repositories it reads (from `subscriptions/1`)."
  def serving(subscriptions) do
    for %{repo: repo, token: %{id: id}} <- subscriptions, reduce: %{} do
      acc -> Map.update(acc, id, [repo], &Enum.uniq([repo | &1]))
    end
    |> Map.new(fn {id, repos} -> {id, Enum.sort(repos)} end)
  end

  @doc "Every repository `user_id`'s tokens reach, with the token that would read it: [%{repo, token}]."
  def repos(user_id) do
    usable = user_id |> list() |> Enum.reject(&(&1.status == "unauthorized"))

    usable
    |> Enum.flat_map(&(&1.repos || []))
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.sort_by(&String.downcase/1)
    |> Enum.map(fn repo ->
      t = Poller.route(usable, repo)
      %{repo: repo, token: %{id: t.id, label: t.label, kind: t.kind}}
    end)
  end

  @doc "The users that have a GitHub token."
  def users_with_tokens, do: Repo.all(from t in Token, distinct: true, select: t.user_id)

  @doc "Record what a read found about `t`: its status and why."
  def mark(%Token{} = t, status, why) do
    t |> Ecto.Changeset.change(status: status, last_error: why, checked_at: DateTime.utc_now() |> DateTime.truncate(:second)) |> Repo.update()
  end

  @doc """
  When `t` expires: what GitHub reported, else what the operator entered (the
  end of that day, UTC), else nil (never, as far as anyone said). Returns
  {at, :github | :manual} or nil.
  """
  def expiry_of(%Token{expires_at: %DateTime{} = at}), do: {at, :github}
  def expiry_of(%Token{expires_on: %Date{} = d}), do: {DateTime.new!(d, ~T[23:59:59], "Etc/UTC"), :manual}

  def expiry_of(%Token{}), do: nil

  @doc "Whether `t` expires within #{@warn_days} days (or has expired)."
  def expiring?(%Token{} = t, now) do
    case expiry_of(t) do
      {at, _} -> DateTime.diff(at, now) < @warn_days * 86_400
      nil -> false
    end
  end

  @doc "Set or clear (nil) the expiry the operator entered, an ISO date."
  def set_expires_on(%Token{} = t, nil), do: t |> Ecto.Changeset.change(expires_on: nil) |> Repo.update()

  def set_expires_on(%Token{} = t, date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, d} -> t |> Ecto.Changeset.change(expires_on: d) |> Repo.update()
      _ -> {:error, :bad_date}
    end
  end

  def set_expires_on(_t, _), do: {:error, :bad_date}

  @doc "What its prefix says it is."
  def kind("github_pat_" <> _), do: "fine_grained"
  def kind("ghp_" <> _), do: "classic"
  def kind(_), do: "other"

  # --- asking GitHub ------------------------------------------------------------------

  defp inspect_token(secret) do
    case Client.get(secret, "/user") do
      {:ok, %{status: 200, body: %{"login" => login}} = r} ->
        repos = list_repos(secret)

        {:ok, %{login: login, scopes: scopes(r), expires_at: expiry(r, DateTime.utc_now()), repos: repos,
                repos_count: repos && length(repos)}}

      {:ok, %{status: 401}} ->
        {:error, {:github, "GitHub refused the token (401): it is wrong, expired or revoked", "unauthorized"}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:github, "GitHub answered #{status}#{message(body)}", "error"}}

      {:error, why} ->
        {:error, {:github, "GitHub could not be reached: #{why}", "error"}}
    end
  end

  defp message(%{"message" => m}) when is_binary(m), do: ": " <> String.slice(m, 0, 200)
  defp message(_), do: ""

  # A classic token's scopes; a fine-grained token has none to report.
  defp scopes(%{headers: %{"x-oauth-scopes" => s}}), do: s
  defp scopes(_), do: nil

  @doc """
  The expiry in `GitHub-Authentication-Token-Expiration` ("2026-11-10 16:20:42
  +0500", or "… UTC"), or nil: no header (a token that never expires), or a
  value not after `now` on an answer GitHub served (an expired token is
  refused: a past value is GitHub misreporting, as it was seen to for
  fine-grained tokens, which returned the current time).
  """
  def expiry(%{headers: %{"github-authentication-token-expiration" => v}}, now) do
    with [_, date, time, zone] <- Regex.run(~r/\A(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}) (UTC|[+-]\d{4})\z/, String.trim(v)),
         {:ok, naive} <- NaiveDateTime.from_iso8601("#{date}T#{time}"),
         at = DateTime.from_naive!(naive, "Etc/UTC") |> DateTime.add(-offset_s(zone)),
         true <- DateTime.compare(at, DateTime.add(now, 60)) == :gt do
      DateTime.truncate(at, :second)
    else
      _ -> nil
    end
  end

  def expiry(_, _now), do: nil

  defp offset_s("UTC"), do: 0

  defp offset_s(<<sign, hh::binary-size(2), mm::binary-size(2)>>) do
    s = String.to_integer(hh) * 3600 + String.to_integer(mm) * 60
    if sign == ?-, do: -s, else: s
  end

  # owner/name of each repository the token reaches, or nil if GitHub would not say.
  defp list_repos(secret), do: list_repos(secret, "/user/repos?per_page=100", [], 0)

  defp list_repos(_secret, _url, acc, @max_pages), do: Enum.reverse(acc)

  defp list_repos(secret, url, acc, pages) do
    case Client.get(secret, url) do
      {:ok, %{status: 200, body: repos} = r} when is_list(repos) ->
        acc = Enum.reduce(repos, acc, fn repo, a -> if is_binary(repo["full_name"]), do: [repo["full_name"] | a], else: a end)

        case Client.next_page(r) do
          nil -> Enum.reverse(acc)
          next -> list_repos(secret, next, acc, pages + 1)
        end

      _ ->
        if acc == [], do: nil, else: Enum.reverse(acc)
    end
  end
end
