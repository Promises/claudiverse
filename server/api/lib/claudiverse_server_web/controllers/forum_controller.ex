defmodule ClaudiverseServerWeb.ForumController do
  @moduledoc """
  HTTP surface for the agent discussion forum (mirrors `/api/notify/*`).

  Reading and searching are pure pull — no subscription, no alert. Subscribing
  opts an agent (by title) in to new-post pings, delivered through
  `Notifications.Router`'s existing idle path. The MCP `cv_forum_*` tools wrap
  these endpoints.
  """
  use ClaudiverseServerWeb, :controller

  alias ClaudiverseServer.{Forum, Sessions}

  # GET /api/forum/channels
  def channels(conn, _params) do
    channels =
      Forum.list_channels()
      |> Enum.map(&channel_json/1)

    json(conn, %{channels: channels})
  end

  # POST /api/forum/channels  %{"slug" => , "title" => , "description" => }
  def create_channel(conn, params) do
    attrs = Map.take(params, ["slug", "title", "description"])

    case Forum.create_channel(attrs) do
      {:ok, channel} ->
        json(conn, %{ok: true, channel: channel_json(channel)})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: errors(changeset)})
    end
  end

  # GET /api/forum/channels/:slug/posts
  #   ?limit= &before=                      bounded paging (existing)
  #   &status=active &owner=ipsum-backend      filter the board
  #   &compact=1  (alias top_level=1)       top-level posts only, no reply bodies
  #   &include_archived=1                   also return soft-hidden posts
  def posts(conn, %{"slug" => slug} = params) do
    case Forum.get_channel_by_slug(slug) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "no channel #{slug}"})

      channel ->
        compact = truthy(params["compact"]) or truthy(params["top_level"])

        opts =
          [
            limit: parse_int(params["limit"]),
            before: parse_int(params["before"]),
            status: presence(params["status"]),
            owner: presence(params["owner"]),
            top_level: compact or truthy(params["top_level"]),
            include_archived: truthy(params["include_archived"])
          ]
          |> Enum.reject(fn {_k, v} -> is_nil(v) or v == false end)

        posts = Forum.list_posts(channel, opts)

        rendered =
          if compact do
            counts = posts |> Enum.map(& &1.id) |> Forum.reply_counts()
            Enum.map(posts, &compact_json(&1, channel.slug, Map.get(counts, &1.id, 0)))
          else
            Enum.map(posts, &post_json(&1, channel.slug))
          end

        json(conn, %{channel: channel.slug, compact: compact, posts: rendered})
    end
  end

  # GET /api/forum/posts/:id
  #   ?thread=1  (alias replies=1)  — also include the post's replies (the whole
  #                                   thread when :id is a top-level post).
  def show(conn, %{"id" => id} = params) do
    case Forum.get_post(parse_int(id)) do
      nil ->
        not_found_post(conn, id)

      post ->
        slug = slug_for(post)
        want_thread = truthy(params["thread"]) or truthy(params["replies"])

        base = %{post: post_json(post, slug)}

        payload =
          if want_thread do
            root_id = Forum.thread_root_id_of(post)
            replies = Forum.list_thread(root_id) |> Enum.reject(&(&1.id == post.id))
            Map.put(base, :replies, Enum.map(replies, &post_json(&1, slug)))
          else
            base
          end

        json(conn, payload)
    end
  end

  # POST /api/forum/posts  %{"self" => author, "channel" => slug, "body" => , "parent_id" => }
  def create_post(conn, params) do
    author = params["self"] || params["author"]
    channel = params["channel"]
    body = params["body"]

    cond do
      blank?(author) ->
        conn |> put_status(:bad_request) |> json(%{error: "missing self (author title)"})

      blank?(channel) ->
        conn |> put_status(:bad_request) |> json(%{error: "missing channel"})

      blank?(body) ->
        conn |> put_status(:bad_request) |> json(%{error: "missing body"})

      is_nil(Forum.get_channel_by_slug(channel)) ->
        conn |> put_status(:not_found) |> json(%{error: "no channel #{channel}"})

      true ->
          attrs =
            %{
              "channel" => channel,
              "author" => author,
              "body" => body,
              "parent_id" => parse_int(params["parent_id"]),
              "title" => presence(params["title"]),
              "status" => presence(params["status"]),
              "owner" => presence(params["owner"])
            }
            |> Enum.reject(fn {_k, v} -> is_nil(v) end)
            |> Map.new()

          case Forum.create_post(attrs) do
            {:ok, post} ->
              json(conn, %{ok: true, post: post_json(post, channel)})

            {:error, :parent_not_found} ->
              conn |> put_status(:not_found) |> json(%{error: "parent post not found"})

            {:error, {:parent_in_other_channel, parent_slug}} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{
                error:
                  "parent post #{attrs["parent_id"]} is in ##{parent_slug}, not ##{channel} — " <>
                    "a reply must be posted in its parent's channel (is that id really a forum post?)"
              })

            {:error, changeset} ->
              conn |> put_status(:unprocessable_entity) |> json(%{error: errors(changeset)})
          end
      end
    end

    # GET /api/forum/search?q=&channel=&limit=
    def search(conn, params) do
      q = params["q"] || params["query"] || ""

      n_terms = if blank?(q), do: 0, else: length(Forum.search_terms(q))

      cond do
        blank?(q) ->
          conn |> put_status(:bad_request) |> json(%{error: "missing q"})

        # A long query is refused, not truncated: silently searching the first N
        # words would return a confident answer to a different question.
        n_terms > Forum.max_search_terms() ->
          conn
          |> put_status(:bad_request)
          |> json(%{
            error:
              "query has #{n_terms} distinct terms; the most a forum search accepts is " <>
                "#{Forum.max_search_terms()}. Every term is an OR'd prefix match and cost grows faster " <>
                "than linearly, so a pasted paragraph can stall the whole server. Search for a few " <>
                "distinctive words or identifiers instead.",
            terms: n_terms,
            max_terms: Forum.max_search_terms()
          })

        true ->
        opts =
          [limit: parse_int(params["limit"]), channel: params["channel"]]
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)

        results =
          q
          |> Forum.search(opts)
          |> Enum.map(fn r ->
            %{
              id: r.id,
              channel: r.channel_slug,
              author: r.author,
              snippet: r.snippet,
              permalink: "forum/#{r.channel_slug}/#{r.id}",
              inserted_at: r.inserted_at
            }
          end)

        json(conn, %{query: q, results: results})
    end
  end

  # POST /api/forum/subscribe  %{"self" => title, "channel" => slug | "post_id" => id}
  #   channel-scoped (no post_id): pinged on new TOP-LEVEL posts in the channel.
  #   thread-scoped (post_id set):  pinged on new replies in that post's thread.
  def subscribe(conn, params) do
    user = conn.assigns.current_user
    self_title = params["self"]
    channel = params["channel"]
    post_id = parse_int(params["post_id"])

    cond do
      blank?(self_title) ->
        conn |> put_status(:bad_request) |> json(%{error: "missing self"})

      is_nil(post_id) and blank?(channel) ->
        conn |> put_status(:bad_request) |> json(%{error: "missing channel or post_id"})

      true ->
        session_id = resolve_session_id(user.id, self_title)

        result =
          if post_id,
            do: Forum.subscribe_thread(post_id, self_title, session_id),
            else: Forum.subscribe(channel, self_title, session_id)

        case result do
          {:ok, _} when is_integer(post_id) ->
            json(conn, %{ok: true, post_id: post_id, subscriber: self_title})

          {:ok, _} ->
            json(conn, %{ok: true, channel: channel, subscriber: self_title})

          {:error, :no_channel} ->
            conn |> put_status(:not_found) |> json(%{error: "no channel #{channel}"})

          {:error, :post_not_found} ->
            conn |> put_status(:not_found) |> json(%{error: "no post #{post_id}"})
        end
    end
  end

  # POST /api/forum/unsubscribe  %{"self" => title, "channel" => slug | "post_id" => id}
  def unsubscribe(conn, params) do
    self_title = params["self"]
    channel = params["channel"]
    post_id = parse_int(params["post_id"])

    cond do
      blank?(self_title) ->
        conn |> put_status(:bad_request) |> json(%{error: "missing self"})

      is_nil(post_id) and blank?(channel) ->
        conn |> put_status(:bad_request) |> json(%{error: "missing channel or post_id"})

      true ->
        result =
          if post_id,
            do: Forum.unsubscribe_thread(post_id, self_title),
            else: Forum.unsubscribe(channel, self_title)

        case result do
          {:ok, n} -> json(conn, %{ok: true, removed: n})
          {:error, :no_channel} -> conn |> put_status(:not_found) |> json(%{error: "no channel #{channel}"})
          {:error, :post_not_found} -> conn |> put_status(:not_found) |> json(%{error: "no post #{post_id}"})
        end
    end
  end

  # GET /api/forum/subscriptions?self=title  — what THIS agent is subscribed to.
  def subscriptions(conn, params) do
    self_title = params["self"]

    if blank?(self_title) do
      conn |> put_status(:bad_request) |> json(%{error: "missing self"})
    else
      json(conn, Map.put(Forum.list_subscriptions_for_title(self_title), :self, self_title))
    end
  end

  # --- post mutations (work-tracker) -----------------------------------------
  # All require Bearer auth (the :authenticated pipeline). The fleet shares one
  # account, so identity is the `self` title, not the DB user: any authenticated
  # member may edit/archive/pin/resolve/delete a post. Archive is the recoverable
  # soft-hide; delete is the irreversible hard remove — prefer archive.

  # PATCH /api/forum/posts/:id  %{"title"=>, "body"=>, "status"=>, "owner"=>}
  def edit(conn, %{"id" => id} = params) do
    attrs =
      params
      |> Map.take(["title", "body", "status", "owner"])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    update_and_render(conn, parse_int(id), attrs)
  end

  # DELETE /api/forum/posts/:id  — hard remove (whole thread if top-level).
  def delete(conn, %{"id" => id}) do
    case Forum.delete_post(parse_int(id)) do
      {:ok, n} -> json(conn, %{ok: true, deleted: n})
      {:error, :not_found} -> not_found_post(conn, id)
    end
  end

  # POST /api/forum/posts/:id/archive
  def archive(conn, %{"id" => id}), do: mutate(conn, id, &Forum.archive_post/1)
  # POST /api/forum/posts/:id/unarchive
  def unarchive(conn, %{"id" => id}), do: mutate(conn, id, &Forum.unarchive_post/1)
  # POST /api/forum/posts/:id/pin
  def pin(conn, %{"id" => id}), do: mutate(conn, id, &Forum.pin_post/1)
  # POST /api/forum/posts/:id/unpin
  def unpin(conn, %{"id" => id}), do: mutate(conn, id, &Forum.unpin_post/1)
  # POST /api/forum/posts/:id/resolve  — status=done + archive (keeps the record).
  def resolve(conn, %{"id" => id}), do: mutate(conn, id, &Forum.resolve_post/1)

  # POST /api/forum/posts/:id/status  %{"status"=>"active"}
  def set_status(conn, %{"id" => id} = params) do
    update_and_render(conn, parse_int(id), %{"status" => params["status"]})
  end

  # POST /api/forum/posts/:id/assign  %{"owner"=>"ipsum-backend", "self"=>actor}
  #   (omit owner to clear). Setting a new non-nil owner pings that owner —
  #   unless `self` (the assigner) IS the new owner.
  def assign(conn, %{"id" => id} = params) do
    actor = presence(params["self"])

    case Forum.assign_post(parse_int(id), params["owner"], actor) do
      {:ok, post} -> json(conn, %{ok: true, post: post_json(post, slug_for(post))})
      {:error, :not_found} -> not_found_post(conn, id)
      {:error, changeset} -> conn |> put_status(:unprocessable_entity) |> json(%{error: errors(changeset)})
    end
  end

  # POST /api/forum/posts/:id/claim  %{"owner"=>"ipsum-w5-t123", "self"=>slot}
  #   ATOMIC claim of an UNOWNED post. Exactly one concurrent caller gets 200;
  #   the rest get 409 with the title that actually holds it.
  #
  #   409 IS A NORMAL OUTCOME, not an error condition — losing a claim race is
  #   the expected result for all but one runner, and the status code has to say
  #   so unambiguously or the client will retry into the winner. Distinct from
  #   404 (no such post), which means something else entirely.
  def claim(conn, %{"id" => id} = params) do
    actor = presence(params["self"])
    owner = presence(params["owner"])

    if is_nil(owner) do
      conn |> put_status(:bad_request) |> json(%{error: "missing owner"})
    else
      case Forum.claim_post(parse_int(id), owner, actor) do
        {:ok, post} ->
          json(conn, %{ok: true, claimed: true, post: post_json(post, slug_for(post))})

        {:error, {:already_claimed, holder}} ->
          conn
          |> put_status(:conflict)
          |> json(%{ok: false, claimed: false, held_by: holder})

        # Also 409 with held_by null: an older runner reads it as a lost race
        # and skips, which is right for a post that is no longer a task.
        {:error, {:not_claimable, why}} ->
          conn
          |> put_status(:conflict)
          |> json(%{ok: false, claimed: false, held_by: nil, not_claimable: why})

        {:error, :not_found} ->
          not_found_post(conn, id)
      end
    end
  end

  defp mutate(conn, id, fun) do
    case fun.(parse_int(id)) do
      {:ok, post} -> json(conn, %{ok: true, post: post_json(post, slug_for(post))})
      {:error, :not_found} -> not_found_post(conn, id)
      {:error, changeset} -> conn |> put_status(:unprocessable_entity) |> json(%{error: errors(changeset)})
    end
  end

  defp update_and_render(conn, id, attrs) do
    case Forum.update_post(id, attrs) do
      {:ok, post} -> json(conn, %{ok: true, post: post_json(post, slug_for(post))})
      {:error, :not_found} -> not_found_post(conn, id)
      {:error, changeset} -> conn |> put_status(:unprocessable_entity) |> json(%{error: errors(changeset)})
    end
  end

  defp not_found_post(conn, id), do: conn |> put_status(:not_found) |> json(%{error: "no post #{id}"})

  defp slug_for(post) do
    case Forum.get_channel(post.channel_id) do
      %{slug: slug} -> slug
      _ -> to_string(post.channel_id)
    end
  end

  # --- handoffs (per-agent continuity state) ---------------------------------
  # Pull-only: setting a handoff enqueues NO ping. `set` is scoped to the
  # caller's own role (`self`) — an agent cannot overwrite another role's
  # handoff. `get`/`list` are bounded reads used on takeover.

  # POST /api/forum/handoff/set  %{"self" => role, "body" => }
  # The role is ALWAYS the caller's own `self` — there is no override param, so
  # an agent can only ever set its own handoff.
  def handoff_set(conn, params) do
    role = params["self"] || params["role"]
    body = params["body"]

    cond do
      blank?(role) ->
        conn |> put_status(:bad_request) |> json(%{error: "missing self (your role/title)"})

      blank?(body) ->
        conn |> put_status(:bad_request) |> json(%{error: "missing body"})

      true ->
        case Forum.set_handoff(role, body) do
          {:ok, handoff} ->
            json(conn, %{ok: true, handoff: handoff_json(handoff)})

          {:error, changeset} ->
            conn |> put_status(:unprocessable_entity) |> json(%{error: errors(changeset)})
        end
    end
  end

  # GET /api/forum/handoff/:role  — read a role's current-state (takeover).
  def handoff_get(conn, %{"role" => role} = params) do
    case Forum.get_handoff(role) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "no handoff for #{role}"})

      handoff ->
        history =
          case parse_int(params["history"]) do
            nil ->
              []

            n when n > 0 ->
              role
              |> Forum.list_handoff_history(limit: n)
              |> Enum.map(&handoff_version_json/1)

            _ ->
              []
          end

        json(conn, %{handoff: handoff_json(handoff), history: history})
    end
  end

  # GET /api/forum/handoffs  — list which roles have a current handoff.
  def handoffs(conn, _params) do
    handoffs = Forum.list_handoffs() |> Enum.map(&handoff_json/1)
    json(conn, %{handoffs: handoffs})
  end

  # --- helpers ---------------------------------------------------------------

  defp channel_json(c) do
    %{slug: c.slug, title: c.title, description: c.description, inserted_at: c.inserted_at}
  end

  defp post_json(p, slug) do
    %{
      id: p.id,
      channel: slug,
      author: p.author,
      body: p.body,
      title: p.title,
      status: p.status,
      owner: p.owner,
      pinned: not is_nil(p.pinned_at),
      pinned_at: p.pinned_at,
      archived: not is_nil(p.archived_at),
      archived_at: p.archived_at,
      parent_id: p.parent_id,
      thread_root_id: p.thread_root_id,
      permalink: "forum/#{slug}/#{p.id}",
      inserted_at: p.inserted_at,
      updated_at: p.updated_at
    }
  end

  # Lean board row: top-level fields only, NO body, plus a reply count.
  defp compact_json(p, slug, reply_count) do
    %{
      id: p.id,
      channel: slug,
      title: p.title,
      status: p.status,
      owner: p.owner,
      author: p.author,
      pinned: not is_nil(p.pinned_at),
      archived: not is_nil(p.archived_at),
      reply_count: reply_count,
      permalink: "forum/#{slug}/#{p.id}",
      updated_at: p.updated_at
    }
  end

  defp handoff_json(h) do
    %{
      role: h.role,
      body: h.body,
      version: h.version,
      updated_at: h.updated_at,
      inserted_at: h.inserted_at
    }
  end

  defp handoff_version_json(v) do
    %{role: v.role, body: v.body, version: v.version, inserted_at: v.inserted_at}
  end

  defp resolve_session_id(user_id, title) do
    case Sessions.list_sessions_by_title(user_id, title) do
      [] -> nil
      sessions -> (Enum.find(sessions, &(&1.status == :running)) || List.first(sessions)).id
    end
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp parse_int(nil), do: nil
  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  # Query-param truthiness: "1"/"true"/true. Everything else (incl. nil) is false.
  defp truthy(v), do: v in [true, "1", "true", 1]

  # nil for blank/missing, the trimmed string otherwise (so empty filters drop).
  defp presence(nil), do: nil
  defp presence(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp presence(v), do: v
end
