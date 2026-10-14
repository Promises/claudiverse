defmodule ClaudiverseServer.Sessions do
  import Ecto.Query

  alias ClaudiverseServer.Repo
  alias ClaudiverseServer.Sessions.{Session, Message, CvEvent, CvSubscription}

  # A sidecar inserts a NEW session row on every launch/reconnect, so these
  # tables grow without bound (observed 2026-07-27: ~38k rows for one user,
  # `cv_list` returning a 1–3.5MB blob that blew the client's token limit).
  # Both list functions are therefore BOUNDED and RUNNING-FIRST by default.
  @default_list_limit 200

  @doc """
  Lists a user's sessions, running first, then most-recent, bounded.

  Options:
    * `:status` — `:running` (default) | `:stopped` | `:crashed` | `:all`
    * `:limit`  — max rows (default #{@default_list_limit})

  Defaults to RUNNING ONLY: callers asking "what sessions exist" almost always
  mean "what is alive", and returning every historical row is what made
  `cv_list` unusable. Pass `status: :all` for the full history.
  """
  def list_sessions(user_id, opts \\ []) do
    Session
    |> where(user_id: ^user_id)
    |> filter_status(Keyword.get(opts, :status, :running))
    |> order_running_first()
    |> limit(^Keyword.get(opts, :limit, @default_list_limit))
    |> Repo.all()
  end

  @doc """
  Lists a user's sessions whose title matches exactly — RUNNING FIRST, then
  newest, bounded.

  Titles are not unique (a sidecar creates a fresh session row on every
  launch), so an orchestrator resolving a friendly name like "decomper" should
  take the newest running match. That contract used to be the CALLER's job and
  was easy to get wrong: a caller taking `hd/1` could resolve a title to a
  STOPPED session and drive a zombie (observed 2026-07-27 — a stale `ipsum-orchestrator`
  woke under the live title and began acting). Ordering running-first here
  makes `hd/1` correct by construction; pass `status: :all` for history.

  See orchestrator/cvctl.mjs.
  """
  def list_sessions_by_title(user_id, title, opts \\ []) do
    Session
    |> where(user_id: ^user_id, title: ^title)
    |> filter_status(Keyword.get(opts, :status, :all))
    |> order_running_first()
    |> limit(^Keyword.get(opts, :limit, @default_list_limit))
    |> Repo.all()
  end

  # `:all` keeps every status; anything else filters to exactly that status.
  defp filter_status(query, :all), do: query
  defp filter_status(query, status), do: where(query, status: ^status)

  # Running rows first, then newest-first within each group.
  # ⭐ ORDERED BY LAST ACTIVITY, not creation.
  #
  # inserted_at ranks by when a seat was STARTED, so a long-lived watcher that
  # has been working all day sinks below a session opened minutes ago and never
  # used. What an operator scans for is "what moved recently", and the honest
  # source of that is the last message the session produced.
  #
  # Coalescing to inserted_at: a session with no messages yet has no activity to
  # sort by, and dropping it or sorting it last would hide a seat that just
  # started. Its creation time is the best available answer.
  #
  # Running still comes first — a stopped session that was busy an hour ago must
  # not outrank a live one that is merely quiet.
  #
  # 🔴 NOT A GROUP BY, AND THAT IS THE WHOLE POINT. The obvious form
  #
  #     LEFT JOIN (SELECT session_id, max(inserted_at) AS last_at
  #                FROM messages GROUP BY session_id) AS a ON a.session_id = s.id
  #
  # is correct and unusable: it groups the ENTIRE messages table on every list
  # call, and the LIMIT cannot reach inside it. Measured against the live DB
  # 2026-09-16 — `limit=3` took 17.8s and `limit=200` took 34s, which the web
  # panel showed as half a minute of "Loading…" and MCP clients saw as a
  # timeout. On a synthetic 1,500-session / 2M-message copy the two forms
  # measured 1,666ms vs 0.1ms.
  #
  # ⭐ A CORRELATED max(), NOT A GROUPED ONE. Restricting the aggregate to one
  # session turns it into a seek against (session_id, inserted_at) — added in
  # migration 20260917100000 precisely for this — so the cost stops depending on
  # how much traffic the fleet has ever mirrored.
  #
  # ⛔ AND NOT "the inserted_at of the highest-sequence row", which is what this
  # was first written as, because (session_id, sequence) was the index that
  # already existed and it looked equivalent. It is not. `sequence` is seeded
  # per ROOM from max(sequence)+1 at init and then incremented IN MEMORY, and
  # create_message's result is never checked, so ties and gaps are reachable —
  # and a tie makes ORDER BY sequence DESC LIMIT 1 return an arbitrary row among
  # the tied ones. Caught live 2026-09-17: session "testme" answered a message
  # while the list went on reporting an activity time 90 seconds stale.
  # The question is "when did something last happen", so it is answered with
  # time, never with a proxy for time.
  defmacrop last_activity(s) do
    quote do
      fragment(
        "COALESCE((SELECT max(m0.inserted_at) FROM messages AS m0 WHERE m0.session_id = ?), ?)",
        unquote(s).id,
        unquote(s).inserted_at
      )
    end
  end

  defp order_running_first(query) do
    query
    |> order_by([s],
      asc: fragment("CASE WHEN ? = 'running' THEN 0 ELSE 1 END", s.status),
      desc: last_activity(s)
    )
    |> select([s], %{s | last_activity_at: type(last_activity(s), :naive_datetime)})
  end

  def get_session!(id), do: Repo.get!(Session, id)

  def get_session(id), do: Repo.get(Session, id)

  @doc "Whether `user_id` has ever had a seat titled `title` (any row, running or not)."
  def user_has_title?(user_id, title) when is_binary(title) do
    Repo.exists?(from s in Session, where: s.user_id == ^user_id and s.title == ^title)
  end

  # With last_activity_at, as the list computes it. Without it the serializer
  # fell back to inserted_at, so GET /api/sessions/:id said "8h ago" for a seat
  # the list showed active minutes ago (measured on 203737 by the app).
  def get_user_session(user_id, session_id) do
    from(s in Session,
      where: s.id == ^session_id and s.user_id == ^user_id,
      select: %{s | last_activity_at: type(last_activity(s), :naive_datetime)}
    )
    |> Repo.one()
  rescue
    # A non-integer id from a URL: not found, as Repo.get_by answered it.
    Ecto.Query.CastError -> nil
  end

  @doc """
  A runner reports it is running seat `title` for `fleet` on `host`: record
  fleet, origin "runner" and host on that seat's newest running row, where
  the seat left them unset. lorem-fleet's runners predate placement reporting, so
  their workers registered with no fleet at all; the runner knows. Never
  overwrites what a seat reported itself. Returns the number of rows updated.
  """
  def stamp_runner_seat(user_id, title, fleet, host) do
    case from(s in Session,
           where: s.user_id == ^user_id and s.title == ^title and s.status == :running and s.type != :proxy,
           order_by: [desc: s.inserted_at, desc: s.id],
           limit: 1
         )
         |> Repo.one() do
      nil ->
        0

      session ->
        fill = fn field, value -> if is_nil(Map.get(session, field)) and not is_nil(value), do: [{field, value}], else: [] end
        changes = fill.(:fleet, fleet) ++ fill.(:origin, "runner") ++ fill.(:host, host)

        if changes == [] do
          0
        else
          {:ok, _} = session |> Ecto.Changeset.change(changes) |> Repo.update()
          1
        end
    end
  end

  @doc """
  After host `host`'s agent started seat `title` (a spawn or a resume): find
  the row that seat registered (running, inserted at or after `since`) and
  record what the server KNOWS about it, whatever the seat's runtime reports:
  - `host`, origin "spawn" and `working_directory`, where the seat left them
    unset. A runtime without placement (measured: the XPS's, row 204047)
    otherwise registers no host, and stop, interrupt and resume — which reach
    a seat through its machine — cannot address it;
  - `conversation_id`, for a resume: a resumed seat reports a placeholder
    claude_session_id, so this is what resuming it again needs;
  - for a profile start, `known` also carries origin "profile", the
    profile id and revision and the tmux session, filled where unset (the
    patched runtime does not report them; the mod does);
  - `model`, the model the seat was started with, where the row has none
    yet: until its first reply, nothing else says what it runs.
  A row that already reports a DIFFERENT host is not this seat. "Registered
  since" is inserted OR updated since: a resumed seat re-registers on its
  existing row (same Claude session id), whose inserted_at is old — MEASURED
  2026-10-05, Failover's profile start reported "did not register" for a seat
  that registered within 3 s on its September row.
  `{:ok, session}`, or `nil` when no such row exists yet.
  """
  def adopt_started_seat(user_id, host, title, since, known) do
    from(s in Session,
      where: s.user_id == ^user_id and (s.host == ^host or is_nil(s.host)) and s.title == ^title and
               s.status == :running and s.type != :proxy and (s.inserted_at >= ^since or s.updated_at >= ^since),
      order_by: [desc: s.inserted_at, desc: s.id],
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil ->
        nil

      session ->
        fill = fn field, value -> if is_nil(Map.get(session, field)) and not is_nil(value), do: [{field, value}], else: [] end

        changes =
          fill.(:host, host) ++ fill.(:origin, known[:origin] || "spawn") ++ fill.(:working_directory, known[:working_directory]) ++
            fill.(:profile_id, known[:profile_id]) ++ fill.(:profile_revision, known[:profile_revision]) ++
            fill.(:tmux_session, known[:tmux_session]) ++ fill.(:model, known[:model]) ++
            if(known[:conversation_id], do: [conversation_id: known[:conversation_id]], else: [])

        session |> Ecto.Changeset.change(changes) |> Repo.update()
    end
  end

  @doc """
  Creates a session — or REUSES the existing row when the sidecar reports a
  Claude session UUID we've seen before.

  A sidecar reconnects for many benign reasons (network blip, MCP restart,
  `--resume`). Previously each of those inserted a NEW row, so rows grew
  without bound (~38k observed) and stale same-title rows lingered as zombies
  that title-resolution could wake.

  Matching on Claude's own session id fixes that at the source: the same
  Claude session always maps to the same row. On a blip we flip it back to
  `:running` and refresh its metadata rather than inserting.

  Deliberately NOT the approach reverted in 1f71301: that one *stopped* older
  running rows for a title (kill-and-replace), which made live sidecars
  reconnect and caused a ~2 sessions/sec storm. Reuse touches only the row
  that genuinely belongs to this Claude session, so it cannot cascade.

  Falls back to a plain insert when `claude_session_id` is absent (legacy
  sidecars, `:spawned` sessions), so behaviour is unchanged for them.
  """
  def create_session(attrs) do
    user_id = attrs[:user_id] || attrs["user_id"]
    claude_session_id = attrs[:claude_session_id] || attrs["claude_session_id"]

    case find_reusable_session(user_id, claude_session_id) do
      nil ->
        %Session{}
        |> Session.changeset(attrs)
        |> unknown_model()
        |> Repo.insert()

      %Session{} = existing ->
        # Reconnect of a known Claude session: revive in place. Status is
        # forced back to :running; title/cwd/model may legitimately have
        # changed across a relaunch, so let the incoming attrs win.
        # ⛔ The seat's assignment is NOT reconciled here. This function does not
        # receive the request's instance_id, and without it there is nothing
        # reliable to match a seat on — an earlier version tried the previous
        # title and the session id and could match neither, because the
        # assignment is written at the startup lease under a different title and
        # with no session id. SessionController does it instead, where the
        # parsed client identity is in scope.
        existing
        |> Session.changeset(Map.put(normalize_attrs(attrs), :status, :running))
        |> Repo.update()
    end
  end

  defp find_reusable_session(nil, _), do: nil
  defp find_reusable_session(_, nil), do: nil
  defp find_reusable_session(_, ""), do: nil

  # A row whose claude_session_id is this conversation, OR that recorded it as
  # its conversation_id: a seat started with `--resume <name>` on the patched
  # runtime registers a placeholder session id, and the row it lived on holds
  # the real conversation only in conversation_id (set on resume adoption, or
  # by an app). Of those, the most recently active one is the seat's home.
  # MEASURED 2026-10-06: claudiverse-desktop moved to a profile resuming its
  # conversation 7ca78cbc; only an abandoned 3-minute row from Oct 4 had that
  # as its session id, so the seat was attached there (9 messages) instead of
  # its real row 204013 (7,542 messages, conversation_id 7ca78cbc).
  defp find_reusable_session(user_id, claude_session_id) do
    Session
    |> where(user_id: ^user_id)
    |> where([s], s.claude_session_id == ^claude_session_id or s.conversation_id == ^claude_session_id)
    |> where([s], s.type != :proxy)
    |> order_by(desc: :updated_at, desc: :id)
    |> limit(1)
    |> Repo.one()
  end

  # Accept either atom- or string-keyed attrs (controller params are strings).
  defp normalize_attrs(attrs) do
    Map.new(attrs, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    ArgumentError -> attrs
  end

  @doc """
  Record `host` on a row that has none (an older runtime never reported it).
  A row that recorded its machine keeps it.
  """
  def place_on_host(%Session{host: nil} = session, host) when is_binary(host) do
    case update_session(session, %{host: host}) do
      {:ok, s} -> s
      _ -> session
    end
  end

  def place_on_host(session, _host), do: session

  # A row with no model says so. Ecto leaves a nil field out of the INSERT,
  # so the column's own default ("sonnet", from the first migration; SQLite
  # can't drop a default without rebuilding the table) would fill it in.
  # MEASURED: the struct read nil while the stored row read "sonnet".
  defp unknown_model(changeset) do
    if Ecto.Changeset.get_change(changeset, :model), do: changeset, else: Ecto.Changeset.force_change(changeset, :model, nil)
  end

  def update_session(%Session{} = session, attrs) do
    session
    |> Session.changeset(attrs)
    |> Repo.update()
  end

  def delete_session(%Session{} = session) do
    Repo.delete(session)
  end

  def create_message(attrs) do
    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Record a structured observability event (idle/busy transition, cvdebug
  snapshot, …). Best-effort: never let logging break the message hot-path, so a
  failure is swallowed (returns `:error`) rather than crashing the Room.
  """
  def record_event(attrs) do
    %CvEvent{}
    |> CvEvent.changeset(attrs)
    |> Repo.insert()
  rescue
    _ -> :error
  end

  @doc "Recent observability events for a session, newest first."
  def list_events(session_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    kind = Keyword.get(opts, :kind)

    CvEvent
    |> where(session_id: ^session_id)
    |> then(fn q -> if kind, do: where(q, kind: ^kind), else: q end)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Persist a Router subscription (listener title -> watched titles), upserting on
  title. Best-effort: never break subscribe if persistence fails.
  """
  def put_subscription(listener_title, watch_titles) do
    %CvSubscription{}
    |> CvSubscription.changeset(%{listener_title: listener_title, watch: %{"titles" => watch_titles}})
    |> Repo.insert(on_conflict: {:replace, [:watch, :updated_at]}, conflict_target: :listener_title)
  rescue
    _ -> :error
  end

  def delete_subscription(listener_title) do
    Repo.delete_all(from s in CvSubscription, where: s.listener_title == ^listener_title)
  rescue
    _ -> :error
  end

  @doc "All persisted subscriptions as %{listener_title => [watched_titles]} (for Router rehydrate)."
  def list_subscriptions do
    CvSubscription
    |> Repo.all()
    |> Map.new(fn s -> {s.listener_title, Map.get(s.watch || %{}, "titles", [])} end)
  rescue
    _ -> %{}
  end

  def list_messages(session_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    Message
    |> where(session_id: ^session_id)
    |> order_by(asc: :sequence)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  This session's newest `limit` stored messages (payloads), NEWEST FIRST, as a
  Room's replay buffer holds them, stream fragments excluded as the buffer
  excludes them. A Room starting fresh (a server restart, or a Room stopped
  and started again) seeds its buffer from this, or a viewer joining after a
  restart was replayed only what arrived since (measured 2026-10-05 by the
  desktop app: after the 08:20Z swap, session 204013 replayed from 08:20 on).
  """
  @agent_types ~w(agent_started agent_message agent_turn_complete agent_ended agents)

  def recent_payloads(session_id, limit) do
    from(m in Message,
      where: m.session_id == ^session_id and m.type not in ["stream_event", "background_tasks"] and m.type not in @agent_types,
      order_by: [desc: m.sequence],
      limit: ^limit,
      select: {m.payload, m.inserted_at}
    )
    |> Repo.all()
    |> Enum.map(&timed_payload/1)
  end

  @doc "A seat's newest `limit` agent_* rows (Room's agent buffer, newest first)."
  def recent_agent_payloads(session_id, limit) do
    from(m in Message,
      where: m.session_id == ^session_id and m.type in @agent_types,
      order_by: [desc: m.sequence],
      limit: ^limit,
      select: {m.payload, m.inserted_at}
    )
    |> Repo.all()
    |> Enum.map(&timed_payload/1)
  end

  # A row stored before the Room stamped arrival times reads its stored time.
  defp timed_payload({payload, inserted_at}),
    do: stamp_time(payload, NaiveDateTime.to_iso8601(inserted_at) <> "Z")

  @doc """
  Puts `iso` as a row's "timestamp" when it has none, and on an agent_message's
  inner row too. The apps read each row's time from "timestamp" (ISO-8601):
  the patched runtime's sidecar sent Claude Code's own, the mod's rows carry
  none, so a stock seat showed no message times and no day dividers (measured
  2026-10-09 by the apps on standalone-bob). A row's own time always wins.
  """
  def stamp_time(%{} = row, iso) do
    row = Map.put_new(row, "timestamp", iso)

    case row do
      %{"type" => "agent_message", "message" => %{} = inner} -> %{row | "message" => Map.put_new(inner, "timestamp", iso)}
      _ -> row
    end
  end

  def stamp_time(row, _iso), do: row

  @doc "The seat's agent list as the mod last reported it (an `agents` row), else []."
  def latest_agents(session_id) do
    from(m in Message,
      where: m.session_id == ^session_id and m.type == "agents",
      order_by: [desc: m.sequence],
      limit: 1,
      select: m.payload
    )
    |> Repo.one()
    |> case do
      %{"agents" => agents} when is_list(agents) -> agents
      _ -> []
    end
  end

  @doc "The seat's background work as the mod last reported it (a `background_tasks` row), else []."
  def latest_background_tasks(session_id) do
    from(m in Message,
      where: m.session_id == ^session_id and m.type == "background_tasks",
      order_by: [desc: m.sequence],
      limit: 1,
      select: m.payload
    )
    |> Repo.one()
    |> case do
      %{"tasks" => tasks} when is_list(tasks) -> tasks
      _ -> []
    end
  end

  @doc """
  The conversation a resumed seat continues, as it ran on earlier rows:
  the newest `limit` mirrored messages (payloads, oldest first) of this
  user's earlier rows for the same conversation. A seat resumed with
  `claude --resume` lands on a new row (it reports a placeholder session
  id), so its own replay starts empty although the seat remembers
  everything. `[]` for a row that is not a resumed seat (no conversation_id).
  """
  def earlier_conversation(session_id, limit \\ 500) do
    case Repo.get(Session, session_id) do
      %Session{conversation_id: conv, user_id: uid} when is_binary(conv) ->
        from(s in Session,
          where: s.user_id == ^uid and s.id < ^session_id and s.type != :proxy and
                   (s.claude_session_id == ^conv or s.conversation_id == ^conv),
          order_by: [desc: s.id],
          select: s.id
        )
        |> Repo.all()
        |> newest_payloads(limit, [])

      _ ->
        []
    end
  end

  # Newest row first, each from its newest message back, until `left` is used
  # up: one indexed (session_id, sequence) read per earlier row.
  defp newest_payloads([], _left, acc), do: acc
  defp newest_payloads(_ids, left, acc) when left <= 0, do: acc

  defp newest_payloads([id | older], left, acc) do
    payloads =
      # Stream fragments stay out of replay (see Room's buffer).
      from(m in Message, where: m.session_id == ^id and m.type != "stream_event", order_by: [desc: m.sequence], limit: ^left, select: m.payload)
      |> Repo.all()
      |> Enum.reverse()

    newest_payloads(older, left - length(payloads), payloads ++ acc)
  end

  def next_sequence(session_id) do
    result =
      Message
      |> where(session_id: ^session_id)
      |> select([m], max(m.sequence))
      |> Repo.one()

    (result || 0) + 1
  end
end
