defmodule ClaudiverseServer.UsagePollerLiftTest do
  @moduledoc """
  A cooldown the usage poll set is lifted by a later poll that reads every
  limit back under the threshold — and only that kind, and only on evidence.

  🔴 MEASURED 2026-10-02 ~22:04Z: the operator applied a weekly reset to
  Personal; the poll read weekly_all 0%, yet Personal stayed cooling_down until
  2026-10-04T23:59Z (the poll never lifted what it set), every seat on Work at
  94%. Lifted by hand at 22:05Z.

  The counter-risk is the 2026-09-20 incident (see
  anthropic_auth_refresh_keeps_cooldown_test.exs): a cooldown erased WITHOUT
  evidence moved the fleet into an exhausted account. Hence the guards below.
  """
  # Not async: SQLite has one writer, and parallel sandbox transactions on
  # anthropic_auths timed out with "Database busy" (measured 2026-10-04).
  use ClaudiverseServer.DataCase, async: false

  alias ClaudiverseServer.AnthropicAuths.{AnthropicAuth, UsagePoller}

  defp in_seconds(s), do: DateTime.utc_now() |> DateTime.add(s, :second) |> DateTime.truncate(:second)

  defp usage(weekly_pct, session_pct \\ 0) do
    %{"limits" => [
      %{"kind" => "session", "percent" => session_pct, "resets_at" => "2026-10-03T02:30:00Z"},
      %{"kind" => "weekly_all", "percent" => weekly_pct, "resets_at" => "2026-10-05T00:00:00Z"}
    ]}
  end

  defp cooling(reason, snapshot, label \\ "Personal") do
    Repo.insert!(%AnthropicAuth{
      label: label, priority: 10, status: "cooling_down",
      cooldown_until: in_seconds(2 * 86_400), cooldown_reason: reason, usage_snapshot: snapshot
    })
  end

  defp reload(a), do: Repo.get!(AnthropicAuth, a.id)

  test "a poll-set cooldown is lifted when a later poll reads every limit under the threshold" do
    personal = cooling("weekly_all at 99% >= 95% (usage poll)", usage(0))
    work = Repo.insert!(%AnthropicAuth{label: "Work", priority: 100, status: "available"})

    UsagePoller.apply_threshold(personal)
    lifted = reload(personal)

    assert lifted.status == "available" and is_nil(lifted.cooldown_until)
    assert lifted.cooldown_reason =~ "lifted"
    assert AnthropicAuth.leasable?(lifted)

    # …and the switch-back fires: Personal is now the better account.
    assert UsagePoller.maybe_announce_upgrade(%{best_id: work.id}).best_id == personal.id
  end

  test "a 429-derived cooldown is not lifted by low usage (limits the poll can't see)" do
    a = cooling("rate limited (429)", usage(3))
    UsagePoller.apply_threshold(a)
    assert reload(a).status == "cooling_down"
  end

  test "a poll cooldown later confirmed by a 429 is not lifted either" do
    a = cooling("weekly_all at 100% >= 95% (usage poll) (429 reported; kept the longer existing cooldown)", usage(0))
    UsagePoller.apply_threshold(a)
    assert reload(a).status == "cooling_down"
  end

  test "a response with no readable limit lifts nothing" do
    for {snapshot, i} <- Enum.with_index([%{}, %{"limits" => []}, %{"limits" => [%{"kind" => "weekly_all", "percent" => nil}]}]) do
      a = cooling("weekly_all at 99% >= 95% (usage poll)", snapshot, "Personal-#{i}")
      UsagePoller.apply_threshold(a)
      assert reload(a).status == "cooling_down", "lifted on #{inspect(snapshot)}"
    end
  end

  test "still over the threshold: stays cooling" do
    a = cooling("weekly_all at 99% >= 95% (usage poll)", usage(97))
    UsagePoller.apply_threshold(a)
    assert reload(a).status == "cooling_down"
  end
end
