defmodule ClaudiverseServer.UsageHistoryTest do
  @moduledoc """
  The pool's usage history: days from readings (a day across a weekly reset,
  a day with no readings), thinning that leaves every day's sum unchanged,
  the API and the daily log line.
  """
  use ClaudiverseServerWeb.ConnCase, async: false

  import ClaudiverseServer.Fixtures
  import Ecto.Query

  alias ClaudiverseServer.{Accounts, Repo}
  alias ClaudiverseServer.AnthropicAuths.{AnthropicAuth, UsageHistory, UsageSample}

  @tz "Europe/Oslo"

  defp s(at, pct, resets_at, id \\ nil),
    do: %UsageSample{id: id, at: at, weekly_pct: pct, weekly_resets_at: resets_at}

  test "a day across a weekly reset sums what was used, before and after it" do
    old = ~U[2026-10-12 05:00:00Z]
    new = ~U[2026-10-19 05:00:00Z]
    # Oslo 2026-10-12 is 2026-10-11T22:00Z..2026-10-12T22:00Z.
    # Readings ~2 h apart (the poll is every 5 min; 3 h apart counts on no day).
    samples = [
      s(~U[2026-10-11 22:30:00Z], 92.0, old),
      s(~U[2026-10-12 01:00:00Z], 93.0, old),
      s(~U[2026-10-12 03:00:00Z], 94.0, old),
      s(~U[2026-10-12 04:55:00Z], 95.0, old),
      s(~U[2026-10-12 05:05:00Z], 1.0, new),
      s(~U[2026-10-12 07:00:00Z], 4.0, new),
      s(~U[2026-10-12 09:00:00Z], 8.0, new),
      s(~U[2026-10-12 11:00:00Z], 10.0, new),
      s(~U[2026-10-12 13:00:00Z], 12.0, new),
      s(~U[2026-10-12 15:00:00Z], 13.0, new),
      s(~U[2026-10-12 17:00:00Z], 13.0, new),
      s(~U[2026-10-12 19:00:00Z], 14.0, new),
      s(~U[2026-10-12 21:55:00Z], 15.0, new)
    ]

    prior = s(~U[2026-10-11 21:55:00Z], 92.0, old)
    %{days: [day], reset_times: resets} = UsageHistory.days(samples, prior, ~D[2026-10-12], ~D[2026-10-12], @tz, ~D[2026-10-13])

    # 92 → 95 is 3, the reset adds the new period's 1, then 1 → 15 is 14.
    assert %{weekly_used_pct: 18.0, weekly_pct_start_of_day: 92.0, weekly_pct_end_of_day: 15.0, reset_in_day: true, samples: 13} = day
    assert resets == [old]

    # The control: end − start says the day used less than nothing.
    assert day.weekly_pct_end_of_day - day.weekly_pct_start_of_day == -77.0
    refute day.weekly_pct_end_of_day - day.weekly_pct_start_of_day == day.weekly_used_pct
  end

  test "a day with no readings is null, not 0; a day with readings and no use is 0.0" do
    r = ~U[2026-10-19 05:00:00Z]
    samples = [s(~U[2026-10-10 10:00:00Z], 20.0, r), s(~U[2026-10-10 11:00:00Z], 20.0, r), s(~U[2026-10-12 10:00:00Z], 30.0, r)]
    %{days: [d10, d11, d12]} = UsageHistory.days(samples, nil, ~D[2026-10-10], ~D[2026-10-12], @tz, ~D[2026-10-12])

    assert %{weekly_used_pct: +0.0, samples: 2} = d10
    assert %{weekly_used_pct: nil, weekly_pct_start_of_day: nil, weekly_pct_end_of_day: nil, reset_in_day: nil, samples: 0} = d11
    # Two days apart: what was used in between is not known to be this day's.
    assert %{weekly_used_pct: +0.0, weekly_pct_start_of_day: 20.0, weekly_pct_end_of_day: 30.0, partial: true} = d12
  end

  # 45 days of readings every 5 minutes: steady use, a weekly reset every 7
  # days, a few falls (a reading that comes back lower), a short and a long
  # outage, and a reading with no weekly limit.
  defp series do
    start = ~U[2026-08-25 00:02:00Z]
    :rand.seed(:exsss, {1, 2, 3})

    {list, _} =
      Enum.map_reduce(0..(45 * 288), {0.0, ~U[2026-08-27 07:00:00Z]}, fn i, {pct, reset} ->
        at = DateTime.add(start, i * 300)
        {pct, reset} = if DateTime.compare(at, reset) != :lt, do: {0.0, DateTime.add(reset, 7 * 86_400)}, else: {pct, reset}
        pct = min(pct + :rand.uniform() * 0.08, 100.0)
        shown = if rem(i, 997) == 0, do: max(pct - 2.0, 0.0), else: pct
        weekly = if rem(i, 1501) == 0, do: nil, else: Float.round(shown, 2)
        {%UsageSample{id: i, at: at, weekly_pct: weekly, weekly_resets_at: reset}, {pct, reset}}
      end)

    outage = fn s -> not (s.id in 3000..3011 or s.id in 6000..6600) end
    Enum.filter(list, outage)
  end

  defp sums(samples, from, to) do
    %{days: days, reset_times: resets} = UsageHistory.days(samples, nil, from, to, @tz, Date.add(to, 1))
    {Enum.map(days, &{&1.date, &1.weekly_used_pct}), resets}
  end

  test "thinning leaves every day's sum and every reset as they were" do
    all = series()
    now = DateTime.add(List.last(all).at, 3600)
    keep = UsageHistory.keep_ids(all, now)
    kept = Enum.filter(all, &MapSet.member?(keep, &1.id))

    assert length(kept) < length(all) / 2, "thinning kept #{length(kept)} of #{length(all)}"
    assert sums(kept, ~D[2026-08-25], ~D[2026-10-08]) == sums(all, ~D[2026-08-25], ~D[2026-10-08])

    # The control: keeping one reading per hour, the last, moves the sums.
    naive = all |> Enum.group_by(&div(DateTime.to_unix(&1.at), 3600)) |> Enum.map(fn {_, g} -> List.last(g) end) |> Enum.sort_by(& &1.id)
    refute sums(naive, ~D[2026-08-25], ~D[2026-10-08]) == sums(all, ~D[2026-08-25], ~D[2026-10-08])
  end

  test "thin/1 applies it to the table, and deletes past retention" do
    auth = Repo.insert!(%AnthropicAuth{label: "Personal", priority: 10, status: "available"})
    now = ~U[2026-10-12 12:00:00Z]
    usage = fn pct -> %{"limits" => [%{"kind" => "weekly_all", "percent" => pct, "resets_at" => "2026-10-19T05:00:00Z"}]} end
    for i <- 0..35, do: UsageHistory.record(auth.id, usage.(10 + i * 0.1), DateTime.add(~U[2026-10-01 00:01:00Z], i * 300))
    UsageHistory.record(auth.id, usage.(1.0), ~U[2025-01-01 00:00:00Z])

    deleted = UsageHistory.thin(now)
    left = Repo.all(UsageSample) |> length()
    assert deleted > 0 and left < 37
    cutoff = ~U[2026-01-01 00:00:00Z]
    refute Repo.exists?(from(x in UsageSample, where: x.at < ^cutoff))
  end

  test "GET usage_history: days per account, raw samples on request, readable by a seat's token" do
    {user, api} = user_with_token()
    app = Accounts.create_user_api_token(user, "app")
    auth = Repo.insert!(%AnthropicAuth{label: "Personal", priority: 10, status: "available"})
    now = DateTime.utc_now()

    for {mins, pct} <- [{-30, 40}, {-20, 42}, {-10, 45}] do
      UsageHistory.record(auth.id, %{"limits" => [%{"kind" => "weekly_all", "percent" => pct, "resets_at" => "2030-01-01T00:00:00Z"},
                                                   %{"kind" => "session", "percent" => 3}]}, DateTime.add(now, mins * 60))
    end

    body = build_conn() |> put_req_header("authorization", "Bearer " <> app) |> get("/api/anthropic_auths/usage_history?days=3&raw=1") |> json_response(200)
    assert %{"tz" => "Europe/Oslo", "accounts" => [acct]} = body
    assert %{"label" => "Personal", "weekly_resets_at" => "2030-01-01T00:00:00Z", "reset_times" => [], "days" => days, "samples" => raw} = acct
    assert length(days) == 3
    assert %{"weekly_used_pct" => 5.0, "partial" => true} = List.last(days)
    assert [%{"weekly_pct" => 40.0, "session_pct" => 3.0} | _] = raw

    seat = build_conn() |> put_req_header("authorization", "Bearer " <> api) |> get("/api/anthropic_auths/usage_history?tz=UTC") |> json_response(200)
    assert %{"tz" => "UTC", "accounts" => [%{"days" => d}]} = seat
    assert length(d) == 28
    refute Map.has_key?(hd(seat["accounts"]), "samples")

    assert build_conn() |> put_req_header("authorization", "Bearer " <> app) |> get("/api/anthropic_auths/usage_history?tz=Mars/Base") |> json_response(400)
    assert build_conn() |> put_req_header("authorization", "Bearer " <> app) |> get("/api/anthropic_auths/usage_history?days=0") |> json_response(400)
  end

  test "the daily line runs a minute after local midnight, across a daylight-saving change too" do
    assert UsageHistory.next_run(~U[2026-10-12 10:00:00Z], @tz) == ~U[2026-10-12 22:01:00Z]
    # 2026-10-25: Oslo goes from +02:00 to +01:00, so midnight on the 26th is 23:00Z.
    assert UsageHistory.next_run(~U[2026-10-25 10:00:00Z], @tz) == ~U[2026-10-25 23:01:00Z]
    assert UsageHistory.next_run(~U[2026-10-12 21:59:00Z], @tz) == ~U[2026-10-12 22:01:00Z]
  end

  test "the daily log line names each account's day" do
    personal = Repo.insert!(%AnthropicAuth{label: "Personal", priority: 10, status: "available"})
    Repo.insert!(%AnthropicAuth{label: "Work", priority: 20, status: "available"})
    r = "2026-10-19T05:00:00Z"
    readings = for h <- 0..11, do: {DateTime.add(~U[2026-10-11 21:55:00Z], h * 7200), 10 + h * 18 / 11}
    for {at, pct} <- readings ++ [{~U[2026-10-12 21:50:00Z], 28}] do
      UsageHistory.record(personal.id, %{"limits" => [%{"kind" => "weekly_all", "percent" => pct, "resets_at" => r}]}, at)
    end

    assert UsageHistory.daily_line(~D[2026-10-12], @tz, ~U[2026-10-12 22:05:00Z]) ==
             "[usage] 2026-10-12 (Europe/Oslo) weekly use: Personal +18% (10% → 28%), Work no readings"
  end
end
