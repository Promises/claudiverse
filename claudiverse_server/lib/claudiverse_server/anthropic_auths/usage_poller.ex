defmodule ClaudiverseServer.AnthropicAuths.UsagePoller do
  @moduledoc """
  Periodically reads each account's usage and cools down the ones near a limit.

  ## Why this exists, beyond a nicer panel

  It is also how a rate limit gets NOTICED WITHOUT A CLIENT PATCH. Seats run
  stock — they have no hook to report a 429 back — so if the server never looked,
  the only signal would be a worker failing mysteriously. Polling gives the pool
  a first-hand view and lets it stop leasing an exhausted account BEFORE a seat
  spends a turn discovering the limit.

  ## What it will not do

  ⛔ A FAILED POLL NEVER MARKS AN ACCOUNT HEALTHY, AND NEVER MARKS IT EXHAUSTED.
  Unknown is its own state. Treating a network error as "fine" would be a check
  that cannot fail; treating it as "exhausted" would take the fleet offline every
  time Anthropic hiccups. On failure the previous snapshot simply goes stale, and
  the panel shows when it was last read.

  ## Tuning

      CV_USAGE_POLL_MS        interval, default 300_000 (5 min)
      CV_USAGE_COOLDOWN_PCT   cool down at or above this percent, default 95
      CV_USAGE_POLL           set to "0" to disable entirely

  The interval is deliberately slow. This is a background signal, not a
  gate — the lease path never blocks on it, and a stale snapshot degrades to
  the behaviour we would have had without polling at all.
  """

  use GenServer

  require Logger

  alias ClaudiverseServer.AnthropicAuths
  alias ClaudiverseServer.AnthropicAuths.AnthropicAuth

  @default_interval 300_000
  @default_threshold 95

  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, Keyword.put(opts, :name, __MODULE__))

  @doc """
  Re-evaluate the best account now, without polling (the operator changed the
  preference). A no-op when the poller is not running.
  """
  def reconsider do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :reconsider), else: :ok
  end

  @doc "Poll now, ignoring the schedule. Returns the per-account outcomes."
  def poll_now, do: GenServer.call(__MODULE__, :poll, 60_000)

  @impl true
  def init(:ok) do
    if enabled?() do
      # First poll is delayed: at boot the vault key and accounts may not be
      # ready yet, and a failure in the first second is noise rather than signal.
      Process.send_after(self(), :poll, 30_000)
      # best_id: the highest-priority usable account at the last poll. A change
      # to a BETTER one is what we broadcast on.
      {:ok, %{best_id: nil}}
    else
      Logger.info("[anthropic_auths] usage poller disabled (CV_USAGE_POLL=0)")
      :ignore
    end
  end

  @impl true
  def handle_info(:poll, state) do
    poll_all()
    state = maybe_announce_upgrade(state)
    Process.send_after(self(), :poll, interval())
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast(:reconsider, state), do: {:noreply, maybe_announce_upgrade(state)}

  @impl true
  def handle_call(:poll, _from, state) do
    result = poll_all()
    {:reply, result, maybe_announce_upgrade(state)}
  end

  # --- preferred-account recovery -------------------------------------------
  #
  # A failover is one-way on its own: a seat that switched to the fallback stays
  # there until it restarts. Meanwhile the PREFERRED account comes back within
  # hours and sits unused, and the weekly quotas diverge — measured 44% on the
  # preferred account against 1% on the fallback, while the preferred one was
  # the only one being exhausted daily.
  #
  # So when the best usable account IMPROVES, tell every live session. Each one
  # re-leases and compares; the lease already returns the highest-priority usable
  # account, so a seat already on it does nothing. The ordering decision stays in
  # one place instead of being duplicated per client where it could drift.
  #
  # ⚠️ Only fires when the best account CHANGES (better, or worse because the
  # old best stopped being leasable). Announcing every poll would have every
  # seat re-lease every five minutes forever, and a swap is not free — it
  # invalidates the credential memo and risks racing an in-flight request.
  # Public (@doc false) so the state machine can be exercised directly. Driving
  # it through the timer would need a live poll and a real cooldown lapse — i.e.
  # a test nobody runs, which is the same as untested.
  @doc false
  def maybe_announce_upgrade(state) do
    best =
      AnthropicAuths.list_auths()
      |> Enum.filter(&AnthropicAuth.leasable?/1)
      |> Enum.sort_by(&{&1.priority, &1.id})
      |> List.first()

    prev = Map.get(state, :best_id)

    cond do
      # Nothing leasable: seats are on a last-resort account (or stalled), so
      # the NEXT account to come back is an improvement worth announcing —
      # unlike the boot state (nil), which knows nothing yet.
      is_nil(best) ->
        %{state | best_id: :none}

      best.id == prev ->
        state

      # Boot: nothing known yet, so nothing changed. Record it, announce nothing
      # (a server restart must not nudge every seat).
      is_nil(prev) ->
        %{state | best_id: best.id}

      # Improvement means: no previous best, or this one sorts ahead of it.
      improvement?(best, prev) ->
        Logger.info("[anthropic_auths] preferred account #{best.label} available — notifying seats")
        broadcast_upgrade()
        AnthropicAuths.notify_pool("upgrade")
        %{state | best_id: best.id}

      # Best changed and got WORSE: the account seats were on stopped being
      # leasable (the poll cooled it at its margin, or it needs re-auth). Move
      # seats off it NOW. Waiting for each one's own 429 defeats the margin,
      # whose whole point is to leave before the account runs dry. MEASURED
      # 2026-10-06 01:08Z: the poll cooled Personal at 96% and NO seat moved
      # (patched seats keep their token until a 429; the proxy re-checks every
      # 5 min). The nudge is the same as an upgrade's: each seat re-leases and
      # takes whatever the lease returns, so the ordering stays in one place.
      true ->
        Logger.info("[anthropic_auths] best account now #{best.label} (the previous one is not leasable) — moving seats")
        broadcast_upgrade()
        AnthropicAuths.notify_pool("degrade")
        %{state | best_id: best.id}
    end
  end

  defp improvement?(_best, nil), do: false
  defp improvement?(_best, :none), do: true

  defp improvement?(best, prev_id) do
    case AnthropicAuths.get_auth(prev_id) do
      nil -> true
      prev -> {best.priority, best.id} < {prev.priority, prev.id}
    end
  end

  defp broadcast_upgrade do
    # Pooled proxy seats hold one cached lease; drop it so their next request
    # leases the new best instead of up to @relook_ms later.
    ClaudiverseServer.Proxy.Credentials.reset()

    Registry.select(ClaudiverseServer.Sessions.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.each(fn session_id ->
      try do
        ClaudiverseServer.Sessions.Room.notify_auth_upgrade(session_id)
      catch
        # A room that died between select and cast must not take the poller with
        # it — this runs on a timer and has to survive every tick.
        _, _ -> :ok
      end
    end)
  end

  defp poll_all do
    AnthropicAuths.list_auths()
    |> Enum.reject(&(&1.status == "needs_reauth"))
    |> Enum.map(&poll_one/1)
  end

  # refresh_usage/1 applies the threshold itself (as enrolment and the
  # panel's Check usage do): every fresh reading is acted on, not only this one.
  defp poll_one(%AnthropicAuth{} = auth) do
    case AnthropicAuths.refresh_usage(auth) do
      {:ok, _updated} ->
        {auth.label, :ok}

      {:error, reason} ->
        # Stale, not exhausted. Say so and change nothing.
        {auth.label, {:unknown, reason}}
    end
  end

  # Cool down an account at or above the threshold, using the reset time the API
  # reported alongside that specific limit.
  #
  # 🔑 READS THE `limits` ARRAY, NOT THE TOP-LEVEL KEYS. The first version of
  # this read session_usage_percent / week_usage_percent / *_reset_time, which
  # was a guess from a third-party integration and MATCHES NOTHING in the real
  # response. Measured shape:
  #
  #     "limits": [
  #       {"group":"session","kind":"session","percent":34,
  #        "resets_at":"2026-09-12T16:40:00Z","severity":"normal","is_active":true},
  #       {"group":"weekly","kind":"weekly_all","percent":4, ...},
  #       {"group":"weekly","kind":"weekly_scoped","percent":0,
  #        "scope":{"model":{"display_name":"Fable"}}, ...}
  #     ]
  #
  # `limits` is the right thing to key on for three reasons: each entry pairs a
  # percent with ITS OWN reset time (the top-level five_hour/seven_day objects
  # split them across keys), new limit kinds arrive as new array entries rather
  # than new top-level keys, and it is self-describing.
  #
  # ⚠️ The response also carries ~9 null keys with names like `amber_ladder`,
  # `cinder_cove`, `juniper_tide`. They are all null and look deliberately
  # decoy-shaped. Do not key on any of them.
  #
  # ⚠️ `is_active` is NOT used as a filter. Its meaning is not established — on
  # the measured sample only the session limit had it true, while the weekly one
  # at 4% had it false. A weekly limit near 100% with is_active:false would still
  # end the account's week, so filtering on a flag I cannot define would be
  # guessing with the fleet's uptime.
  @doc false
  def apply_threshold(%AnthropicAuth{usage_snapshot: nil}), do: :ok

  def apply_threshold(%AnthropicAuth{usage_snapshot: usage} = auth) do
    case cooldown_for(usage) do
      nil ->
        maybe_lift(auth, usage, threshold())

      attrs ->
        Logger.info("[anthropic_auths] #{auth.label} #{attrs.cooldown_reason} — cooling until #{attrs.cooldown_until}")
        AnthropicAuths.update_auth(auth, attrs)
    end
  end

  @doc """
  The cooldown a usage reading calls for, as auth attributes, or nil when
  every limit is under the threshold. Several limits can be over at once; the
  account is unusable until the LATEST of them clears. Enrolment uses it to
  store a capped account as cooling_down in the same write that creates it.
  """
  def cooldown_for(nil), do: nil

  def cooldown_for(usage) do
    threshold = threshold()

    over =
      (usage["limits"] || [])
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn l -> {l["percent"], parse_reset(l["resets_at"]), l["kind"] || l["group"]} end)
      |> Enum.filter(fn {pct, reset, _} ->
        is_number(pct) and pct >= threshold and not is_nil(reset)
      end)

    case over do
      [] ->
        nil

      list ->
        {pct, until, kind} = Enum.max_by(list, fn {_, dt, _} -> DateTime.to_unix(dt) end)

        %{
          status: "cooling_down",
          cooldown_until: DateTime.truncate(until, :second),
          cooldown_reason: "#{kind} at #{round(pct)}% >= #{threshold}% (usage poll)"
        }
    end
  end

  # 🔴 A COOLDOWN THIS POLL SET, THIS POLL MAY LIFT. Without this a poll-set
  # cooldown ran to its stored reset time even after the usage came back down.
  # MEASURED 2026-10-02: the operator applied a weekly reset to Personal; the
  # poll then read weekly_all 0%, and the account stayed cooling_down until
  # 2026-10-04T23:59Z with every seat on the fallback at 94%.
  #
  # Only a cooldown whose reason is exactly the poll's own ("… (usage poll)") is
  # lifted. A 429-derived one is NOT: a 429 can come from limits this usage
  # response does not report, so the poll cannot prove it over. And only on
  # evidence — a response with no readable limit lifts nothing, since an empty
  # or reshaped body would otherwise read as "all clear".
  defp maybe_lift(%AnthropicAuth{status: "cooling_down", cooldown_reason: reason} = auth, usage, threshold)
       when is_binary(reason) do
    readable = for l <- usage["limits"] || [], is_map(l), is_number(l["percent"]), do: l["percent"]

    if String.ends_with?(reason, "(usage poll)") and readable != [] do
      peak = Enum.max(readable)

      Logger.info(
        "[anthropic_auths] #{auth.label} usage back under #{threshold}% (peak #{peak}%) — lifting the poll's cooldown"
      )

      AnthropicAuths.update_auth(auth, %{
        status: "available",
        cooldown_until: nil,
        cooldown_reason: "lifted: usage poll shows every limit under #{threshold}% (peak #{round(peak)}%)"
      })
    else
      :ok
    end
  end

  defp maybe_lift(_auth, _usage, _threshold), do: :ok

  defp parse_reset(nil), do: nil

  defp parse_reset(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_reset(v) when is_integer(v) do
    case DateTime.from_unix(v) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp parse_reset(_), do: nil

  defp enabled?, do: System.get_env("CV_USAGE_POLL") != "0"

  defp interval do
    case Integer.parse(System.get_env("CV_USAGE_POLL_MS") || "") do
      {n, _} when n >= 30_000 -> n
      _ -> @default_interval
    end
  end

  defp threshold do
    case Integer.parse(System.get_env("CV_USAGE_COOLDOWN_PCT") || "") do
      {n, _} when n > 0 and n <= 100 -> n
      _ -> @default_threshold
    end
  end
end
