defmodule ClaudiverseServer.AnthropicAuthEnrolmentUsageTest do
  @moduledoc """
  An account's usage is acted on the moment it is read, not at the next poll.

  🔴 MEASURED 2026-10-10 on a fresh install: an account enrolled at weekly 100%
  read `available` for its first minute, until the usage poll cooled it, so a
  seat could have been handed an account that cannot serve a request. The
  panel's Check usage stored its reading the same way, without the threshold.
  The same minute showed it "last leased" twice, though nothing leased it:
  the usage reads themselves stamped last_leased_at.
  """
  # Not async: SQLite has one writer (see the other anthropic_auth tests).
  use ClaudiverseServer.DataCase, async: false

  alias ClaudiverseServer.AnthropicAuths
  alias ClaudiverseServer.AnthropicAuths.AnthropicAuth

  @tokens %{"access_token" => "enrolled-access", "refresh_token" => "enrolled-refresh", "expires_in" => 3600}

  defp in_seconds(s), do: DateTime.utc_now() |> DateTime.add(s, :second) |> DateTime.truncate(:second)

  defp usage(weekly_pct, weekly_reset \\ in_seconds(2 * 86_400)) do
    %{"limits" => [
      %{"kind" => "session", "percent" => 0, "resets_at" => nil},
      %{"kind" => "weekly_all", "percent" => weekly_pct, "resets_at" => DateTime.to_iso8601(weekly_reset)}
    ]}
  end

  defp reload(a), do: Repo.get!(AnthropicAuth, a.id)

  test "an account enrolled at its limit is cooling before its first lease" do
    {:ok, personal} = AnthropicAuths.store_enrolment("personal", @tokens, nil, usage(100))

    assert personal.status == "cooling_down"
    assert personal.cooldown_reason =~ "weekly_all at 100%"
    refute AnthropicAuth.leasable?(personal)
    assert AnthropicAuths.lease() == {:error, :no_available_auth}
  end

  test "beside a capped enrolment, the lease goes to the healthy account" do
    {:ok, _} = AnthropicAuths.store_enrolment("personal", @tokens, nil, usage(100))
    {:ok, work} = AnthropicAuths.store_enrolment("work", @tokens, nil, usage(83))

    assert work.status == "available"
    assert {:ok, %{label: "work"}} = AnthropicAuths.lease()
  end

  test "an enrolment under the threshold is available, with its reading stored" do
    {:ok, a} = AnthropicAuths.store_enrolment("work", @tokens, nil, usage(83))

    assert a.status == "available"
    assert a.usage_snapshot == usage(83) |> Jason.encode!() |> Jason.decode!()
    assert a.usage_checked_at
  end

  test "a failed usage read at enrolment stores no snapshot and does not cool the account" do
    {:ok, a} = AnthropicAuths.store_enrolment("work", @tokens, nil, nil)

    assert a.status == "available"
    assert is_nil(a.usage_snapshot)
  end

  test "re-enrolment keeps the longer of the existing cooldown and the measured one" do
    {:ok, a} = AnthropicAuths.store_enrolment("personal", @tokens, nil, usage(100, in_seconds(3600)))
    longer = in_seconds(5 * 86_400)
    a |> Ecto.Changeset.change(cooldown_until: longer, cooldown_reason: "rate limited (429)") |> Repo.update!()

    {:ok, again} = AnthropicAuths.store_enrolment("personal", @tokens, nil, usage(100, in_seconds(3600)))

    assert again.status == "cooling_down"
    assert DateTime.compare(again.cooldown_until, longer) == :eq
    assert again.cooldown_reason == "rate limited (429)"
  end

  test "a usage reading at the limit (Check usage, the poll) cools the account at once" do
    {:ok, a} = AnthropicAuths.store_enrolment("personal", @tokens, nil, usage(40))
    assert a.status == "available"

    {:ok, read} = AnthropicAuths.record_usage(a, usage(100))

    assert read.status == "cooling_down"
    assert reload(a).status == "cooling_down"
  end

  test "reading an account's token for a usage check is not a lease; lease/1 is" do
    {:ok, a} = AnthropicAuths.store_enrolment("work", @tokens, nil, usage(10))

    {:ok, _} = AnthropicAuths.valid_token(a)
    assert is_nil(reload(a).last_leased_at)

    {:ok, _} = AnthropicAuths.lease()
    assert reload(a).last_leased_at
  end
end
