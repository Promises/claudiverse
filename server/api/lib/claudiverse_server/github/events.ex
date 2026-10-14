defmodule ClaudiverseServer.GitHub.Events do
  @moduledoc """
  What happened in a repository between two moments, read from GitHub's own
  timestamps, and how it is told. Pure: GitHub.Poller does the asking.

  An event happened in the window when its time is after `from` and at or
  before `to` (`to` is GitHub's own clock, as its Date header gave it, less a
  margin). The next window starts where this one ended, so nothing fires twice
  and nothing in between is missed.

  🔴 GITHUB CONTENT IS UNTRUSTED. Anyone who can open an issue writes its
  title, and a seat reads its pings. A ping therefore carries metadata only:
  what happened, where, the title cut short and stripped of anything but
  printable text on one line, who (a GitHub login, checked), and a link built
  here. Never a comment or a body. A seat that needs more reads it itself.
  """

  @title_max 80
  @login ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})(?:\[bot\])?\z/

  @doc """
  The events in an issues listing (`GET /repos/:repo/issues?state=all&since=`;
  pull requests are in it too): opened, closed and merged, by their times.
  """
  def from_issues(repo, items, from, to) do
    Enum.flat_map(items, fn item ->
      pr? = is_map(item["pull_request"])
      base = base(repo, item, pr?)

      opened = if within?(item["created_at"], from, to), do: [Map.merge(base, %{action: "opened", by: login(item["user"])})], else: []

      closed =
        cond do
          pr? and within?(item["pull_request"]["merged_at"], from, to) -> [Map.merge(base, %{action: "merged", by: login(item["closed_by"])})]
          within?(item["closed_at"], from, to) -> [Map.merge(base, %{action: "closed", by: login(item["closed_by"])})]
          true -> []
        end

      opened ++ closed
    end)
  end

  @doc """
  The comments in a comments listing (`GET /repos/:repo/issues/comments?since=`,
  on issues and pull requests) made in the window. `titles` maps a number to
  its item's title and kind, from the issues listing of the same window.
  """
  def from_comments(repo, comments, titles, from, to) do
    for c <- comments, within?(c["created_at"], from, to), number = number_from(c["issue_url"]), number != nil do
      {title, pr?} = Map.get(titles, number, {nil, nil})

      %{repo: repo, number: number, pr?: pr?, title: title, action: "commented", by: login(c["user"]),
        url: "https://github.com/#{repo}/#{if pr?, do: "pull", else: "issues"}/#{number}" <> comment_anchor(c["id"])}
    end
  end

  @doc "A pull request's reviews (`GET /repos/:repo/pulls/:n/reviews`) submitted in the window."
  def from_reviews(repo, number, title, reviews, from, to) do
    for r <- reviews, within?(r["submitted_at"], from, to), action = review_action(r["state"]), action != nil do
      %{repo: repo, number: number, pr?: true, title: title, action: action, by: login(r["user"]),
        url: "https://github.com/#{repo}/pull/#{number}" <> review_anchor(r["id"])}
    end
  end

  defp review_action("APPROVED"), do: "approved"
  defp review_action("CHANGES_REQUESTED"), do: "changes requested"
  defp review_action("COMMENTED"), do: "reviewed"
  defp review_action(_), do: nil

  @doc """
  A head commit's checks as one state, from its combined commit status
  (`GET /repos/:repo/commits/:sha/status`) and its Actions runs
  (`GET /repos/:repo/actions/runs?head_sha=`): "failed" if any failed,
  "pending" while any runs, "passed" when all that ran passed, "none" if it
  has no checks.
  """
  def ci_state(status, runs) do
    statuses = if is_map(status), do: status["statuses"] || [], else: []
    runs = runs || []
    states = Enum.map(statuses, & &1["state"])
    pending_run? = Enum.any?(runs, &(&1["status"] != "completed"))
    conclusions = for r <- runs, r["status"] == "completed", do: r["conclusion"]

    cond do
      statuses == [] and runs == [] -> "none"
      Enum.any?(states, &(&1 in ["failure", "error"])) or Enum.any?(conclusions, &(&1 in ["failure", "timed_out", "startup_failure", "action_required"])) -> "failed"
      pending_run? or "pending" in states -> "pending"
      true -> "passed"
    end
  end

  @doc "A pull request's checks settling on its head: passed or failed."
  def ci_event(repo, %{"number" => n, "title" => title}, state) when state in ["passed", "failed"] do
    %{repo: repo, number: n, pr?: true, title: title, action: "checks #{state}", by: nil, url: "https://github.com/#{repo}/pull/#{n}/checks"}
  end

  @doc "The watch titles an event pings, most specific first."
  def titles(%{repo: repo, number: n, pr?: pr?}) do
    ["gh:#{repo}##{n}", "gh:#{repo}:#{if pr?, do: "prs", else: "issues"}", "gh:#{repo}"]
  end

  @doc ~S|One line: `GH PR merged: owner/repo#123 "title…" by someone — https://github.com/…`.|
  def text(%{repo: repo, number: n, pr?: pr?, title: title, action: action, by: by, url: url}) do
    kind = if pr?, do: "PR", else: if(pr? == false, do: "issue", else: "PR/issue")
    "GH #{kind} #{action}: #{repo}##{n}#{quote_title(title)}#{if by, do: " by #{by}", else: ""} — #{url}"
  end

  @doc "A title as a ping may carry it: one line, printable, at most #{@title_max} characters, quoted; or nothing."
  def quote_title(nil), do: ""

  def quote_title(title) when is_binary(title) do
    clean =
      title
      |> String.replace(~r/[\p{C}\p{Zl}\p{Zp}]+/u, " ")
      |> String.replace(~r/["`]/, "'")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    cond do
      clean == "" -> ""
      String.length(clean) > @title_max -> " \"" <> String.slice(clean, 0, @title_max - 1) <> "…\""
      true -> " \"" <> clean <> "\""
    end
  end

  def quote_title(_), do: ""

  @doc "Whether ISO 8601 `at` is after `from` and at or before `to` (DateTimes)."
  def within?(at, from, to) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, t, _} -> DateTime.compare(t, from) == :gt and DateTime.compare(t, to) != :gt
      _ -> false
    end
  end

  def within?(_, _, _), do: false

  defp base(repo, item, pr?) do
    n = item["number"]
    %{repo: repo, number: n, pr?: pr?, title: item["title"], url: "https://github.com/#{repo}/#{if pr?, do: "pull", else: "issues"}/#{n}"}
  end

  # A login GitHub would issue, or nil: it goes into a ping.
  defp login(%{"login" => l}) when is_binary(l), do: if(Regex.match?(@login, l), do: l, else: nil)
  defp login(_), do: nil

  defp number_from(url) when is_binary(url) do
    case Regex.run(~r{/issues/(\d+)\z}, url) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  defp number_from(_), do: nil

  defp comment_anchor(id) when is_integer(id), do: "#issuecomment-#{id}"
  defp comment_anchor(_), do: ""
  defp review_anchor(id) when is_integer(id), do: "#pullrequestreview-#{id}"
  defp review_anchor(_), do: ""
end
