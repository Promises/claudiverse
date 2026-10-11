defmodule ClaudiverseServer.PoolEventsTest do
  @moduledoc """
  The pool's usage events (AnthropicAuths.PoolEvents): an account's limit
  resetting, reaching 100%, and its weekly usage crossing a step. Each fires
  once per crossing, never on an unchanged reading, and never again after a
  restart (the stored snapshot is the last reading either way).
  """
  # Not async: SQLite has one writer (see the other anthropic_auth tests).
  use ClaudiverseServer.DataCase, async: false

  alias ClaudiverseServer.AnthropicAuths
  alias ClaudiverseServer.AnthropicAuths.{AnthropicAuth, PoolEvents}

  @now ~U[2026-10-11 10:00:00Z]
  @week_end "2026-10-11T09:59:00Z"
  @next_week_end "2026-10-18T09:59:00Z"

  defp usage(weekly, weekly_reset \\ @next_week_end, session \\ 0, session_reset \\ "2026-10-11T12:00:00Z") do
    %{"limits" => [
      %{"kind" => "session", "group" => "session", "percent" => session, "resets_at" => session_reset},
      %{"kind" => "weekly_all", "group" => "weekly", "percent" => weekly, "resets_at" => weekly_reset},
      %{"kind" => "weekly_scoped", "group" => "weekly", "percent" => 0, "resets_at" => nil}
    ]}
  end

  defp auth(attrs \\ %{}), do: struct(%AnthropicAuth{id: 1, label: "work"}, attrs)
  defp detect(old, new, a \\ auth()), do: PoolEvents.detect(old, new, a, @now)
  defp changes(events), do: Enum.map(events, &{&1["change"], &1["limit"], &1["every"], &1["crossed"]})

  test "an unchanged reading fires nothing (and so does the first reading after a restart)" do
    assert detect(usage(91), usage(91)) == []
    assert detect(usage(100), usage(100)) == []
  end

  test "no stored reading (a new account) fires nothing" do
    assert detect(nil, usage(100)) == []
  end

  # --- reset ----------------------------------------------------------------

  test "reset: the weekly limit's resets_at moved to the next period" do
    assert [%{"change" => "reset", "limit" => "weekly", "text" => text}] =
             detect(usage(94, @week_end), usage(0, @next_week_end))

    assert text == "POOL reset: work weekly 94% → 0% (next reset Sun 2026-10-18 09:59 UTC)"
  end

  test "reset: an unused limit reports no reset time once its old one has passed" do
    assert [%{"change" => "reset", "text" => text}] = detect(usage(94, @week_end), usage(0, nil))
    assert text == "POOL reset: work weekly 94% → 0% (no next reset reported yet)"
  end

  test "no reset: the same period re-reported, a percent that dropped, or a missing time before the old one" do
    assert detect(usage(92, "2026-10-18T09:59:00.126Z"), usage(93, "2026-10-18T09:59:00.481Z")) == []
    assert detect(usage(94), usage(40)) == [], "a drop alone (a manual reset) is not a reset"
    assert detect(usage(94, "2026-10-12T00:00:00Z"), usage(94, nil)) == [], "the old period has not ended"
  end

  test "a session reset is its own event, with limit session" do
    events = detect(usage(50, @next_week_end, 80, "2026-10-11T09:00:00Z"), usage(50, @next_week_end, 0, "2026-10-11T14:00:00Z"))
    assert [%{"change" => "reset", "limit" => "session", "text" => text}] = events
    assert text == "POOL reset: work session 80% → 0% (next reset Sun 2026-10-11 14:00 UTC)"
  end

  # --- capped ---------------------------------------------------------------

  test "capped: weekly usage reached 100%, naming the cooldown (and the 100% steps with it)" do
    a = auth(%{label: "personal", cooldown_until: ~U[2026-10-12 00:00:00Z]})
    events = detect(usage(98), usage(100), a)
    assert changes(events) == [{"capped", "weekly", nil, nil}, {"step", "weekly", 5, 100}, {"step", "weekly", 10, 100}]
    assert hd(events)["text"] == "POOL capped: personal weekly 100%, cooling until Mon 2026-10-12 00:00 UTC"
  end

  test "capped fires once: staying at 100% is not a new event" do
    assert detect(usage(100), usage(100)) == []
    assert detect(usage(100), usage(101)) == []
  end

  test "a session cap is its own event, with limit session" do
    assert changes(detect(usage(50, @next_week_end, 97), usage(50, @next_week_end, 100))) == [{"capped", "session", nil, nil}]
  end

  # --- steps ----------------------------------------------------------------

  test "step: crossing 90 is one 10-step and one 5-step event" do
    events = detect(usage(84), usage(91))
    assert changes(events) == [{"step", "weekly", 5, 90}, {"step", "weekly", 10, 90}]
    assert Enum.at(events, 1)["text"] == "POOL step: work weekly crossed 90% (now 91%)"
  end

  test "step: a crossing of a 5 that is not a 10 is a 5-step only" do
    assert changes(detect(usage(81), usage(86))) == [{"step", "weekly", 5, 85}]
  end

  test "step: a poll that skipped several multiples fires once, for the highest" do
    assert changes(detect(usage(70), usage(92))) == [{"step", "weekly", 5, 90}, {"step", "weekly", 10, 90}]
  end

  test "step: no step within the same multiple, and none for session usage" do
    assert detect(usage(91), usage(94)) == []
    assert detect(usage(50, @next_week_end, 10), usage(50, @next_week_end, 60)) == []
  end

  test "a reset starts the steps again from 0" do
    events = detect(usage(94, @week_end), usage(12, @next_week_end))
    assert changes(events) == [{"reset", "weekly", nil, nil}, {"step", "weekly", 5, 10}, {"step", "weekly", 10, 10}]
  end

  # --- through record_usage --------------------------------------------------

  test "record_usage broadcasts each event on the pool topic, once" do
    Phoenix.PubSub.subscribe(ClaudiverseServer.PubSub, AnthropicAuths.pool_topic())
    a = Repo.insert!(%AnthropicAuth{label: "work", priority: 100, status: "available", usage_snapshot: usage(84)})

    {:ok, _} = AnthropicAuths.record_usage(a, usage(91))
    assert_receive {"pool", %{"change" => "step", "every" => 5, "crossed" => 90, "auth_id" => id}}
    assert_receive {"pool", %{"change" => "step", "every" => 10, "text" => "POOL step: work weekly crossed 90% (now 91%)"}}
    assert id == a.id

    # The same reading again, as the first poll after a restart would read it.
    {:ok, _} = AnthropicAuths.record_usage(Repo.get!(AnthropicAuth, a.id), usage(91))
    refute_receive {"pool", %{"change" => _, "text" => _}}, 200
  end
end
