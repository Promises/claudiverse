defmodule ClaudiverseServer.AnthropicAuths.UsageHistory do
  @moduledoc """
  The account pool's usage over time: every usage reading of every account is
  kept as a sample (`record/3`, from AnthropicAuths.record_usage/2), and
  `report/4` turns them into days: how many percentage points of its weekly
  limit each account used each local day.

  ## A day's use

  The readings of one account, in order. Each step between two readings adds
  its rise, never a fall. Across a weekly reset the step adds the new
  period's reading (all of it was used since the reset), so a day that spans
  a reset sums correctly and nothing is ever subtracted: end − start would be
  negative there. A reset is the `resets_at` moving to a later period (more
  than an hour later), or the old one passing with none reported, as
  PoolEvents reads it. A step counts on the day of its later reading. A step
  over more than 3 hours counts on no day: what was used during an outage
  is not known to be that day's. A day with no readings has no numbers (null),
  never 0.

  ## Thinning (`thin/1`, daily)

  Every reading is kept for 48 hours; after that, one per 15-minute UTC bucket
  (the last); after 30 days, one per hour. On top of those, a sample is kept
  when dropping it could change a day's sum: the last before a reset and the
  first after, a peak or a trough, one beside a gap of 30 minutes or more, and
  one without a weekly reading (and its neighbours). What remains between two
  kept samples is then a rise within one period, in one bucket, and the step
  between the kept ones is the same sum. Local midnight must fall on a bucket
  boundary for that: a zone a whole number of hours from UTC (Europe/Oslo is).
  Samples older than 400 days are deleted.
  """
  import Ecto.Query

  require Logger

  alias ClaudiverseServer.Repo
  alias ClaudiverseServer.AnthropicAuths.{AnthropicAuth, UsageSample}

  @db Tz.TimeZoneDatabase
  @new_period_s 3600
  @max_step_s 3 * 3600
  @gap_s 30 * 60
  @raw_s 48 * 3600
  @quarter_until_s 30 * 86_400
  @retain_s 400 * 86_400

  # --- recording -----------------------------------------------------------

  @doc "Keep one usage reading (`usage`, as AnthropicAuths stores it) of account `auth_id`."
  def record(auth_id, usage, at \\ DateTime.utc_now()) do
    weekly = reading(usage, "weekly_all")
    session = reading(usage, "session")

    Repo.insert(%UsageSample{
      anthropic_auth_id: auth_id,
      at: DateTime.truncate(at, :second),
      weekly_pct: weekly.percent,
      weekly_resets_at: weekly.resets_at,
      session_pct: session.percent,
      session_resets_at: session.resets_at
    })
  end

  defp reading(usage, kind) do
    l = Enum.find((is_map(usage) && usage["limits"]) || [], &(is_map(&1) and &1["kind"] == kind)) || %{}
    %{percent: if(is_number(l["percent"]), do: l["percent"] / 1, else: nil), resets_at: time(l["resets_at"])}
  end

  defp time(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp time(_), do: nil

  # --- steps and days (pure) -------------------------------------------------

  @doc """
  The weekly reset between readings `a` and `b`, or nil: when the old
  period's reset falls between them, that instant; for an early reset, `b`'s.
  """
  def reset_between(a, b) do
    case {a.weekly_resets_at, b.weekly_resets_at} do
      {nil, _} -> nil
      {old, nil} -> if DateTime.compare(b.at, old) != :lt, do: old
      {old, new} -> if DateTime.diff(new, old) > @new_period_s, do: instant(old, a, b)
    end
  end

  defp instant(old, a, b),
    do: if(DateTime.compare(old, a.at) == :gt and DateTime.compare(old, b.at) != :gt, do: old, else: b.at)

  @doc "The weekly percentage points used between readings `a` and `b`, or nil when not known (a missing reading, or more than 3 h apart)."
  def used(a, b) do
    cond do
      not is_number(a.weekly_pct) or not is_number(b.weekly_pct) -> nil
      DateTime.diff(b.at, a.at) > @max_step_s -> nil
      reset_between(a, b) -> b.weekly_pct
      true -> max(b.weekly_pct - a.weekly_pct, 0.0)
    end
  end

  @doc """
  The days `from`..`to` (local dates in `tz`, oldest first) of one account's
  readings `samples` (ascending, those in the window), `prior` the last
  reading before it (or nil), `today` the local date now. Returns
  `%{days: [...], reset_times: [DateTime]}`.
  """
  def days(samples, prior, from, to, tz, today) do
    window = {midnight(from, tz), midnight(Date.add(to, 1), tz)}
    seq = if prior, do: [prior | samples], else: samples
    pairs = Enum.zip(seq, Enum.drop(seq, 1))

    used_by_day =
      Enum.reduce(pairs, %{}, fn {a, b}, acc ->
        case used(a, b) do
          nil -> acc
          u -> Map.update(acc, local_date(b.at, tz), u, &(&1 + u))
        end
      end)

    resets =
      pairs
      |> Enum.map(fn {a, b} -> reset_between(a, b) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&within?(&1, window))
      |> Enum.uniq()

    reset_days = MapSet.new(resets, &local_date(&1, tz))
    by_day = Enum.group_by(samples, &local_date(&1.at, tz))

    days =
      for date <- Date.range(from, to) do
        case Map.get(by_day, date, []) do
          [] ->
            %{date: date, weekly_used_pct: nil, weekly_pct_start_of_day: nil, weekly_pct_end_of_day: nil,
              reset_in_day: nil, samples: 0, partial: date == today}

          day ->
            %{
              date: date,
              weekly_used_pct: Float.round(Map.get(used_by_day, date, 0.0) / 1, 2),
              weekly_pct_start_of_day: start_of(seq, hd(day)),
              weekly_pct_end_of_day: day |> Enum.map(& &1.weekly_pct) |> Enum.reject(&is_nil/1) |> List.last(),
              reset_in_day: MapSet.member?(reset_days, date),
              samples: length(day),
              partial: date == today
            }
        end
      end

    %{days: days, reset_times: resets}
  end

  # The weekly reading just before `first` (the day's first sample).
  defp start_of(seq, first) do
    seq
    |> Enum.take_while(&(&1 != first))
    |> Enum.map(& &1.weekly_pct)
    |> Enum.reject(&is_nil/1)
    |> List.last()
  end

  defp within?(t, {from, to}), do: DateTime.compare(t, from) != :lt and DateTime.compare(t, to) == :lt

  @doc "The local date of `t` in `tz`."
  def local_date(t, tz) do
    {:ok, local} = DateTime.shift_zone(t, tz, @db)
    DateTime.to_date(local)
  end

  @doc "The UTC instant of local midnight starting `date` in `tz` (the earlier one on a DST fold)."
  def midnight(date, tz) do
    case DateTime.new(date, ~T[00:00:00], tz, @db) do
      {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC", @db)
      {:ambiguous, dt, _} -> DateTime.shift_zone!(dt, "Etc/UTC", @db)
      {:gap, _, dt} -> DateTime.shift_zone!(dt, "Etc/UTC", @db)
    end
  end

  @doc "The zone days are counted in unless asked otherwise: CV_USAGE_TZ, else Europe/Oslo (the operator's)."
  def default_tz, do: System.get_env("CV_USAGE_TZ") || "Europe/Oslo"

  @doc "When the daily line is next due after `now`: a minute past the next local midnight in `tz`."
  def next_run(now, tz), do: DateTime.add(midnight(Date.add(local_date(now, tz), 1), tz), 60)

  @doc "Whether `tz` is a time zone this server knows."
  def valid_zone?(tz) when is_binary(tz), do: match?({:ok, _}, DateTime.shift_zone(~U[2026-01-01 00:00:00Z], tz, @db))
  def valid_zone?(_), do: false

  # --- thinning (pure, then applied) ----------------------------------------------------

  @doc "The ids of one account's `samples` (ascending) that thinning keeps at `now`."
  def keep_ids(samples, now) do
    arr = List.to_tuple(samples)
    n = tuple_size(arr)

    for i <- 0..(n - 1)//1, keep?(elem(arr, i), i > 0 && elem(arr, i - 1), i < n - 1 && elem(arr, i + 1), now), into: MapSet.new() do
      elem(arr, i).id
    end
  end

  defp keep?(s, prev, next, now) do
    age = DateTime.diff(now, s.at)

    age < @raw_s or not is_number(s.weekly_pct) or next == false or
      bucket(s.at, age) != bucket(next.at, age) or
      (prev != false and edge?(prev, s)) or edge?(s, next)
  end

  # Something between `a` and `b` that thinning must not step over: a reset,
  # a fall, a gap, or a missing reading.
  defp edge?(a, b) do
    reset_between(a, b) != nil or not is_number(a.weekly_pct) or not is_number(b.weekly_pct) or
      b.weekly_pct < a.weekly_pct or DateTime.diff(b.at, a.at) >= @gap_s
  end

  defp bucket(at, age), do: div(DateTime.to_unix(at), if(age < @quarter_until_s, do: 900, else: 3600))

  @doc "Thin every account's samples as of `now`, and delete those past retention. Returns how many were deleted."
  def thin(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@retain_s)
    {expired, _} = Repo.delete_all(from(s in UsageSample, where: s.at < ^cutoff))

    thinned =
      Repo.all(from(s in UsageSample, distinct: true, select: s.anthropic_auth_id))
      |> Enum.map(fn auth_id ->
        samples = Repo.all(from(s in UsageSample, where: s.anthropic_auth_id == ^auth_id, order_by: [asc: s.at, asc: s.id]))
        keep = keep_ids(samples, now)
        drop = for s <- samples, not MapSet.member?(keep, s.id), do: s.id

        drop
        |> Enum.chunk_every(500)
        |> Enum.map(fn ids -> elem(Repo.delete_all(from(s in UsageSample, where: s.id in ^ids)), 0) end)
        |> Enum.sum()
      end)
      |> Enum.sum()

    expired + thinned
  end

  # --- reading -----------------------------------------------------------------

  @doc """
  The last `days` local days (in `tz`, today included) of every account:
  `%{tz, from, to, generated_at, accounts: [%{id, label, weekly_resets_at,
  reset_times, days, samples?}]}`. `raw` adds each account's samples.
  """
  def report(days, tz, raw \\ false, now \\ DateTime.utc_now()) do
    today = local_date(now, tz)
    from = Date.add(today, -(days - 1))
    {start, stop} = {midnight(from, tz), midnight(Date.add(today, 1), tz)}

    accounts =
      for auth <- Repo.all(from(a in AnthropicAuth, order_by: [asc: a.priority, asc: a.id])) do
        samples =
          Repo.all(
            from(s in UsageSample,
              where: s.anthropic_auth_id == ^auth.id and s.at >= ^start and s.at < ^stop,
              order_by: [asc: s.at, asc: s.id]
            )
          )

        prior =
          Repo.one(
            from(s in UsageSample, where: s.anthropic_auth_id == ^auth.id and s.at < ^start, order_by: [desc: s.at, desc: s.id], limit: 1)
          )

        next_reset =
          Repo.one(
            from(s in UsageSample,
              where: s.anthropic_auth_id == ^auth.id and not is_nil(s.weekly_resets_at),
              order_by: [desc: s.at, desc: s.id],
              limit: 1,
              select: s.weekly_resets_at
            )
          )

        %{days: day_list, reset_times: resets} = days(samples, prior, from, today, tz, today)

        base = %{id: auth.id, label: auth.label, weekly_resets_at: next_reset, reset_times: resets, days: day_list}
        if raw, do: Map.put(base, :samples, Enum.map(samples, &sample_json/1)), else: base
      end

    %{tz: tz, from: from, to: today, generated_at: DateTime.truncate(now, :second), accounts: accounts}
  end

  defp sample_json(s),
    do: %{at: s.at, weekly_pct: s.weekly_pct, weekly_resets_at: s.weekly_resets_at, session_pct: s.session_pct, session_resets_at: s.session_resets_at}

  @doc """
  The day's line for the server log, for local `date` in `tz`:
  `[usage] 2026-10-12 (Europe/Oslo) weekly use: Personal +18% (10% → 28%), Work +9% (25% → 34%, reset 09:00)`.
  """
  def daily_line(date, tz, now \\ DateTime.utc_now()) do
    today = local_date(now, tz)
    {start, stop} = {midnight(date, tz), midnight(Date.add(date, 1), tz)}

    parts =
      for auth <- Repo.all(from(a in AnthropicAuth, order_by: [asc: a.priority, asc: a.id])) do
        samples = Repo.all(from(s in UsageSample, where: s.anthropic_auth_id == ^auth.id and s.at >= ^start and s.at < ^stop, order_by: [asc: s.at, asc: s.id]))
        prior = Repo.one(from(s in UsageSample, where: s.anthropic_auth_id == ^auth.id and s.at < ^start, order_by: [desc: s.at, desc: s.id], limit: 1))
        %{days: [d], reset_times: resets} = days(samples, prior, date, date, tz, today)
        "#{auth.label} #{day_text(d, resets, tz)}"
      end

    "[usage] #{date} (#{tz}) weekly use: " <> if(parts == [], do: "no accounts", else: Enum.join(parts, ", "))
  end

  defp day_text(%{weekly_used_pct: nil}, _resets, _tz), do: "no readings"

  defp day_text(d, resets, tz) do
    reset = Enum.map_join(resets, "", &", reset #{Calendar.strftime(DateTime.shift_zone!(&1, tz, @db), "%H:%M")}")
    "+#{pct(d.weekly_used_pct)} (#{pct(d.weekly_pct_start_of_day)} → #{pct(d.weekly_pct_end_of_day)}#{reset})"
  end

  defp pct(nil), do: "?"
  defp pct(p), do: "#{:erlang.float_to_binary(p / 1, decimals: if(p == Float.round(p / 1), do: 0, else: 1))}%"
end
