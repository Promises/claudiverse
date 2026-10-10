defmodule ClaudiverseServer.AnthropicAuthCooldownTest do
  @moduledoc """
  A 429 report may EXTEND an account's cooldown. It may never SHORTEN one.

  🔴 MEASURED 2026-09-18. The usage poll had Personal at weekly_all 100%,
  cooling until its weekly reset two days out. A seat's 429 report arrived with
  no usable resets_at, took the 15-minute default, and replaced the two-day
  cooldown with it. Fifteen minutes later Personal was leasable again, lorem-w3
  was handed it on relaunch, and 429'd on its first request — into an account
  the server had already measured as empty for the week.

  The poll heals it within five minutes, but inside that window the pool hands
  out dead accounts, and every further report re-opens the window.
  """
  # Not async: SQLite has one writer, and parallel sandbox transactions on
  # anthropic_auths timed out with "Database busy" (measured 2026-10-04).
  use ClaudiverseServer.DataCase, async: false

  alias ClaudiverseServer.AnthropicAuths
  alias ClaudiverseServer.AnthropicAuths.AnthropicAuth

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp in_seconds(s), do: DateTime.add(now(), s, :second)

  defp auth!(attrs) do
    Repo.insert!(struct(%AnthropicAuth{label: "Personal", priority: 10, status: "available"}, attrs))
  end

  # The function ends by leasing the NEXT account, which needs a valid token and
  # is not what these tests are about. The cooldown write happens first; read it.
  defp report!(auth, resets_at) do
    _ = AnthropicAuths.report_rate_limited(auth, resets_at, "rate limited (429)")
    Repo.get!(AnthropicAuth, auth.id)
  end

  defp assert_same_instant(a, b),
    do: assert(DateTime.compare(a, b) == :eq, "expected #{b}, got #{a}")

  test "a report with a shorter horizon does not shorten a poll-derived cooldown" do
    two_days = in_seconds(2 * 86_400)
    a = auth!(%{status: "cooling_down", cooldown_until: two_days,
                cooldown_reason: "weekly_all at 100% >= 95% (usage poll)"})

    after_report = report!(a, in_seconds(6 * 3600))

    assert_same_instant(after_report.cooldown_until, two_days)
    assert after_report.cooldown_reason =~ "weekly_all at 100%",
           "the measurement must survive as the reason; a symptom must not replace it"
    assert after_report.cooldown_reason =~ "429 reported"
  end

  test "the exact failure: a report with NO resets_at falls to the 15-minute default and must not win" do
    two_days = in_seconds(2 * 86_400)
    a = auth!(%{status: "cooling_down", cooldown_until: two_days, cooldown_reason: "weekly_all at 100% >= 95% (usage poll)"})

    after_report = report!(a, nil)

    assert_same_instant(after_report.cooldown_until, two_days)
  end

  test "with no existing cooldown, a report without resets_at still applies the default" do
    a = auth!(%{})
    after_report = report!(a, nil)

    diff = DateTime.diff(after_report.cooldown_until, now(), :second)
    assert diff in 840..960, "expected ~15 minutes, got #{diff}s"
    assert after_report.status == "cooling_down"
  end

  test "an EXPIRED cooldown pins nothing — the report sets the new one" do
    a = auth!(%{status: "cooling_down", cooldown_until: in_seconds(-600), cooldown_reason: "old"})
    two_hours = in_seconds(2 * 3600)

    after_report = report!(a, two_hours)

    assert_same_instant(after_report.cooldown_until, two_hours)
    assert after_report.cooldown_reason == "rate limited (429)"
  end

  test "a report with a LONGER horizon extends the cooldown" do
    a = auth!(%{status: "cooling_down", cooldown_until: in_seconds(3600), cooldown_reason: "short"})
    six_hours = in_seconds(6 * 3600)

    after_report = report!(a, six_hours)

    assert_same_instant(after_report.cooldown_until, six_hours)
  end

  test "the SUSPECT cap limits how far a report pushes OUT, never how far it pulls IN" do
    # Fresh snapshot, well under threshold → the report is suspect and would be
    # capped at 120s. But an existing 3h cooldown must still stand.
    three_hours = in_seconds(3 * 3600)
    a = auth!(%{
      status: "cooling_down",
      cooldown_until: three_hours,
      cooldown_reason: "set by an operator",
      usage_snapshot: %{"limits" => [%{"kind" => "session", "percent" => 5}, %{"kind" => "weekly_all", "percent" => 12}]},
      usage_checked_at: now()
    })

    after_report = report!(a, in_seconds(6 * 3600))

    assert_same_instant(after_report.cooldown_until, three_hours)
  end
end
