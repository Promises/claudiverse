defmodule ClaudiverseServer.AnthropicAuths do
  @moduledoc """
  The shared pool of Anthropic subscription accounts.

  Seats lease a currently-valid access token from here. They never hold a
  refresh token and never call Anthropic's token endpoint themselves.

  ## 🔴 Why the server is the only refresher

  A refresh response MAY carry a replacement refresh token. If a client refreshes
  and gets one, the server's stored copy is dead and the server can no longer
  refresh for anyone else on that account — while the panel keeps showing it
  `available`. If the response does NOT carry one, a client refresh accomplished
  nothing the server could not do. One arm is catastrophic and the other is
  pointless, so the client has no business holding the refresh token.

  ## 🔴 Why refresh is serialised per auth

  Two seats leasing at the same expiry both see a stale token and both refresh.
  If the response rotates, the second refresh invalidates the first's result and
  one seat is left holding a token that was already replaced. Serialising
  per-auth turns that into one refresh whose result both seats receive.

  Design: docs/ANTHROPIC_AUTHS_DESIGN.md
  """

  import Ecto.Query

  alias ClaudiverseServer.Repo
  alias ClaudiverseServer.AnthropicAuths.{AnthropicAuth, Assignment, OAuth, RefreshLock, Vault}

  require Logger

  # --- CRUD -----------------------------------------------------------------

  def list_auths do
    Repo.all(from a in AnthropicAuth, order_by: [asc: a.priority, asc: a.id])
  end

  def get_auth(id), do: Repo.get(AnthropicAuth, id)
  def get_auth_by_label(label), do: Repo.get_by(AnthropicAuth, label: label)

  def create_auth(attrs) do
    %AnthropicAuth{} |> AnthropicAuth.changeset(attrs) |> Repo.insert()
  end

  def update_auth(%AnthropicAuth{} = auth, attrs) do
    auth |> AnthropicAuth.changeset(attrs) |> Repo.update()
  end

  def delete_auth(%AnthropicAuth{} = auth), do: Repo.delete(auth)

  @doc "The PubSub topic of pool changes; every operator:events channel listens (one pool serves the server)."
  def pool_topic, do: "operator:pool"

  @doc """
  Tell the apps the pool changed, so they refetch at once instead of on their
  poll: `{"pool", %{"change", "by", "at", "current_id", "preferred_id"}}`.
  `change` is preferred | upgrade | degrade | cooling; `by` who made a manual
  change (nil for the server's own); `current_id` the account a lease gets now.
  """
  def notify_pool(change, by \\ nil) do
    auths = list_auths()

    Phoenix.PubSub.broadcast(ClaudiverseServer.PubSub, pool_topic(), {"pool", %{
      "change" => change,
      "by" => by,
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "current_id" => current_id(),
      "preferred_id" => auths |> List.first() |> then(&(&1 && &1.id))
    }})
  end

  @doc "The account a lease would get right now (the pool's choice), or nil."
  def current_id do
    case pick() do
      %AnthropicAuth{id: id} -> id
      _ -> nil
    end
  end

  @doc """
  Make `auth` the preferred account: it ranks first in every lease. The
  priorities are renumbered 10, 20, 30, … with `auth` first and the others in
  their current order. Preferred is first CHOICE: a cooling or needs-reauth
  account is still skipped, and returned to when it recovers.

  Takes effect at once: the proxy drops its cached lease (pooled seats use the
  new order on their next request), and the usage poller re-evaluates the
  best account, which nudges patched seats over when it improved.
  """
  def make_preferred(%AnthropicAuth{id: id}, by \\ nil) do
    {first, rest} = list_auths() |> Enum.split_with(&(&1.id == id))

    Repo.transaction(fn ->
      (first ++ rest)
      |> Enum.with_index(1)
      |> Enum.each(fn {a, i} -> a |> Ecto.Changeset.change(priority: i * 10) |> Repo.update!() end)
    end)

    ClaudiverseServer.Proxy.Credentials.reset()
    ClaudiverseServer.AnthropicAuths.UsagePoller.reconsider()
    Logger.info("[anthropic_auths] preferred account set: #{hd(first).label}#{if by, do: " (by #{by})"}")
    notify_pool("preferred", by)
    {:ok, list_auths()}
  end

  def vault_configured?, do: Vault.configured?()

  # --- Leasing --------------------------------------------------------------

  @doc """
  Hand out a currently-valid access token, refreshing under lock if needed.

  Returns `{:ok, %{auth: auth, access_token: token, expires_at: dt}}` or
  `{:error, :no_available_auth | :needs_reauth | term}`.

  `exclude_ids` lets a seat that just took a 429 ask for "anything but that one"
  in a single round trip.
  """
  def lease(opts \\ []) do
    exclude = Keyword.get(opts, :exclude_ids, [])

    with %AnthropicAuth{} = auth <- pick(exclude) || {:error, :no_available_auth},
         {:ok, valid} <- valid_token(auth) do
      {:ok, lease_result(valid)}
    end
  end

  @doc """
  A seat hit a 429 on this auth. Put it in cooldown and offer the next one.

  `resets_at` should come from the rate-limit reset the API reported. When it is
  missing we fall back to a conservative default rather than leaving the account
  hot — an account we keep leasing into a limit produces a failure per seat, not
  one failure.
  """
  @default_cooldown_seconds 15 * 60

  # A client's 429 report is TESTIMONY, not measurement. Cross-check it against
  # our own usage snapshot before taking an account out for hours.
  @suspect_cooldown_seconds 120
  @snapshot_fresh_seconds 180

  def report_rate_limited(%AnthropicAuth{} = auth, resets_at \\ nil, reason \\ nil) do
    requested = resets_at || DateTime.add(DateTime.utc_now(), @default_cooldown_seconds, :second)

    # 🔴 DO NOT LET A REPORT OVERRIDE A FRESH MEASUREMENT THAT CONTRADICTS IT.
    # MEASURED on the first live failover: a session on a rate-limited Personal
    # switched to Work correctly, then an IN-FLIGHT 429 from the old account
    # arrived and was attributed to Work — cooling a healthy account (session 3%,
    # weekly 0%) until PERSONAL's 12:40 reset. Both accounts unavailable; the
    # pool blocked the entire fleet. A failover that disables the account it just
    # rescued you with.
    # The client now has an in-flight guard, but the server must not depend on
    # every client being correct: it holds the usage data and should use it.
    # A fresh snapshot showing the account well under threshold makes the report
    # SUSPECT, not false — the snapshot can be stale, and limits exist that usage
    # does not report. So we still cool it, briefly, and let the next poll settle
    # it. Wrong-and-short self-heals in minutes; wrong-and-long blocks a fleet.
    {until, note} =
      case suspect_report?(auth) do
        {true, pct} ->
          short = DateTime.add(DateTime.utc_now(), @suspect_cooldown_seconds, :second)

          Logger.warning(
            "[anthropic_auths] #{auth.label} reported 429 but fresh usage says #{pct}% — " <>
              "capping cooldown at #{@suspect_cooldown_seconds}s instead of #{requested}"
          )

          {short, " (SUSPECT: fresh usage #{pct}%, cooldown capped)"}

        {false, _} ->
          {requested, ""}
      end

    # ⛔ A REPORT MAY EXTEND A COOLDOWN. IT MAY NEVER SHORTEN ONE.
    # MEASURED 2026-09-18: the usage poll had Personal at weekly_all 100% and
    # cooling until its weekly reset on the 20th. A seat's 429 report then
    # arrived with no usable resets_at, took the 15-minute default, and this
    # write REPLACED the poll's two-day cooldown with it. Fifteen minutes later
    # Personal was leasable again, lorem-w3 was handed it on relaunch, spent two
    # minutes booting, and 429'd on its first request — into an account the
    # server had already measured as empty for the week.
    # The poll re-derives the truth every five minutes, but "self-correcting"
    # only bounds the damage; inside the window the pool is handing out dead
    # accounts, and every client report re-opens it. The report knows one
    # thing — a 429 happened — and the existing cooldown may know more.
    # Applies to the SUSPECT cap too: that cap limits how far THIS report can
    # push a cooldown out, not how far it can pull one in.
    # DateTime.compare, never `>`: struct comparison is field-by-field, and the
    # compiler only warns about it under --warnings-as-errors.
    {until, note} =
      case auth.cooldown_until do
        %DateTime{} = existing ->
          if DateTime.compare(existing, until) == :gt,
            do: {existing, " (429 reported; kept the longer existing cooldown)"},
            else: {until, note}

        _ ->
          {until, note}
      end

    # When the existing cooldown wins, its reason still explains it — the poll's
    # "weekly_all at 100%" is the truth, and "rate limited (429)" would replace
    # a measurement with a symptom.
    reason_text =
      if String.contains?(note, "kept the longer"),
        do: "#{auth.cooldown_reason}#{note}",
        else: "#{reason}#{note}"

    {:ok, _} =
      update_auth(auth, %{
        status: "cooling_down",
        cooldown_until: DateTime.truncate(until, :second),
        cooldown_reason: reason_text
      })

    Logger.info("[anthropic_auths] #{auth.label} cooling down until #{until}#{note}")
    notify_pool("cooling")

    case lease(exclude_ids: [auth.id]) do
      {:ok, next} -> {:ok, next}
      {:error, _} = err -> err
    end
  end

  @doc """
  A seat got a 401. Force one refresh under lock and hand back the new token.

  This is distinct from `lease/1` because a 401 means the seat's token is dead
  NOW — the stored `expires_at` said otherwise, so the clock cannot be trusted
  for this one and we refresh regardless of it.
  """
  def report_unauthorized(%AnthropicAuth{} = auth) do
    RefreshLock.with_lock(auth.id, fn ->
      auth = Repo.get(AnthropicAuth, auth.id)
      do_refresh(auth)
    end)
  end

  # --- Usage polling --------------------------------------------------------

  @doc """
  Refresh the cached usage snapshot for one auth.

  ⚠️ Failure here is NOT evidence the account is healthy. It is recorded as
  "unknown" and the chooser must fall back to reactive 429 handling — treating
  a failed poll as "fine" would be a check that cannot fail.
  """
  def refresh_usage(%AnthropicAuth{} = auth) do
    with {:ok, valid} <- valid_token(auth),
         {:ok, usage} <- OAuth.usage(AnthropicAuth.decrypt_access_token(valid)) do
      record_usage(valid, usage)
    else
      {:error, reason} ->
        Logger.warning("[anthropic_auths] usage poll failed for #{auth.label}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Store a usage reading and act on it at once: an account at or over the
  threshold cools down (UsagePoller.apply_threshold/1) in the same call. Every
  reading goes through here (the poll, the panel's Check usage), so none of
  them leaves a capped account leasable until the next poll.
  """
  def record_usage(%AnthropicAuth{} = auth, usage) do
    with {:ok, updated} <-
           update_auth(auth, %{usage_snapshot: usage, usage_checked_at: DateTime.truncate(DateTime.utc_now(), :second)}) do
      ClaudiverseServer.AnthropicAuths.UsagePoller.apply_threshold(updated)
      {:ok, get_auth(updated.id)}
    end
  end

  # --- Enrolment ------------------------------------------------------------

  def start_authorization, do: OAuth.start_authorization()

  @doc """
  Complete a paste-the-code enrolment and store the account.
  """
  def complete_authorization(label, pasted_code, verifier, state, attrs \\ %{}) do
    with {:ok, tokens} <- OAuth.exchange_code(pasted_code, verifier, state) do
      email =
        case OAuth.profile(tokens["access_token"]) do
          {:ok, %{"account" => %{"email_address" => e}}} -> e
          {:ok, %{"email_address" => e}} -> e
          _ -> nil
        end

      # Read usage BEFORE storing, so an account enrolled at its limit is
      # stored cooling_down and is never leasable, not even until the next poll
      # (MEASURED 2026-10-10: an account enrolled at weekly 100% read available
      # for its first minute). A failed read stores no snapshot and changes
      # nothing: unknown is not exhausted.
      usage =
        case OAuth.usage(tokens["access_token"]) do
          {:ok, u} -> u
          _ -> nil
        end

      store_enrolment(label, tokens, email, usage, attrs)
    end
  end

  @doc """
  Store an enrolled account (`tokens` from the code exchange) in ONE write,
  with its status from both an existing cooldown and the `usage` read at
  enrolment: whichever cooldown lasts longer wins.
  """
  def store_enrolment(label, tokens, email, usage, attrs \\ %{}) do
    # 🔴 DO NOT CLEAR AN ACTIVE COOLDOWN ON RE-ENROLMENT.
    # Re-authenticating replaces CREDENTIALS; it does not replace USAGE. An
    # account rate-limited until tomorrow is still rate-limited with a shiny
    # new token. The first version reset status/cooldown unconditionally, and
    # MEASURED consequence: an account sitting at weekly_all=100% flipped to
    # `available` the moment it was re-enrolled, and stayed leasable until the
    # next poll re-derived the truth — up to five minutes of handing out an
    # account that cannot serve a request.
    # Self-correcting is not the same as correct: the window is small, silent,
    # and lands exactly when someone is fiddling with accounts.
    existing = get_auth_by_label(label)

    kept =
      case existing do
        %AnthropicAuth{cooldown_until: until} = e when not is_nil(until) ->
          # Still cooling: keep it, and keep why.
          if DateTime.compare(until, DateTime.utc_now()) == :gt,
            do: %{status: "cooling_down", cooldown_until: until, cooldown_reason: e.cooldown_reason}

        _ ->
          nil
      end

    measured = ClaudiverseServer.AnthropicAuths.UsagePoller.cooldown_for(usage)

    cooldown_attrs =
      case Enum.reject([kept, measured], &is_nil/1) do
        [] -> %{status: "available", cooldown_until: nil}
        list -> Enum.max_by(list, &DateTime.to_unix(&1.cooldown_until))
      end

    usage_attrs =
      if usage, do: %{usage_snapshot: usage, usage_checked_at: DateTime.truncate(DateTime.utc_now(), :second)}, else: %{}

    attrs
    |> Map.merge(%{
      label: label,
      account_email: email,
      scopes: tokens["scope"]
    })
    |> Map.merge(token_attrs(tokens, nil))
    |> Map.merge(usage_attrs)
    # Last, so nothing can overwrite it: this is the guard above.
    |> Map.merge(cooldown_attrs)
    |> upsert_by_label(label)
  end

  # --- internals ------------------------------------------------------------

  defp upsert_by_label(attrs, label) do
    case get_auth_by_label(label) do
      nil -> create_auth(attrs)
      existing -> update_auth(existing, attrs)
    end
  end

  # Reads the TIMESTAMP, never the cached `status` string — the string is a
  # render cache and the timestamp is the truth.
  # Is a 429 report contradicted by our own recent measurement?
  # Only a FRESH snapshot counts — a stale one cannot contradict anything.
  defp suspect_report?(%AnthropicAuth{usage_snapshot: nil}), do: {false, nil}
  defp suspect_report?(%AnthropicAuth{usage_checked_at: nil}), do: {false, nil}

  defp suspect_report?(%AnthropicAuth{usage_snapshot: usage, usage_checked_at: checked}) do
    age = DateTime.diff(DateTime.utc_now(), checked, :second)

    worst =
      (usage["limits"] || [])
      |> Enum.filter(&is_map/1)
      |> Enum.map(& &1["percent"])
      |> Enum.filter(&is_number/1)
      |> Enum.max(fn -> nil end)

    cond do
      age > @snapshot_fresh_seconds -> {false, nil}
      is_nil(worst) -> {false, nil}
      # Well clear of the limit: a real 429 here is possible but unlikely.
      worst < 80 -> {true, worst}
      true -> {false, worst}
    end
  end

  @doc false
  # Which account a lease would get, before any token handling: public so the
  # choice can be tested without a vault-encrypted token.
  def pick(exclude \\ []) do
    now = DateTime.utc_now()

    from(a in AnthropicAuth,
      where: a.status != "needs_reauth",
      where: is_nil(a.cooldown_until) or a.cooldown_until < ^now,
      where: a.id not in ^exclude,
      order_by: [asc: a.priority, asc: a.id],
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> last_resort(exclude, now)
      auth -> auth
    end
  end

  # 🔑 THE POLL'S MARGIN IS A PREFERENCE, NOT A LIMIT. The usage poll cools an
  # account at 95% so seats move off it BEFORE it runs dry — which only helps
  # while there is somewhere to move. With every account cooling, an account
  # cooled ONLY by that margin (reason exactly the poll's own, every limit it
  # reports still under 100%) is still leased, best priority first.
  # Operator 2026-10-03: Work sat at weekly 96% unused while Personal was out
  # of its 5-hour session, and the fleet had nothing.
  # Never a 429-derived cooldown (its reason is not the poll's — a 429 can come
  # from limits the poll cannot see) and never a limit at 100%: those are real.
  defp last_resort(exclude, now) do
    from(a in AnthropicAuth,
      where: a.status != "needs_reauth",
      where: a.cooldown_until >= ^now,
      where: a.id not in ^exclude,
      order_by: [asc: a.priority, asc: a.id]
    )
    |> Repo.all()
    |> Enum.find(&margin_only?/1)
    |> tap(fn
      nil -> :ok
      a -> Logger.info("[anthropic_auths] last resort: leasing #{a.label} inside its usage margin (#{a.cooldown_reason})")
    end)
  end

  defp margin_only?(%AnthropicAuth{cooldown_reason: reason, usage_snapshot: usage}) do
    readable = for l <- (usage || %{})["limits"] || [], is_map(l), is_number(l["percent"]), do: l["percent"]

    is_binary(reason) and String.ends_with?(reason, "(usage poll)") and
      readable != [] and Enum.all?(readable, &(&1 < 100))
  end

  # The auth with a currently valid access token, refreshing it under lock if
  # needed. It does NOT count as a lease: a usage read goes through here too,
  # and stamping last_leased_at for it showed an account the pool had never
  # handed out as leased (MEASURED 2026-10-10, at enrolment). lease/1 stamps.
  @doc false
  def valid_token(%AnthropicAuth{} = auth) do
    if AnthropicAuth.token_valid?(auth) do
      {:ok, auth}
    else
      # Serialise: concurrent leases at expiry collapse into one refresh.
      RefreshLock.with_lock(auth.id, fn ->
        # Re-read INSIDE the lock. Another caller may have refreshed while we
        # waited, in which case there is nothing to do — re-checking here is
        # what makes the lock useful rather than merely sequential.
        fresh = Repo.get(AnthropicAuth, auth.id)

        if AnthropicAuth.token_valid?(fresh) do
          {:ok, fresh}
        else
          do_refresh(fresh)
        end
      end)
    end
  end

  defp do_refresh(%AnthropicAuth{} = auth) do
    case AnthropicAuth.decrypt_refresh_token(auth) do
      nil ->
        mark_needs_reauth(auth, "no refresh token stored")

      refresh_token ->
        case OAuth.refresh(refresh_token) do
          {:ok, tokens} ->
            apply_refresh(auth, tokens)

          {:error, {:http, status, _}} when status in [400, 401, 403] ->
            # The refresh token itself is rejected. No amount of retrying fixes
            # this — it needs a human to re-enrol, so say so in the panel rather
            # than failing a lease every few seconds forever.
            mark_needs_reauth(auth, "refresh rejected with HTTP #{status}")

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc false
  def apply_refresh(%AnthropicAuth{} = auth, tokens) do
    prior = AnthropicAuth.decrypt_refresh_token(auth)

    update_auth(auth, Map.merge(token_attrs(tokens, prior), refreshed_status(auth)))
  end

  # 🔑 KEEP THE OLD REFRESH TOKEN WHEN THE RESPONSE OMITS ONE.
  # Anthropic does not always return a replacement. Writing nil would destroy
  # the only way back into the account and force a manual re-enrol — a
  # self-inflicted needs_reauth. The reference implementation
  # (trickv/hass-claude-usage) does exactly this fallback.
  # 🔴 CREDENTIALS ONLY. A refresh replaces the TOKEN; it says nothing about
  # USAGE, so it must not touch cooldown_until.
  # The first version wrote `status: "available", cooldown_until: nil` here, and
  # every hourly refresh of a weekly-exhausted account erased its cooldown.
  # MEASURED 2026-09-20 ~20:45: Personal at weekly_all 100% had its token
  # refreshed, became leasable for the instant before the poll re-cooled it, the
  # poller announced it as the preferred account, and every seat moved INTO the
  # exhausted account — 429, failover, retries, weekly-limit dialog, on a fleet
  # whose fallback sat at weekly 10%. The re-enrolment guard in
  # complete_authorization had already been written for this exact hazard and
  # was being overwritten by this map, merged after it.
  # Status is derived from the timestamp by the caller — see refreshed_status/1.
  defp token_attrs(tokens, prior_refresh) do
    expires_in = tokens["expires_in"] || 3600

    %{
      access_token: tokens["access_token"],
      refresh_token: tokens["refresh_token"] || prior_refresh,
      expires_at:
        DateTime.utc_now() |> DateTime.add(expires_in, :second) |> DateTime.truncate(:second),
      last_refreshed_at: DateTime.truncate(DateTime.utc_now(), :second)
    }
  end

  # The status string is a render cache of the timestamp. A successful refresh
  # is the one event that legitimately clears needs_reauth — and only that; an
  # account still inside its cooldown stays cooling_down.
  defp refreshed_status(%AnthropicAuth{cooldown_until: %DateTime{} = until}) do
    if DateTime.compare(until, DateTime.utc_now()) == :gt,
      do: %{status: "cooling_down"},
      else: %{status: "available"}
  end

  defp refreshed_status(_), do: %{status: "available"}

  defp mark_needs_reauth(auth, reason) do
    Logger.error("[anthropic_auths] #{auth.label} needs re-auth: #{reason}")
    update_auth(auth, %{status: "needs_reauth", cooldown_reason: reason})
    {:error, :needs_reauth}
  end

  defp lease_result(auth) do
    Repo.update_all(
      from(a in AnthropicAuth, where: a.id == ^auth.id),
      set: [last_leased_at: DateTime.truncate(DateTime.utc_now(), :second)]
    )

    %{
      auth: auth,
      auth_id: auth.id,
      label: auth.label,
      access_token: AnthropicAuth.decrypt_access_token(auth),
      expires_at: auth.expires_at,
      scopes: auth.scopes
    }
  end

  # --- who is on what ---------------------------------------------------------

  @doc """
  Record that `identity` is now using `auth_id`.

  ⭐ CALLED AT THE DECISION POINT. Every account change goes through a server
  call — the startup lease, the 429 failover, the upgrade push and the 401
  renewal — so recording here means the mapping is written by the party that
  chose it, at the moment it chose. Nothing depends on a client reporting its own
  state later, which is the design that made "which seat is on Work?"
  unanswerable in the first place.

  🔴 NEVER FAILS THE CALLER. This is bookkeeping hanging off the lease path, and
  the lease path is how the entire fleet obtains credentials. A bad title, a
  constraint race, a closed connection — none of that may turn "here is your
  account" into an error. It returns :ok regardless and logs the reason, because
  a missing diagnostic row costs one unanswered question while a failed lease
  costs a stalled seat.
  """
  def record_assignment(identity, auth_id, via)

  def record_assignment(%{title: title} = identity, auth_id, via)
      when is_binary(title) and title != "" and is_integer(auth_id) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    attrs = %{
      title: title,
      claude_session_id: nil,
      instance_id: identity_instance(identity),
      anthropic_auth_id: auth_id,
      assigned_at: now,
      via: via
    }

    attrs =
      case identity_session_id(identity) do
        nil -> Map.delete(attrs, :claude_session_id)
        sid -> %{attrs | claude_session_id: sid}
      end

    # ⛔ try/rescue, NOT just the changeset's foreign_key_constraint. MEASURED on
    # SQLite: a bad anthropic_auth_id surfaces with the constraint name reported
    # as nil, so Ecto cannot match it to the declared constraint and RAISES
    # instead of returning {:error, changeset}. That would turn a bookkeeping
    # miss into a 500 on the lease endpoint — a stalled seat caused by the
    # diagnostic meant to explain stalled seats. Caught by a test that asserted
    # the documented promise rather than the happy path.
    try do
      write_assignment(attrs)
    rescue
      e ->
        Logger.warning("[anthropic_auths] could not record assignment for #{title}: #{Exception.message(e)}")
        :ok
    end
  end


  # No title means an unidentified seat — an old binary that does not send the
  # header, or a direct curl. Silently skipped: this is the normal state for
  # every pre-AnthropicAuths client, and logging it would be pure noise.
  def record_assignment(_identity, _auth_id, _via), do: :ok

  defp write_assignment(attrs) do
    # ⭐ UPSERT ON instance_id WHEN THE CLIENT SENDS ONE. That is the key that
    # survives every rename; title is only the fallback for a client predating
    # it, and the migration's partial indexes mirror exactly this split.
    # ⛔ THE PREDICATE IS PART OF THE TARGET. Both unique indexes are PARTIAL, and
    # SQLite rejects an ON CONFLICT whose target does not restate the index's
    # WHERE clause: "ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE
    # constraint". A bare `conflict_target: :title` compiles and then fails at
    # runtime — where write_assignment swallows it and returns :ok, so the row
    # simply never appears. Caught by a test asserting the row exists.
    {target, replace} =
      if attrs[:instance_id] do
        {{:unsafe_fragment, "(instance_id) WHERE instance_id IS NOT NULL"},
         [:title, :claude_session_id, :anthropic_auth_id, :assigned_at, :via, :updated_at]}
      else
        {{:unsafe_fragment, "(title) WHERE instance_id IS NULL"},
         [:claude_session_id, :anthropic_auth_id, :assigned_at, :via, :updated_at]}
      end

    # ⛔ A TITLE BELONGS TO ONE LIVE INSTANCE. Keying on instance_id fixed renames
    # but replaced a UNIQUE title index with a PARTIAL one, so two rows may now
    # share a title whenever their instances differ — and every restart mints a
    # fresh instance. MEASURED four hours later: 19 rows for ~10 seats, with
    # 'claudiverse-account-failover' and 'ipsum-w5-t24955' at three apiece, because
    # nothing ever reaped the row the previous incarnation left behind.
    # The seat answering to a name NOW is the one that owns it; older rows under
    # that name describe processes that are gone.
    if attrs[:instance_id] do
      # ⛔ is_nil OR mismatch — NOT a bare `!=`. In SQL, NULL != 'abc' evaluates
      #    to NULL, not TRUE, so a bare inequality silently SKIPS every row whose
      #    instance_id is null — which is exactly the legacy rows this is meant
      #    to clear. MEASURED: a seat restarted and its pre-instance_id row
      #    survived alongside the new one, because the delete never matched it.
      #    The unit tests all used rows that HAD an instance_id, so they passed.
      Repo.delete_all(
        from a in Assignment,
          where:
            a.title == ^attrs.title and
              (is_nil(a.instance_id) or a.instance_id != ^attrs.instance_id)
      )
    end

    %Assignment{}
    |> Assignment.changeset(attrs)
    |> Repo.insert(on_conflict: {:replace, replace}, conflict_target: target)
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[anthropic_auths] could not record assignment: #{inspect(reason)}")
        :ok
    end
  end

  defp identity_instance(%{instance_id: i}) when is_binary(i) and i != "", do: i
  defp identity_instance(_), do: nil

  defp identity_session_id(%{claude_session_id: sid}) when is_binary(sid) and sid != "", do: sid
  defp identity_session_id(_), do: nil

  @doc """
  Every seat's current account, newest assignment first.

  ⚠️ `assigned_at` is when the account was handed over, NOT when the seat was
  last alive — nothing here observes a seat dying, so an entry for a killed seat
  sits there looking current. Callers that care about liveness must age these out
  themselves; this function will not pretend to know.
  """
  def list_assignments do
    Repo.all(
      from a in Assignment,
        order_by: [desc: a.assigned_at],
        preload: [:anthropic_auth]
    )
  end

  @doc """
  Note the title a seat is currently using.

  ⭐ NO GUESSING. Called from session creation, where the request carries the
  seat's instance_id, so this is a direct update of a known row rather than an
  attempt to infer which assignment belongs to which seat from a title that has
  already changed. The previous version tried to match on the OLD title or the
  session id and could match neither: the assignment was written at the startup
  lease (title = a timestamp, no session id) and the session moments later under
  the session UUID, so the two records had never shared a value.

  ⚠️ Never raises, never fails its caller — same contract as
  record_assignment/3. Session creation must succeed even when bookkeeping
  cannot be updated.
  """
  def note_seat_title(identity, title)

  def note_seat_title(%{instance_id: inst} = identity, title)
      when is_binary(inst) and inst != "" and is_binary(title) and title != "" do
    try do
      fields =
        [title: title, updated_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)]

      fields =
        case identity do
          %{claude_session_id: sid} when is_binary(sid) and sid != "" ->
            Keyword.put(fields, :claude_session_id, sid)

          _ ->
            fields
        end

      # Any other row already holding this title must not block the update. It
      # describes a seat that no longer answers to the name.
      # Same NULL-safety as record_assignment/3: a bare `!=` never matches a row
      # whose instance_id is null.
      Repo.delete_all(
        from a in Assignment,
          where: a.title == ^title and (is_nil(a.instance_id) or a.instance_id != ^inst)
      )

      Repo.update_all(from(a in Assignment, where: a.instance_id == ^inst), set: fields)
      :ok
    rescue
      e ->
        Logger.warning("[anthropic_auths] could not note seat title #{inspect(title)}: #{Exception.message(e)}")
        :ok
    end
  end

  def note_seat_title(_identity, _title), do: :ok
end
