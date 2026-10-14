defmodule ClaudiverseServer.GitHub.Poller do
  @moduledoc """
  Reads GitHub for the `gh:` titles seats watch, and pings them (Router).

  The server has no public URL, so GitHub cannot call it: it asks. Only
  repositories some seat watches are read, each with a token of its user that
  reaches it (`repos`), every #{60} s, or the `X-Poll-Interval` GitHub asks
  for if longer:

  - `GET /repos/:repo/issues?state=all&sort=updated&since=` (pull requests are
    in it): opened, closed and merged, by their own times;
  - `GET /repos/:repo/issues/comments?since=`: comments on either;
  - for each pull request that changed, `GET /repos/:repo/pulls/:n/reviews`;
  - `GET /repos/:repo/pulls?state=open`, and for each open pull request whose
    head's checks have not settled, that commit's combined status and its
    Actions runs: a head settling on passed or failed is sent once.

  A repository's window runs from its cursor (`github_cursors`) to GitHub's
  own clock less #{2} s. The cursor moves only when every request of a read
  succeeded, and only then is anything sent, so a failure reads the window
  again rather than losing or repeating it. A repository read for the first
  time sends nothing: it only starts its cursor. A restart therefore fires
  nothing twice.

  `gh:@me` is GitHub's search, every #{180} s per token: what is open and
  awaits the token's owner (a review requested, assigned, mentioned). An item
  new to a search's last results is sent once.

  `@github` hears of the tokens: one GitHub refused (401) and one within 7
  days of its expiry, once each.

  A token GitHub rate-limits (`X-RateLimit-Remaining: 0`, or `Retry-After`)
  is left alone until its reset. Disabled in tests, which call `poll_repo/3`,
  `poll_me/2` and `check_tokens/2` themselves.
  """
  use GenServer
  require Logger

  alias ClaudiverseServer.GitHub
  alias ClaudiverseServer.GitHub.{Client, Cursor, Events, Token}
  alias ClaudiverseServer.Notifications.Router

  @tick_ms 15_000
  @repo_every_s 60
  @me_every_s 180
  @margin_s 2
  @repos_max_age_s 6 * 3600
  @unreached_max_age_s 600
  @max_pages 5
  @me_queries [
    {"review-requested", "is:open is:pr review-requested:@me", "review requested from you"},
    {"assigned", "is:open assignee:@me", "assigned to you"},
    {"mentioned", "is:open mentions:@me", "you were mentioned"}
  ]
  @repo_title ~r/\Agh:([A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100})(?::(?:prs|issues)|#\d{1,10})?\z/

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    if enabled?(), do: Process.send_after(self(), :tick, @tick_ms)
    # next: {user, source} => when it is due (monotonic s). paused: token id => until.
    {:ok, %{next: %{}, paused: %{}, running: false}}
  end

  defp enabled?, do: Keyword.get(Application.get_env(:claudiverse_server, __MODULE__, []), :enabled, true)

  @impl true
  def handle_info(:tick, %{running: true} = state) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    me = self()
    Task.Supervisor.start_child(ClaudiverseServer.Tasks, fn -> send(me, {:ticked, tick(state)}) end)
    {:noreply, %{state | running: true}}
  end

  def handle_info({:ticked, %{next: next, paused: paused}}, state),
    do: {:noreply, %{state | next: next, paused: paused, running: false}}

  def handle_info(_msg, state), do: {:noreply, state}

  # One pass over every user with tokens. Returns the schedule it leaves.
  defp tick(state) do
    now = System.monotonic_time(:second)

    Enum.reduce(GitHub.users_with_tokens(), state, fn user_id, st ->
      %{repos: repos, me: me?} = watched(user_id)
      tokens = fresh_tokens(user_id, repos)
      check_tokens(user_id, tokens)
      usable = Enum.reject(tokens, &(&1.status == "unauthorized" or paused?(st, &1, now)))

      st =
        Enum.reduce(repos, st, fn repo, acc ->
          due(acc, {user_id, repo}, now, fn ->
            case route(usable, repo) do
              nil -> {:skip, @repo_every_s}
              token -> outcome(acc, token, poll_repo(user_id, repo, token), now)
            end
          end)
        end)

      if me? and usable != [],
        do: due(st, {user_id, :me}, now, fn -> outcome(st, hd(usable), poll_me(user_id, usable), now) end),
        else: st
    end)
  rescue
    e ->
      Logger.warning("[github] poll failed: #{Exception.message(e)}")
      state
  end

  # (Monotonic time is often negative: "never scheduled" must not read as 0.)
  defp due(st, key, now, fun) do
    if Map.has_key?(st.next, key) and st.next[key] > now do
      st
    else
      case fun.() do
        {:paused, token_id, until, every} -> %{st | next: Map.put(st.next, key, now + every), paused: Map.put(st.paused, token_id, until)}
        {_, every} -> %{st | next: Map.put(st.next, key, now + every)}
      end
    end
  end

  defp outcome(_st, token, result, now) do
    case result do
      {:ok, interval} -> {:ok, interval}
      {:rate_limited, wait_s} -> {:paused, token.id, now + wait_s, wait_s}
      {:unauthorized, _} -> {:skip, @repo_every_s}
      {:error, _} -> {:skip, @repo_every_s}
    end
  end

  defp paused?(st, token, now), do: Map.has_key?(st.paused, token.id) and st.paused[token.id] > now

  @doc "The repository a `gh:` title is about, or nil (`gh:@me`, any other title)."
  def repo_of(title) do
    case Regex.run(@repo_title, title, capture: :all_but_first) do
      [repo] -> repo
      _ -> nil
    end
  end

  @doc """
  `user_id`'s tokens, each with a repository list fresh enough to route by.
  A token is checked again (GitHub.check: its account and the repositories it
  reaches) when its list was never loaded (a token checked before lists were
  kept, MEASURED 2026-10-14: both live tokens routed nothing), when it is over
  #{div(6 * 3600, 3600)} h old (repositories get created), and, for a watched
  repository no token reaches, when it is over #{div(600, 60)} min old: a token
  is refreshed before a repository is said to be out of reach.
  """
  def fresh_tokens(user_id, repos) do
    now = DateTime.utc_now()
    tokens = user_id |> GitHub.list() |> Enum.map(&refresh_if(&1, now, @repos_max_age_s))

    if Enum.any?(repos, &(route(usable(tokens), &1) == nil)),
      do: Enum.map(tokens, &refresh_if(&1, now, @unreached_max_age_s)),
      else: tokens
  end

  defp usable(tokens), do: Enum.reject(tokens, &(&1.status == "unauthorized"))

  defp refresh_if(%Token{status: "unauthorized"} = t, _now, _age), do: t

  defp refresh_if(t, now, max_age) do
    age = if t.checked_at, do: DateTime.diff(now, t.checked_at), else: :infinity
    # A list GitHub would not give is asked for again, but not every tick.
    stale? = age > max_age or (t.repos == nil and age > 60)

    with true <- stale?, {:ok, fresh} <- GitHub.check(t) do
      fresh
    else
      _ -> t
    end
  end

  @doc "The repositories and whether `gh:@me` is watched by `user_id`'s seats."
  def watched(user_id) do
    titles = Router.watched(user_id)

    %{
      repos: titles |> Enum.flat_map(&(Regex.run(@repo_title, &1, capture: :all_but_first) || [])) |> Enum.uniq(),
      me: "gh:@me" in titles
    }
  end

  @doc """
  The least-privileged token of the user's that reaches `repo` (case does not
  matter to GitHub), or nil: a fine-grained token (read-only, one owner) if
  any reaches it; a classic token (every repository its account can, and
  write) only for a repository none does.
  """
  def route(tokens, repo) do
    r = String.downcase(repo)

    tokens
    |> Enum.filter(fn t -> Enum.any?(t.repos || [], &(String.downcase(&1) == r)) end)
    |> Enum.min_by(&privilege/1, fn -> nil end)
  end

  defp privilege(%Token{kind: "fine_grained"}), do: 0
  defp privilege(%Token{kind: "classic"}), do: 2
  defp privilege(_), do: 1

  # --- a repository ---------------------------------------------------------------

  @doc """
  Read `repo` since its cursor with `token` and ping what happened. {:ok,
  seconds until the next read}, {:rate_limited, seconds}, {:unauthorized, why}
  or {:error, why}.
  """
  def poll_repo(user_id, repo, %Token{} = token) do
    source = "repo:" <> repo
    cursor = Cursor.get(user_id, source) || %{}
    since = cursor["since"]
    secret = GitHub.secret(token)
    issues = "/repos/#{repo}/issues?state=all&sort=updated&direction=asc&per_page=100" <> since_param(since)

    with {:ok, first} <- ask(user_id, token, secret, issues) do
      to = DateTime.add(server_time(first), -@margin_s)
      interval = max(@repo_every_s, poll_interval(first))

      case since && parse(since) do
        nil ->
          :ok = Cursor.put(user_id, source, %{"since" => DateTime.to_iso8601(to), "ci" => nil})
          {:ok, interval}

        from ->
          with {:ok, items} <- pages(user_id, token, secret, first),
               {:ok, comments} <- get_all(user_id, token, secret, "/repos/#{repo}/issues/comments?sort=created&direction=asc&per_page=100&since=#{DateTime.to_iso8601(from)}"),
               {:ok, reviews} <- reviews(user_id, token, secret, repo, items, from),
               {:ok, open} <- get_all(user_id, token, secret, "/repos/#{repo}/pulls?state=open&per_page=100"),
               {:ok, ci, ci_events} <- checks(user_id, token, secret, repo, open, cursor["ci"]) do
            titles = Map.new(items, &{&1["number"], {&1["title"], is_map(&1["pull_request"])}})

            events =
              Events.from_issues(repo, items, from, to) ++
                Events.from_comments(repo, comments, titles, from, to) ++
                Enum.flat_map(reviews, fn {n, title, rs} -> Events.from_reviews(repo, n, title, rs, from, to) end) ++
                ci_events

            :ok = Cursor.put(user_id, source, %{"since" => DateTime.to_iso8601(to), "ci" => ci})
            for e <- events, do: Router.github(user_id, Events.titles(e), Events.text(e))
            {:ok, interval}
          end
      end
    end
  end

  defp since_param(nil), do: ""
  defp since_param(since), do: "&since=" <> URI.encode_www_form(since)

  # The reviews of each pull request in `items` that changed since `from`.
  defp reviews(user_id, token, secret, repo, items, from) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      if is_map(item["pull_request"]) and Events.within?(item["updated_at"], from, DateTime.add(DateTime.utc_now(), 3600)) do
        case get_all(user_id, token, secret, "/repos/#{repo}/pulls/#{item["number"]}/reviews?per_page=100") do
          {:ok, rs} -> {:cont, {:ok, [{item["number"], item["title"], rs} | acc]}}
          other -> {:halt, other}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  # Each open pull request's head and the state of its checks ("number" =>
  # %{"sha", "state"}), and the events of heads that settled. A head whose
  # checks settled is not asked again until it changes. With no earlier state
  # (`known` nil: this repository's first read of checks) nothing is sent.
  defp checks(user_id, token, secret, repo, open, known) do
    Enum.reduce_while(open, {:ok, %{}, []}, fn pr, {:ok, acc, events} ->
      n = Integer.to_string(pr["number"])
      sha = get_in(pr, ["head", "sha"])
      was = known && known[n]

      cond do
        not is_binary(sha) ->
          {:cont, {:ok, acc, events}}

        was && was["sha"] == sha && was["state"] in ["passed", "failed", "none"] ->
          {:cont, {:ok, Map.put(acc, n, was), events}}

        true ->
          with {:ok, %{body: status}} <- ask(user_id, token, secret, "/repos/#{repo}/commits/#{sha}/status"),
               {:ok, %{body: runs}} <- ask(user_id, token, secret, "/repos/#{repo}/actions/runs?per_page=100&head_sha=#{sha}") do
            state = Events.ci_state(status, is_map(runs) && runs["workflow_runs"])
            settled? = state in ["passed", "failed"] and not (was != nil and was["sha"] == sha and was["state"] == state)
            new = if known != nil and settled?, do: [Events.ci_event(repo, pr, state)], else: []
            {:cont, {:ok, Map.put(acc, n, %{"sha" => sha, "state" => state}), events ++ new}}
          else
            other -> {:halt, other}
          end
      end
    end)
  end

  # --- what awaits the token's owner -------------------------------------------------

  @doc "Search for what is open and awaits the owner of each of `tokens`; ping what is new to each search."
  def poll_me(user_id, tokens) do
    Enum.reduce_while(@me_queries, {:ok, @me_every_s}, fn {key, query, what}, ok ->
      case search(user_id, tokens, query) do
        {:ok, items} ->
          source = "search:" <> key
          seen = (Cursor.get(user_id, source) || %{})["keys"]
          keys = Map.keys(items)

          if is_list(seen) do
            for k <- keys -- seen, item = items[k] do
              Router.github(user_id, ["gh:@me"], Events.text(Map.put(item, :action, what)))
            end
          end

          :ok = Cursor.put(user_id, source, %{"keys" => keys})
          {:cont, ok}

        other ->
          {:halt, other}
      end
    end)
  end

  # The union of a search over every token: "owner/repo#n" => event fields.
  defp search(user_id, tokens, query) do
    Enum.reduce_while(tokens, {:ok, %{}}, fn token, {:ok, acc} ->
      case ask(user_id, token, GitHub.secret(token), "/search/issues?per_page=100&sort=updated&q=" <> URI.encode_www_form(query)) do
        {:ok, %{body: %{"items" => items}}} when is_list(items) ->
          found =
            for i <- items, [_, repo] <- [Regex.run(~r{/repos/([^/]+/[^/]+)\z}, i["repository_url"] || "")], into: %{} do
              pr? = is_map(i["pull_request"])
              {"#{repo}##{i["number"]}",
               %{repo: repo, number: i["number"], pr?: pr?, title: i["title"], by: nil,
                 url: "https://github.com/#{repo}/#{if pr?, do: "pull", else: "issues"}/#{i["number"]}"}}
            end

          {:cont, {:ok, Map.merge(acc, found)}}

        {:ok, _} -> {:halt, {:error, "GitHub's search answered without items"}}
        other -> {:halt, other}
      end
    end)
  end

  # --- the tokens ---------------------------------------------------------------------

  @doc "Tell `@github` once of each of `tokens` within 7 days of its expiry."
  def check_tokens(user_id, tokens) do
    now = DateTime.utc_now()

    for t <- tokens, GitHub.expiring?(t, now), {at, _} = GitHub.expiry_of(t) do
      source = "token:#{t.id}"
      stamp = DateTime.to_iso8601(at)

      if (Cursor.get(user_id, source) || %{})["warned_for"] != stamp do
        Router.github(user_id, ["@github"],
          "GitHub token #{Events.quote_title(t.label) |> String.trim()} #{if DateTime.compare(at, now) == :gt, do: "expires", else: "expired"} #{Calendar.strftime(at, "%Y-%m-%d")}: make a new one and add it on the panel's GitHub page")
        :ok = Cursor.put(user_id, source, %{"warned_for" => stamp})
      end
    end

    :ok
  end

  # --- asking -----------------------------------------------------------------------

  # A GET, read for what the poller must do about it. A 401 marks the token
  # refused and tells @github, the first time.
  defp ask(user_id, token, secret, path) do
    case secret && Client.get(secret, path) do
      nil ->
        {:error, "token #{token.label} cannot be decrypted"}

      {:ok, %{status: 200} = r} ->
        {:ok, r}

      {:ok, %{status: 401}} ->
        refused(user_id, token)
        {:unauthorized, "GitHub refused token #{token.label} (401)"}

      {:ok, %{status: s, headers: h}} when s in [403, 429] ->
        case rate_wait(h) do
          nil -> {:error, "GitHub answered #{s} for #{path}"}
          wait -> {:rate_limited, wait}
        end

      {:ok, %{status: s}} ->
        {:error, "GitHub answered #{s} for #{path}"}

      {:error, why} ->
        {:error, why}
    end
  end

  defp refused(user_id, token) do
    {:ok, _} = GitHub.mark(token, "unauthorized", "GitHub refused the token (401): it is wrong, expired or revoked")

    if token.status != "unauthorized" do
      Router.github(user_id, ["@github"],
        "GitHub token #{Events.quote_title(token.label) |> String.trim()} was refused (401): it is wrong, expired or revoked; replace it on the panel's GitHub page")
    end
  end

  @doc "Seconds to wait from a refusal's headers: Retry-After, or the rate limit's reset; nil if neither says."
  def rate_wait(h) do
    cond do
      is_binary(h["retry-after"]) -> max(int(h["retry-after"]), 1)
      h["x-ratelimit-remaining"] == "0" and is_binary(h["x-ratelimit-reset"]) -> max(int(h["x-ratelimit-reset"]) - System.os_time(:second), 1)
      true -> nil
    end
  end

  defp int(s), do: with({n, _} <- Integer.parse(s), do: n, else: (_ -> 60))

  defp poll_interval(%{headers: %{"x-poll-interval" => v}}), do: int(v)
  defp poll_interval(_), do: 0

  # The response's own items, then up to #{@max_pages} pages more.
  defp pages(user_id, token, secret, first) do
    collect(user_id, token, secret, first, first.body, 1)
  end

  defp get_all(user_id, token, secret, path) do
    with {:ok, r} <- ask(user_id, token, secret, path), do: collect(user_id, token, secret, r, r.body, 1)
  end

  defp collect(user_id, token, secret, r, acc, n) do
    acc = if is_list(acc), do: acc, else: []

    case n < @max_pages && Client.next_page(r) do
      url when is_binary(url) ->
        with {:ok, next} <- ask(user_id, token, secret, url),
             do: collect(user_id, token, secret, next, acc ++ List.wrap(next.body), n + 1)

      _ ->
        {:ok, acc}
    end
  end

  # GitHub's clock, from its Date header ("Tue, 14 Oct 2026 09:00:00 GMT").
  defp server_time(%{headers: %{"date" => d}}) do
    with [_, day, mon, year, time] <- Regex.run(~r/\A\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}:\d{2}:\d{2}) GMT\z/, d),
         m when is_integer(m) <- Enum.find_index(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), &(&1 == mon)),
         {:ok, t, _} <- DateTime.from_iso8601("#{year}-#{String.pad_leading("#{m + 1}", 2, "0")}-#{day}T#{time}Z") do
      t
    else
      _ -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  defp server_time(_), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp parse(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, t, _} -> t
      _ -> nil
    end
  end
end
