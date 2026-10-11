defmodule ClaudiverseServer.Schedules.Cron do
  @moduledoc """
  A schedule's next time: a 5-field cron (the `crontab` library) read as wall
  clock time in an IANA zone (the `tz` library), so "0 12 * * 0" in
  Europe/Oslo stays 12:00 local across a daylight-saving change.

  On a change day:
  - a local time the clock skips (spring forward, e.g. 02:30) fires at the
    first instant after the gap (03:00);
  - a local time that happens twice (fall back) fires once, at the first.
  """

  alias Crontab.CronExpression.Parser

  @db Tz.TimeZoneDatabase
  # A cron that matches nothing reachable (30 February) gives up rather than
  # searching for ever.
  @max_steps 32

  @doc "Parse a 5-field cron; `{:error, reason}` names what is wrong."
  def parse(cron) when is_binary(cron) do
    fields = String.split(cron)

    cond do
      String.starts_with?(String.trim(cron), "@reboot") ->
        {:error, "@reboot has no time to schedule"}

      not String.starts_with?(String.trim(cron), "@") and length(fields) != 5 ->
        {:error, "must have 5 fields (minute hour day-of-month month day-of-week), got #{length(fields)}"}

      true ->
        case Parser.parse(Enum.join(fields, " ")) do
          {:ok, expr} -> check_reachable(expr)
          {:error, why} -> {:error, "is not a valid cron expression (#{why})"}
        end
    end
  end

  def parse(_), do: {:error, "must be a string"}

  defp check_reachable(expr) do
    case Crontab.Scheduler.get_next_run_date(expr, ~N[2026-01-01 00:00:00]) do
      {:ok, _} -> {:ok, expr}
      {:error, _} -> {:error, "never matches a real date"}
    end
  end

  @doc "Is `tz` an IANA zone name this server knows?"
  def valid_zone?(tz) when is_binary(tz) do
    match?({:ok, _}, DateTime.shift_zone(~U[2026-01-01 00:00:00Z], tz, @db))
  end

  def valid_zone?(_), do: false

  @doc """
  The first time strictly after `since` (a UTC DateTime) that `cron` names in
  zone `tz`, as a UTC DateTime truncated to the second.
  """
  def next_after(cron, tz, %DateTime{} = since) when is_binary(cron) do
    {:ok, expr} = parse(cron)
    next_after(expr, tz, since)
  end

  def next_after(%Crontab.CronExpression{} = expr, tz, %DateTime{} = since) do
    {:ok, local} = DateTime.shift_zone(since, tz, @db)

    local
    |> DateTime.to_naive()
    |> NaiveDateTime.truncate(:second)
    |> Map.put(:second, 0)
    |> NaiveDateTime.add(60)
    |> search(expr, tz, since, @max_steps)
  end

  defp search(_from, _expr, _tz, _after, 0), do: nil

  defp search(from, expr, tz, since, steps) do
    {:ok, candidate} = Crontab.Scheduler.get_next_run_date(expr, from)

    case Enum.find(instants(candidate, tz), &(DateTime.compare(&1, since) == :gt)) do
      nil -> search(NaiveDateTime.add(candidate, 60), expr, tz, since, steps - 1)
      at -> at |> DateTime.shift_zone!("Etc/UTC", @db) |> DateTime.truncate(:second)
    end
  end

  # The real instants a local wall-clock time names: one, two in a fall-back
  # hour, or (in a skipped hour) the first instant after the gap.
  defp instants(naive, tz) do
    case DateTime.from_naive(naive, tz, @db) do
      {:ok, at} -> [at]
      {:ambiguous, first, second} -> [first, second]
      {:gap, _before, just_after} -> [just_after]
    end
  end

  @doc "A UTC time as the zone's wall clock: `Sun 2026-10-18 12:00 CEST (Europe/Oslo)`."
  def local_string(%DateTime{} = utc, tz) do
    local = DateTime.shift_zone!(utc, tz, @db)
    Calendar.strftime(local, "%a %Y-%m-%d %H:%M ") <> local.zone_abbr <> " (#{tz})"
  end
end
