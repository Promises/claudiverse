defmodule ClaudiverseServer.AnthropicAuths.PoolEvents do
  @moduledoc """
  Pool events a seat can be pinged about (Notifications.Router, the reserved
  `@pool:*` watch titles): an account's limit resetting, reaching 100%, and its
  weekly usage crossing a multiple of 5 or 10.

  An event is the difference between two usage readings of one account: the
  snapshot already stored (the previous reading, in the database) and the one
  just read (AnthropicAuths.record_usage/2). So each crossing fires once, an
  unchanged reading fires nothing, and a restart re-fires nothing: the first
  reading after boot is compared with the snapshot stored before it.

  Detection, per limit (`weekly_all` as "weekly", `session` as "session"):

  - **reset**: the limit's `resets_at` moved to a later period. Not "the percent
    dropped", which a manual reset also does. Later means more than an hour
    later, or no reset time any more once the old one has passed (an unused
    limit reports none).
  - **capped**: the percent went from below 100 to 100 or more.
  - **step** (weekly only): the highest multiple of 5, and of 10, at or below the
    percent rose; one event names the highest multiple crossed. A reset starts
    the count again from 0.

  Each event is a map with the `"change"` (`reset | capped | step`), the
  account (`"auth_id"`, `"label"`), `"limit"`, `"percent"` and `"was"`, the
  limit's `"resets_at"`, for a step `"every"` and `"crossed"`, and `"text"`:
  the one-line ping.
  """

  alias ClaudiverseServer.AnthropicAuths.AnthropicAuth

  @limits [{"weekly_all", "weekly"}, {"session", "session"}]
  @steps [5, 10]
  # A resets_at this much later is a new period, not the same one re-reported.
  @new_period_s 3600

  @doc """
  The events between `old` (the stored snapshot) and `new` (the reading just
  stored) for `auth` (read after the threshold was applied, for its cooldown).
  """
  def detect(old, new, %AnthropicAuth{} = auth, now \\ DateTime.utc_now()) do
    Enum.flat_map(@limits, fn {kind, limit} ->
      case {limit_of(old, kind), limit_of(new, kind)} do
        {%{percent: p0} = was, %{percent: p1} = now_l} when is_number(p0) and is_number(p1) ->
          for event <- limit_events(limit, was, now_l, now) do
            event
            |> Map.merge(%{
              "auth_id" => auth.id,
              "label" => auth.label,
              "limit" => limit,
              "percent" => p1,
              "was" => p0,
              "resets_at" => now_l.resets_at && DateTime.to_iso8601(now_l.resets_at)
            })
            |> then(&Map.put(&1, "text", text(&1, auth, now_l.resets_at)))
          end

        _ ->
          []
      end
    end)
  end

  defp limit_events(limit, was, now_l, now) do
    reset? = reset?(was.resets_at, now_l.resets_at, now)

    resets = if reset?, do: [%{"change" => "reset"}], else: []

    capped =
      if not reset? and was.percent < 100 and now_l.percent >= 100,
        do: [%{"change" => "capped"}],
        else: []

    steps =
      if limit == "weekly" do
        base = if reset?, do: 0, else: was.percent

        Enum.flat_map(@steps, fn n ->
          crossed = multiple(now_l.percent, n)
          if crossed > multiple(base, n), do: [%{"change" => "step", "every" => n, "crossed" => crossed}], else: []
        end)
      else
        []
      end

    resets ++ capped ++ steps
  end

  defp reset?(nil, _new, _now), do: false

  defp reset?(old, nil, now), do: DateTime.compare(now, old) != :lt

  defp reset?(old, new, _now), do: DateTime.diff(new, old) > @new_period_s

  defp multiple(pct, n), do: min(trunc(pct / n) * n, 100)

  defp limit_of(nil, _kind), do: nil

  defp limit_of(usage, kind) do
    case Enum.find(usage["limits"] || [], &(is_map(&1) and &1["kind"] == kind)) do
      nil -> nil
      l -> %{percent: l["percent"], resets_at: parse_time(l["resets_at"])}
    end
  end

  defp parse_time(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_time(_), do: nil

  defp text(%{"change" => "reset"} = e, _auth, resets_at) do
    next = if resets_at, do: "next reset #{when_(resets_at)}", else: "no next reset reported yet"
    "POOL reset: #{e["label"]} #{e["limit"]} #{pct(e["was"])} → #{pct(e["percent"])} (#{next})"
  end

  defp text(%{"change" => "capped"} = e, %AnthropicAuth{cooldown_until: until}, _resets_at) do
    cooling = if until, do: ", cooling until #{when_(until)}", else: ""
    "POOL capped: #{e["label"]} #{e["limit"]} #{pct(e["percent"])}#{cooling}"
  end

  defp text(%{"change" => "step"} = e, _auth, _resets_at) do
    "POOL step: #{e["label"]} #{e["limit"]} crossed #{e["crossed"]}% (now #{pct(e["percent"])})"
  end

  defp pct(p) when is_float(p), do: "#{round(p)}%"
  defp pct(p), do: "#{p}%"

  defp when_(dt), do: Calendar.strftime(dt, "%a %Y-%m-%d %H:%M UTC")
end
