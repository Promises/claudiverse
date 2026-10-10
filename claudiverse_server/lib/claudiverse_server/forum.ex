defmodule ClaudiverseServer.Forum do
  @moduledoc """
  Persistent, DB-backed discussion forum for the agent fleet.

  Channels hold threaded posts; agents read/search by pull (no alert) and may
  opt in to a channel to get new-post pings. Those pings are delivered through
  the EXISTING `Notifications.Router` idle path — `create_post/1` looks up the
  channel's subscribers and hands their titles to `Router.forum_post/2`, which
  queues a compact ping per subscriber and flushes it when that agent next goes
  idle (exactly like `idle`/`report`/`compact` pings). No parallel alert system.

  Search uses SQLite FTS5 (`forum_posts_fts`, kept in sync by triggers) and
  falls back to `LIKE` if FTS5 is unavailable.
  """
  import Ecto.Query

  alias ClaudiverseServer.Repo
  alias ClaudiverseServer.Forum.{Channel, Post, Subscription, Handoff}
  alias ClaudiverseServer.Forum.Handoff.Version, as: HandoffVersion
  alias ClaudiverseServer.Notifications.Router

  @default_read_limit 20
  @max_read_limit 50
  @default_search_limit 15
  # Distinct terms a forum search may carry. Every term becomes an OR'd PREFIX
  # term, and cost grows faster than linearly with their number. MEASURED
  # 2026-09-28 on a copy of the live forum (28,207 posts, 91 MB): 10 terms
  # 0.05 s, 40 → 0.35 s, 120 → 1.9 s, 300 → 9.1 s. One search ran 253 s in
  # production at 10:23 UTC and held a DB connection the whole time; every
  # other request queued behind it (a message INSERT waited 208 s) and the
  # server read as down. Real searches use a handful of distinctive words.
  @max_search_terms 24
  @max_search_limit 30

  # --- Channels --------------------------------------------------------------

  @doc "All channels, alphabetical by slug."
  def list_channels do
    Channel |> order_by(asc: :slug) |> Repo.all()
  end

  def get_channel(id), do: Repo.get(Channel, id)

  def get_channel_by_slug(slug) when is_binary(slug) do
    # Tolerate a leading "#" (agents naturally write "#ipsum-general"): strip it so
    # "#ipsum-general" resolves to the stored bare slug "ipsum-general".
    norm = slug |> String.trim() |> String.trim_leading("#") |> String.trim() |> String.downcase()
    Repo.get_by(Channel, slug: norm)
  end

  def get_channel_by_slug(_), do: nil

  def create_channel(attrs) do
    %Channel{}
    |> Channel.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetch a channel by slug, creating it from `attrs` if it doesn't exist."
  def get_or_create_channel(slug, attrs \\ %{}) do
    case get_channel_by_slug(slug) do
      nil ->
        create_channel(Map.merge(%{slug: slug, title: slug}, attrs))

      channel ->
        {:ok, channel}
    end
  end

  # --- Posts -----------------------------------------------------------------

  @doc """
  Create a post. Accepts `:channel_id` or `:channel` (slug). If `:parent_id` is
  given, the parent's thread root (or the parent itself) becomes this post's
  thread root.

  On success it (a) auto-subscribes the author to the post's THREAD (so it hears
  follow-ups without manual subscribing), then (b) enqueues new-post pings via
  `Notifications.Router`:

    * a new TOP-LEVEL post pings the CHANNEL subscribers of its channel;
    * a new REPLY pings the THREAD subscribers of its thread root.

  The author is never pinged about its own post.
  """
  def create_post(attrs) do
    attrs = normalize_post_attrs(attrs)

    with {:ok, attrs} <- resolve_thread_root(attrs),
         {:ok, post} <- do_insert_post(attrs) do
      auto_subscribe_author(post)
      notify_subscribers(post)
      {:ok, post}
    end
  end

  defp do_insert_post(attrs) do
    %Post{}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  # Accept a string/atom-keyed map; map a `:channel` slug to `:channel_id`.
  defp normalize_post_attrs(attrs) do
    attrs = for {k, v} <- attrs, into: %{}, do: {to_string(k), v}

    case {attrs["channel_id"], attrs["channel"]} do
      {nil, slug} when is_binary(slug) ->
        case get_channel_by_slug(slug) do
          nil -> attrs
          ch -> Map.put(attrs, "channel_id", ch.id)
        end

      _ ->
        attrs
    end
    |> Map.drop(["channel"])
  end

  # A reply inherits its parent's thread root (or the parent becomes the root).
  #
  # ⛔ A reply must be in its parent's channel. Task ids and knowledge-store ids
  # are separate integer sequences that collide with forum post ids, so a caller
  # that passes one as parent_id lands its post under an unrelated thread.
  # MEASURED 2026-10-02: 279 lorem-fleet posts sat in ipsum-* channels this way. Refusing a
  # cross-channel reply turns that silent misfile into a loud error whenever the
  # caller named the channel it meant.
  defp resolve_thread_root(attrs) do
    case attrs["parent_id"] do
      nil ->
        {:ok, attrs}

      parent_id ->
        channel_id = attrs["channel_id"]

        case Repo.get(Post, parent_id) do
          nil ->
            {:error, :parent_not_found}

          %Post{channel_id: pch} when not is_nil(pch) and pch != channel_id ->
            slug =
              case get_channel(pch) do
                %Channel{slug: s} -> s
                _ -> to_string(pch)
              end

            {:error, {:parent_in_other_channel, slug}}

          parent ->
            root_id = parent.thread_root_id || parent.id
            {:ok, Map.put(attrs, "thread_root_id", root_id)}
        end
    end
  end

  def get_post(id), do: Repo.get(Post, id)

  @doc """
  The thread root id of a post: itself when it's top-level (`parent_id` nil),
  otherwise its `thread_root_id`. The single source of truth for "which thread".
  """
  def thread_root_id_of(%Post{parent_id: nil, id: id}), do: id
  def thread_root_id_of(%Post{thread_root_id: root_id}) when not is_nil(root_id), do: root_id
  def thread_root_id_of(%Post{parent_id: parent_id}), do: parent_id

  @doc """
  List posts in a channel, pinned-first then newest-first, bounded. Opts:
    * `:limit`            — capped at #{@max_read_limit} (default #{@default_read_limit})
    * `:before`           — only posts with id < this (keyset pagination)
    * `:top_level`        — when truthy, only top-level posts (no replies). The
                            compact "what's the board" view.
    * `:status`           — keep only posts with this status (e.g. `"active"`).
    * `:owner`            — keep only posts assigned to this owner title.
    * `:include_archived` — when truthy, also return archived (soft-hidden) posts.
                            Default: archived posts are excluded.

  Pinned posts (non-nil `pinned_at`) always sort ahead of the rest. Existing
  callers passing only `:limit`/`:before` are unaffected: with no archived or
  pinned rows the result order/content is identical to before.
  """
  def list_posts(%Channel{id: channel_id}, opts \\ []) do
    limit = clamp(Keyword.get(opts, :limit, @default_read_limit), @max_read_limit)
    before = Keyword.get(opts, :before)
    status = Keyword.get(opts, :status)
    owner = Keyword.get(opts, :owner)

    Post
    |> where(channel_id: ^channel_id)
    |> then(fn q -> if before, do: where(q, [p], p.id < ^before), else: q end)
    |> then(fn q -> if truthy(opts[:top_level]), do: where(q, [p], is_nil(p.parent_id)), else: q end)
    |> then(fn q -> if status, do: where(q, [p], p.status == ^status), else: q end)
    |> then(fn q -> if owner, do: where(q, [p], p.owner == ^owner), else: q end)
    |> then(fn q ->
      if truthy(opts[:include_archived]), do: q, else: where(q, [p], is_nil(p.archived_at))
    end)
    |> then(fn q ->
      # Pinned-first ONLY for board/compact (top_level) reads, so a plain
      # `read limit:N` returns the latest N by recency instead of pinned anchors
      # crowding the window. The board view still shows pins on top.
      if truthy(opts[:top_level]),
        do: order_by(q, [p], asc: fragment("CASE WHEN ? IS NULL THEN 1 ELSE 0 END", p.pinned_at)),
        else: q
    end)
    |> order_by([p], desc: p.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(1), do: true
  defp truthy("1"), do: true
  defp truthy(_), do: false

  # --- Post mutations (the work-tracker surface) -----------------------------
  #
  # All mutations are by post id and return {:ok, post} | {:error, reason}. They
  # are cooperative: any authenticated fleet member may edit/archive/pin/etc. (the
  # fleet shares one account — identity is the `author`/`self` title, not a DB
  # user). The HTTP layer enforces the Bearer auth; see ForumController.

  @doc """
  Edit a post in place. `attrs` may carry any of `title`, `body`, `status`,
  `owner` (and, used by the dedicated helpers below, `pinned_at`/`archived_at`).
  Author, channel and threading are immutable.
  """
  def update_post(%Post{} = post, attrs) do
    post
    |> Post.update_changeset(stringify_keys(attrs))
    |> Repo.update()
  end

  def update_post(id, attrs) do
    case get_post(id) do
      nil -> {:error, :not_found}
      post -> update_post(post, attrs)
    end
  end

  @doc "Set a post's status (`incoming`/`active`/`done`, or nil to clear)."
  def set_status(id, status), do: update_post(id, %{"status" => status})

  @doc """
  Assign (or clear, with nil) a post's owner. When the owner CHANGES to a new
  non-nil title, the new owner is pinged (via `Notifications.Router`) that work
  was assigned to it — unless `actor` (the agent doing the assigning) IS the new
  owner. This is targeted: a worker learns of work assigned to it WITHOUT being
  subscribed to the whole channel. Clearing the owner (nil) never pings.
  """
  def assign_post(id, owner, actor \\ nil) do
    case get_post(id) do
      nil ->
        {:error, :not_found}

      %Post{owner: prev_owner} = post ->
        case update_post(post, %{"owner" => owner}) do
          {:ok, updated} ->
            notify_owner_assignment(updated, prev_owner, actor)
            {:ok, updated}

          other ->
            other
        end
    end
  end

  @doc """
  ATOMICALLY claim an UNOWNED post. Returns `{:ok, post}` to exactly one caller;
  every other concurrent caller gets `{:error, {:already_claimed, holder}}`.

  ## Why this exists, and why `assign_post/3` cannot be used for claiming

  `assign_post/3` is READ-THEN-WRITE with no condition, which is correct for its
  job (a manager *reassigning* work) and unsafe for claiming. Two runners racing
  for one task BOTH succeed there, and the read-back verification that follows
  cannot catch it: the loser reads back before the winner overwrites, sees its
  own name, and proceeds. Measured 2026-08-16 — `ipsum-w5` and `ipsum-w7` both ran task
  12467 to completion, on a task that creates records and sends mail.

  A TOCTOU race cannot be closed on the client. No amount of re-reading, delay or
  double-checking helps; it only shrinks the window. The check and the write have
  to be the same statement, which means it has to happen here.

  `update_all` with `is_nil(p.owner)` in the WHERE compiles to a single
  `UPDATE … WHERE id = $1 AND owner IS NULL`, and the returned count IS the
  verdict — no follow-up read can disagree with it.

  ⚠️ This repo is SQLite (`Ecto.Adapters.SQLite3`), not Postgres. The guarantee
  still holds and is simpler: SQLite serialises writers, so the second UPDATE
  runs after the first commits, sees a non-nil owner, and matches zero rows.

  If `busy_timeout` is too low the loser may get `SQLITE_BUSY` instead of a
  clean zero. That surfaces to the client as a THROW, and `cv-runner` treats a
  throw as "we do not know" — skip and retry next poll — never as "won". So the
  degraded path fails toward not-claiming, which is the safe direction.
  """
  def claim_post(id, owner, actor \\ nil) when is_binary(owner) and owner != "" do
    {count, _} =
      Post
      |> where([p], p.id == ^id and is_nil(p.owner))
      |> Repo.update_all(set: [owner: owner, updated_at: now()])

    case count do
      1 ->
        post = get_post(id)
        # prev_owner is nil by construction — we only matched an unowned row.
        notify_owner_assignment(post, nil, actor)
        {:ok, post}

      0 ->
        # Zero rows means one of two things and the caller must be able to tell
        # them apart: the post does not exist, or somebody else holds it.
        case get_post(id) do
          nil -> {:error, :not_found}
          %Post{owner: holder} -> {:error, {:already_claimed, holder}}
        end
    end
  end

  @doc "Pin a post to the top of its channel (idempotent)."
  def pin_post(id), do: update_post(id, %{"pinned_at" => now()})

  @doc "Remove a pin."
  def unpin_post(id), do: update_post(id, %{"pinned_at" => nil})

  @doc "Soft-hide a post: excluded from default reads, recoverable via unarchive."
  def archive_post(id), do: update_post(id, %{"archived_at" => now()})

  @doc "Restore a soft-hidden post to the board."
  def unarchive_post(id), do: update_post(id, %{"archived_at" => nil})

  @doc """
  Resolve a task: mark it `done` AND archive it in one step, so the record is
  kept but it drops off the active board. Distinct from `delete_post/1` (which
  removes the record) and from a bare `status: "done"` (which stays visible).
  """
  def resolve_post(id), do: update_post(id, %{"status" => "done", "archived_at" => now()})

  @doc """
  Hard-delete a post. If it is a top-level post, the whole thread (the root plus
  all its replies) is removed; deleting a single reply removes just that reply.
  Returns `{:ok, count}` (rows deleted) or `{:error, :not_found}`.
  """
  def delete_post(id) do
    case get_post(id) do
      nil ->
        {:error, :not_found}

      %Post{parent_id: nil, id: root_id} ->
        {n, _} =
          Repo.delete_all(
            from p in Post, where: p.id == ^root_id or p.thread_root_id == ^root_id
          )

        {:ok, n}

      %Post{} = reply ->
        case Repo.delete(reply) do
          {:ok, _} -> {:ok, 1}
          {:error, _} = err -> err
        end
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp stringify_keys(attrs) do
    for {k, v} <- attrs, into: %{}, do: {to_string(k), v}
  end

  @doc """
  Reply counts for a list of top-level post ids, as a `%{root_id => count}` map
  (ids with no replies are absent). One grouped query — used by the compact board
  read to show how busy each thread is without loading the replies.
  """
  def reply_counts([]), do: %{}

  def reply_counts(root_ids) when is_list(root_ids) do
    Post
    |> where([p], p.thread_root_id in ^root_ids)
    |> group_by([p], p.thread_root_id)
    |> select([p], {p.thread_root_id, count(p.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc "All posts in a thread (the root + its replies), oldest first."
  def list_thread(root_id) do
    Post
    |> where([p], p.id == ^root_id or p.thread_root_id == ^root_id)
    |> order_by(asc: :id)
    |> Repo.all()
  end

  @doc "Build the stable permalink for a post."
  def permalink(%Post{id: id} = post) do
    "forum/#{slug_for_post(post)}/#{id}"
  end

  # The channel association may not be loaded — fall back to a slug lookup.
  defp slug_for_post(%Post{channel: %Channel{slug: slug}}), do: slug

  defp slug_for_post(%Post{channel_id: channel_id}) do
    case get_channel(channel_id) do
      %Channel{slug: slug} -> slug
      _ -> to_string(channel_id)
    end
  end

  # --- Search ----------------------------------------------------------------

  @doc """
  Full-text search over post bodies (FTS5, LIKE fallback). Returns a list of
  `%{id, channel_id, channel_slug, author, snippet, inserted_at}` maps, most
  relevant first. Opts: `:limit` (capped #{@max_search_limit}), `:channel`
  (restrict to a channel slug).
  """
  @doc "The distinct terms a forum search query carries (case-insensitive, like the FTS tokenizer)."
  def search_terms(query) when is_binary(query) do
    query
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
  end

  @doc "The most distinct terms a forum search accepts; see @max_search_terms."
  def max_search_terms, do: @max_search_terms

  def search(query, opts \\ []) when is_binary(query) do
    limit = clamp(Keyword.get(opts, :limit, @default_search_limit), @max_search_limit)
    channel_id = channel_id_for(Keyword.get(opts, :channel))

    case fts_search(query, limit, channel_id) do
      {:ok, rows} -> rows
      :unavailable -> like_search(query, limit, channel_id)
    end
  end

  defp channel_id_for(nil), do: nil

  defp channel_id_for(slug) do
    case get_channel_by_slug(slug) do
      nil -> nil
      ch -> ch.id
    end
  end

  # FTS5 path, in TWO steps: (1) rank the matches with the FTS table evaluated
  # once (a MATERIALIZED CTE), then join back to posts and filter by channel;
  # (2) build snippets for only the <= limit rows returned.
  #
  # ⛔ The single-statement form (MATCH + channel filter + ORDER BY rank +
  # snippet in one SELECT) let the planner walk posts and re-evaluate the MATCH
  # per row. MEASURED 2026-10-02 on a scratch copy of the live forum (30,113
  # posts): `"func_0029"*` in one channel took 107 s that way and 0 s in this
  # form, returning the same ids in the same order; on the live server one such
  # search held a core for 150.9 s. Each piece alone (match, rank, channel
  # filter) was fast; only the combination was not.
  defp fts_search(query, limit, channel_id) do
    match = to_fts_match(query)

    if match == "" do
      {:ok, []}
    else
      {sql, params} = fts_ranked_sql(match, limit, channel_id)

      try do
        %{rows: ranked} = Repo.query!(sql, params)
        snippets = fts_snippets(match, Enum.map(ranked, &hd/1))

        {:ok,
         Enum.map(ranked, fn [id, ch, slug, author, inserted_at] ->
           row_to_result([id, ch, slug, author, Map.get(snippets, id), inserted_at])
         end)}
      rescue
        _ -> :unavailable
      end
    end
  end

  defp fts_ranked_sql(match, limit, channel_id) do
    {channel_clause, channel_params} =
      if channel_id, do: {"WHERE p.channel_id = ?", [channel_id]}, else: {"", []}

    sql = """
    WITH m AS MATERIALIZED (
      SELECT rowid AS id, rank AS r FROM forum_posts_fts WHERE forum_posts_fts MATCH ?
    )
    SELECT p.id, p.channel_id, c.slug, p.author, p.inserted_at
    FROM m
    JOIN forum_posts p ON p.id = m.id
    JOIN forum_channels c ON c.id = p.channel_id
    #{channel_clause}
    ORDER BY m.r
    LIMIT ?
    """

    {sql, [match] ++ channel_params ++ [limit]}
  end

  defp fts_snippets(_match, []), do: %{}

  defp fts_snippets(match, ids) do
    placeholders = Enum.map_join(ids, ", ", fn _ -> "?" end)

    sql = """
    SELECT rowid, snippet(forum_posts_fts, 0, '[', ']', '…', 16)
    FROM forum_posts_fts
    WHERE forum_posts_fts MATCH ? AND rowid IN (#{placeholders})
    """

    %{rows: rows} = Repo.query!(sql, [match | ids])
    Map.new(rows, fn [id, snip] -> {id, snip} end)
  end

  # Turn freeform text into a safe FTS5 MATCH expression: tokenize, QUOTE each
  # term, and OR them as prefixes (`"term"*`). OR (not implicit AND) so a
  # multi-word / natural-language query matches posts containing ANY term, ranked
  # by relevance — implicit AND required EVERY word present, so long queries
  # matched nothing.
  #
  # 🔴 THIS USED TO STRIP NON-ALNUM CHARACTERS *INSIDE* THE TERM, AND THAT MADE
  # EVERY IDENTIFIER UNFINDABLE. `bb_application` became `bbapplication*` — a
  # string that was never indexed, because FTS5's default tokenizer had already
  # split the body into `bb` and `application`. So the search returned a CLEAN
  # ZERO on text that provably contained the term, which is the single worst
  # failure a search can have: absence is what closes an investigation.
  #
  # Measured on the live corpus before the fix:
  #   "func_002933D0"  -> 0 hits
  #   "func 002933D0"  -> 3 hits, THE SAME POSTS      <- the data was always there
  #   "0x00115484"     -> 2 hits (pure alnum, nothing to strip, so it worked)
  #
  # The old comment said alnum-stripping "avoids FTS5 syntax errors". That hazard
  # is REAL — a bare `.` in a query raises `fts5: syntax error` — but stripping
  # destroys the token to dodge it. QUOTING escapes it instead, which is what
  # FTS5 provides for exactly this. Verified equivalent-or-better on every form:
  #   '"class.socommon.inc.php"'         -> 1     '"func_002933D0"'  -> 1
  #   '"bb_application"*'                -> 1     '"bb_appl"*'       -> 1  (prefix kept)
  #   '"bb_application"* OR "writers"*'  -> 2     (OR prose semantics unchanged)
  #
  # ⚠️ Default tokenizer, so NO MIGRATION AND NO REINDEX. A `tokenchars` change
  # would need both and STILL fails on a bare `.` without quoting — strictly worse.
  #
  # `"` is escaped by doubling, per FTS5 string literals. That is also what keeps
  # this injection-safe now that punctuation reaches the expression at all.
  defp to_fts_match(query) do
    # De-duplicated: a repeated word would pay its prefix expansion again.
    query
    |> search_terms()
    |> Enum.map(&("\"" <> String.replace(&1, "\"", "\"\"") <> "\"*"))
    |> Enum.join(" OR ")
  end

  defp row_to_result([id, channel_id, slug, author, snippet, inserted_at]) do
    %{
      id: id,
      channel_id: channel_id,
      channel_slug: slug,
      author: author,
      snippet: snippet,
      inserted_at: inserted_at
    }
  end

  # Fallback when FTS5 isn't compiled in: case-insensitive substring on the body.
  defp like_search(query, limit, channel_id) do
    # ⚠️ ESCAPE the LIKE wildcards, do not DELETE them. The previous version
    # stripped `_` and `%`, so `MAIL_TO_DISK` became `MAILTODISK` and matched
    # nothing — an identifier search that silently returns zero, which is the
    # single worst failure this corpus can have (a wrong query and a true
    # negative are the same observable).
    #
    # Dormant in practice: this path only runs when FTS is unavailable, and FTS
    # currently handles these queries. It bites exactly when things are already
    # degraded, which is the worst time to lose identifier search.
    escaped = String.replace(query, ~r/([\\%_])/, "\\\\\\1")
    like = "%" <> escaped <> "%"

    Post
    |> join(:inner, [p], c in Channel, on: c.id == p.channel_id)
    |> where([p], fragment("? LIKE ? ESCAPE '\\'", p.body, ^like))
    |> then(fn q -> if channel_id, do: where(q, [p], p.channel_id == ^channel_id), else: q end)
    |> order_by([p], desc: p.id)
    |> limit(^limit)
    |> select([p, c], %{
      id: p.id,
      channel_id: p.channel_id,
      channel_slug: c.slug,
      author: p.author,
      snippet: fragment("substr(?, 1, 160)", p.body),
      inserted_at: p.inserted_at
    })
    |> Repo.all()
  end

  # --- Subscriptions ---------------------------------------------------------

  @doc """
  Opt `subscriber_title` in to a channel's new-post pings (channel-scoped:
  new TOP-LEVEL posts only). Idempotent. If a live `session_id` is known, the
  Router binds it immediately so the very next post can be delivered on idle;
  otherwise it's bound on the agent's next idle. Returns `{:ok, subscription}` or
  `{:error, :no_channel}`.
  """
  def subscribe(channel_slug, subscriber_title, session_id \\ nil) do
    case get_channel_by_slug(channel_slug) do
      nil ->
        {:error, :no_channel}

      channel ->
        result = insert_subscription(channel.id, subscriber_title, nil)
        Router.forum_subscribe(subscriber_title, session_id)
        result
    end
  end

  @doc """
  Opt `subscriber_title` in to a single THREAD's reply pings (thread-scoped).
  `post_id` may be any post in the thread; it is normalized to the thread root.
  Idempotent. Returns `{:ok, subscription}` or `{:error, :post_not_found}`.
  """
  def subscribe_thread(post_id, subscriber_title, session_id \\ nil) do
    case get_post(post_id) do
      nil ->
        {:error, :post_not_found}

      %Post{} = post ->
        result = insert_subscription(post.channel_id, subscriber_title, thread_root_id_of(post))
        Router.forum_subscribe(subscriber_title, session_id)
        result
    end
  end

  # Idempotent insert of a channel (root_id nil) or thread (root_id set) sub.
  defp insert_subscription(channel_id, subscriber_title, root_id) do
    %Subscription{}
    |> Subscription.changeset(%{
      channel_id: channel_id,
      subscriber_title: subscriber_title,
      post_id: root_id
    })
    |> Repo.insert(on_conflict: :nothing)
    |> case do
      {:ok, sub} -> {:ok, sub}
      {:error, _} = err -> err
    end
  end

  @doc "Unsubscribe `subscriber_title` from a channel (channel-scoped sub only)."
  def unsubscribe(channel_slug, subscriber_title) do
    case get_channel_by_slug(channel_slug) do
      nil ->
        {:error, :no_channel}

      channel ->
        {n, _} =
          Repo.delete_all(
            from s in Subscription,
              where:
                s.channel_id == ^channel.id and s.subscriber_title == ^subscriber_title and
                  is_nil(s.post_id)
          )

        {:ok, n}
    end
  end

  @doc "Unsubscribe `subscriber_title` from a thread (by any post id in it)."
  def unsubscribe_thread(post_id, subscriber_title) do
    case get_post(post_id) do
      nil ->
        {:error, :post_not_found}

      %Post{} = post ->
        root_id = thread_root_id_of(post)

        {n, _} =
          Repo.delete_all(
            from s in Subscription,
              where: s.post_id == ^root_id and s.subscriber_title == ^subscriber_title
          )

        {:ok, n}
    end
  end

  @doc """
  Channel-subscriber titles for a channel — the agents pinged on a new TOP-LEVEL
  post. Thread-scoped rows (post_id set) are excluded.
  """
  def list_channel_subscriber_titles(channel_id) do
    Subscription
    |> where([s], s.channel_id == ^channel_id and is_nil(s.post_id))
    |> select([s], s.subscriber_title)
    |> Repo.all()
  end

  @doc """
  Thread-subscriber titles for a thread root — the agents pinged on a new REPLY
  in that thread.
  """
  def list_thread_subscriber_titles(root_id) do
    Subscription
    |> where([s], s.post_id == ^root_id)
    |> select([s], s.subscriber_title)
    |> Repo.all()
  end

  @doc """
  Everything `title` is subscribed to, split by scope:
  `%{channels: [%{slug, title}], threads: [%{post_id, channel_slug, title}]}`.
  Lets a worker audit/prune its own pings.
  """
  def list_subscriptions_for_title(title) do
    subs =
      Subscription
      |> where([s], s.subscriber_title == ^title)
      |> order_by([s], asc: s.id)
      |> Repo.all()
      |> Repo.preload([:channel, post: :channel])

    {thread_subs, channel_subs} = Enum.split_with(subs, &(&1.post_id != nil))

    %{
      channels:
        Enum.map(channel_subs, fn s ->
          %{slug: s.channel && s.channel.slug, title: s.channel && s.channel.title}
        end),
      threads:
        Enum.map(thread_subs, fn s ->
          %{
            post_id: s.post_id,
            channel_slug: s.post && s.post.channel && s.post.channel.slug,
            title: s.post && s.post.title
          }
        end)
    }
  end

  @doc """
  Every distinct agent title that has at least one forum subscription. Used by
  `Notifications.Router` on boot to pre-create listener entries so a restart
  doesn't drop forum delivery (each binds its live session on its next idle).
  """
  def list_all_subscriber_titles do
    Subscription
    |> select([s], s.subscriber_title)
    |> distinct(true)
    |> Repo.all()
  rescue
    _ -> []
  end

  @doc "Channel slugs a given agent title is subscribed to."
  def list_channels_for_title(title) do
    Subscription
    |> join(:inner, [s], c in Channel, on: c.id == s.channel_id)
    |> where([s], s.subscriber_title == ^title)
    |> select([s, c], c.slug)
    |> Repo.all()
  end

  # --- Internal --------------------------------------------------------------

  # A new TOP-LEVEL post → ping the CHANNEL subscribers (new topic/task).
  # A new REPLY → ping the THREAD subscribers of its root (NOT channel subs).
  # The author is always excluded. This audience split is the anti-spam core.
  defp notify_subscribers(%Post{parent_id: nil} = post) do
    post.channel_id
    |> list_channel_subscriber_titles()
    |> Enum.reject(&(&1 == post.author))
    |> ping_forum_post(post)
  end

  defp notify_subscribers(%Post{} = post) do
    post
    |> thread_root_id_of()
    |> list_thread_subscriber_titles()
    |> Enum.reject(&(&1 == post.author))
    |> ping_forum_post(post)
  end

  defp ping_forum_post([], _post), do: :ok

  defp ping_forum_post(titles, %Post{} = post) do
    Router.forum_post(
      %{channel: slug_for_channel(post.channel_id), post_id: post.id, author: post.author},
      titles
    )

    :ok
  end

  # Auto-subscribe the author to its post's THREAD so it hears follow-ups without
  # subscribing manually. Thread-scoped (never a channel sub), idempotent, and
  # binds no Router session (the author is active; it isn't pinged for its own
  # post anyway). Best-effort: a failure here never fails the post.
  defp auto_subscribe_author(%Post{author: author} = post) when is_binary(author) do
    insert_subscription(post.channel_id, author, thread_root_id_of(post))
    :ok
  end

  defp auto_subscribe_author(_post), do: :ok

  # Ping the newly-assigned owner (unless they assigned themselves, or it's a
  # clear / no-op re-assign). Routed through Notifications.Router like forum pings.
  defp notify_owner_assignment(%Post{owner: owner} = post, prev_owner, actor)
       when is_binary(owner) and owner != "" and owner != prev_owner and owner != actor do
    Router.forum_assigned(
      %{
        channel: slug_for_channel(post.channel_id),
        post_id: post.id,
        by: actor,
        title: post.title
      },
      owner
    )

    :ok
  end

  defp notify_owner_assignment(_post, _prev_owner, _actor), do: :ok

  defp slug_for_channel(channel_id) do
    case get_channel(channel_id) do
      %Channel{slug: s} -> s
      _ -> to_string(channel_id)
    end
  end

  defp clamp(n, max) when is_integer(n) and n > 0, do: min(n, max)
  defp clamp(_, max), do: max

  # --- Handoffs (per-agent continuity state) ---------------------------------
  #
  # PULL-ONLY by design. Setting a handoff NEVER touches Notifications.Router —
  # no ping is ever enqueued, so other agents pay zero attention to a role's
  # handoff. A successor reads the ONE canonical current-state on takeover.

  @max_handoff_history 20

  @doc """
  Upsert the canonical current-state for `role` (the caller's own title). One row
  per role: an existing handoff is overwritten in place (NOT appended to a
  scroll), its `version` bumped, and the new body snapshotted into
  `forum_handoff_versions` for cheap history. Done in a transaction so the
  current row and its history snapshot stay consistent.

  Returns `{:ok, %Handoff{}}` or `{:error, changeset}`. Enqueues NO notification.
  """
  def set_handoff(role, body, _opts \\ []) do
    role = if is_binary(role), do: String.trim(role), else: role

    # 🔴 `mode: :immediate` — TAKE THE WRITE LOCK AT BEGIN. This transaction
    # READS (get_by) and then WRITES. Under SQLite's default DEFERRED mode that
    # needs a read->write lock upgrade, and in WAL mode the upgrade fails AT ONCE
    # with SQLITE_BUSY if another connection committed since the read — the busy
    # timeout is never consulted. MEASURED: 24 of 29 "Database busy" errors in
    # 30 h of the live log were this INSERT, each 4–7 ms after its request began,
    # and every one stranded a worker at its final handoff. IMMEDIATE acquires the
    # lock up front, where a contended lock DOES wait. Raising busy_timeout alone
    # would not have helped.
    Repo.transaction(fn ->
      existing = role && Repo.get_by(Handoff, role: role)
      next_version = if existing, do: existing.version + 1, else: 1

      result =
        (existing || %Handoff{})
        |> Handoff.changeset(%{role: role, body: body, version: next_version})
        |> Repo.insert_or_update()

      case result do
        {:ok, handoff} ->
          snapshot_handoff_version(handoff)
          handoff

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end, mode: :immediate)
  end

  defp snapshot_handoff_version(%Handoff{role: role, body: body, version: version}) do
    %HandoffVersion{}
    |> HandoffVersion.changeset(%{role: role, body: body, version: version})
    |> Repo.insert()
  end

  @doc "Fetch the canonical current-state for `role` (nil if none). Used on takeover."
  def get_handoff(role) when is_binary(role) do
    Repo.get_by(Handoff, role: String.trim(role))
  end

  def get_handoff(_), do: nil

  @doc "All current handoffs (one per role), most-recently-updated first."
  def list_handoffs do
    Handoff |> order_by(desc: :updated_at, desc: :id) |> Repo.all()
  end

  @doc """
  Historical snapshots for `role`, newest version first, bounded
  (#{@max_handoff_history}). Lets a successor inspect how the state evolved.
  """
  def list_handoff_history(role, opts \\ []) when is_binary(role) do
    limit = clamp(Keyword.get(opts, :limit, @max_handoff_history), @max_handoff_history)

    HandoffVersion
    |> where(role: ^String.trim(role))
    |> order_by(desc: :version)
    |> limit(^limit)
    |> Repo.all()
  end
end
