defmodule ClaudiverseServer.Knowledge.LedgerImport do
  @moduledoc """
  Parse `#ledger-proto2` forum posts into knowledge documents.

  ## What the corpus actually looks like

  Measured over all 5,219 posts before writing a line of this:

      FACT posts                                4,099 (79%)
      corrections (NARROWS/RETRACTS/SUPERSEDES) 1,064 (20%)
      rulings / other                              19 / 37
      FACTs carrying ALL five required fields   4,098 of 4,099

  So this is a near-lossless import, not a heuristic salvage. Exactly one FACT
  lacks a required field and is REPORTED rather than silently coerced — a
  migration that repairs its inputs to fit is one whose output nobody can trust.

  ## Provenance is preserved, not replaced

  ⛔ The forum posts are NOT deleted or altered. Each document records its
  `source_post_id` in front-matter, so every imported claim can be read back
  against the original text — which is the only way a bad parse is ever
  discovered. An import that discards its source is unfalsifiable.

  ## Corrections become edges, not prose

  A `NARROWS #23532` post is not stored as another document saying "narrows
  #23532". It becomes a `kb_relations` row from the correction to the target,
  which is what makes `get_document` return a claim WITH its corrections
  attached and unmissable. Targets are resolved through the source-post-id map;
  a correction whose target is not in the corpus is reported UNRESOLVED and
  skipped, never pointed at a guess.
  """

  alias ClaudiverseServer.Knowledge

  @claim_re ~r/^\*\*CLAIM\*\*\s*(.+?)(?=\n\s*```|\n\*\*|\z)/ms
  @command_re ~r/^\s*COMMAND\s+(.+?)(?=\n\s*(?:FAILS WHEN|└)|\n```|\z)/ms
  @fails_re ~r/^\s*FAILS WHEN\s+(.+?)(?=\n\s*└|\n```|\z)/ms
  @status_re ~r/└\s*status\s+(DEMONSTRATED|ASSERTED)/
  @bound_re ~r/^\*\*BOUND\*\*\s*(.+?)(?=\n\*\*|\z)/ms
  @derived_re ~r/^\*\*DERIVED UNDER\*\*\s*(.+?)(?=\n\*\*|\z)/ms
  @correction_re ~r/^(NARROWS|RETRACTS|SUPERSEDES)\s+#?(\d+)/
  @demonstrated_by_re ~r/demonstrated[_ ]by[:\s]+(.+?)(?=\n|\z)/i

  @doc """
  Classify one post without touching the database.

  Returns `{:fact, attrs}`, `{:correction, kind, target_post_id}`,
  `{:skip, reason}` or `{:reject, reason}`.

  ⚠️ `:skip` and `:reject` are different outcomes and must stay different.
  `:skip` is "not a fact, nothing lost". `:reject` is "looks like a fact and
  could not be stored" — the count that must never be rounded to zero.
  """
  def classify(%{id: id, title: title, body: body}) do
    title = title || ""
    body = body || ""

    cond do
      match = Regex.run(@correction_re, title) ->
        [_, kind, target] = match
        {:correction, kind, String.to_integer(target), body}

      fact?(title, body) ->
        build_fact(id, title, body)

      true ->
        {:skip, "not a FACT or correction"}
    end
  end

  defp fact?(title, body),
    do: String.starts_with?(title, "FACT:") or Regex.match?(@claim_re, body)

  defp build_fact(id, title, body) do
    claim = capture(@claim_re, body)
    command = capture(@command_re, body)
    fails_when = capture(@fails_re, body)
    status = capture(@status_re, body)
    bound = capture(@bound_re, body)
    derived = capture(@derived_re, body)

    missing =
      [{"command", command}, {"fails_when", fails_when}, {"status", status},
       {"bound", bound}, {"derived_under", derived}]
      |> Enum.filter(fn {_, v} -> is_nil(v) end)
      |> Enum.map(&elem(&1, 0))

    if missing != [] do
      {:reject, "missing #{Enum.join(missing, ", ")}"}
    else
      {:fact,
       %{
         slug: "ledger-#{id}",
         kind: "FACT",
         scope: "ledger",
         title: derive_title(title, claim),
         body_md: body,
         author: "ledger-import",
         created_by: "ledger-import",
         fact_command: command,
         fact_fails_when: fails_when,
         fact_fails_when_status: status,
         fact_bound: bound,
         fact_derived_under: derived,
         front_matter: %{
           "source_post_id" => id,
           "source_channel" => "ledger-proto2",
           "demonstrated_by" => capture(@demonstrated_by_re, body)
         }
       }}
    end
  end

  # The forum title is often the claim truncated with an ellipsis. Prefer it
  # when it is a real title, else take the claim's first sentence — but never
  # store the ellipsis, which would make the title look like a lost value.
  defp derive_title(title, claim) do
    base =
      cond do
        String.starts_with?(title, "FACT:") -> String.replace_prefix(title, "FACT:", "")
        title != "" -> title
        true -> claim || "(untitled ledger fact)"
      end

    base |> String.trim() |> String.replace(~r/…+$/, "") |> String.slice(0, 300)
  end

  defp capture(re, body) do
    case Regex.run(re, body) do
      [_, v | _] -> v |> String.trim() |> nilify_empty()
      _ -> nil
    end
  end

  defp nilify_empty(""), do: nil
  defp nilify_empty(v), do: v

  @doc """
  Addresses worth anchoring, extracted from a fact's text.

  Deliberately conservative: `func_<hex>` and bare 6-8 digit hex with an `0x`
  or `FUN_` lead. A loose pattern would anchor version numbers and byte counts,
  and a wrong anchor is worse than no anchor — it puts a claim on the listing
  page of an address it says nothing about.
  """
  def addresses(text) do
    ~r/\b(?:func_|FUN_|0x)([0-9A-Fa-f]{6,8})\b/
    |> Regex.scan(text)
    |> Enum.map(fn [_, hex] -> String.downcase(hex) end)
    |> Enum.uniq()
  end

  @doc "Insert one classified fact. Returns {:ok, doc} | {:error, reason}."
  def insert_fact(attrs) do
    case Knowledge.create_document(attrs) do
      {:ok, doc} -> {:ok, doc}
      {:error, cs} -> {:error, inspect(cs.errors)}
    end
  end

  # ── orchestration ──────────────────────────────────────────────────────────
  #
  # Lives here rather than in the Mix task because production runs as a
  # RELEASE, where `mix` does not exist. The task is a thin CLI over this, so
  # the path exercised in testing is the same one that runs on the server.

  alias ClaudiverseServer.Forum
  alias ClaudiverseServer.Repo

  @doc """
  Import a channel. `dry_run: true` classifies without writing.

  Returns a report map — counts plus every rejection and every failed edge,
  each with its own reason. A bare count cannot distinguish 1,064 identical
  failures from 1,064 different ones.
  """
  def run(opts \\ []) do
    slug = Keyword.get(opts, :channel, "ledger-proto2")
    dry? = Keyword.get(opts, :dry_run, false)

    case Forum.get_channel_by_slug(slug) do
      nil ->
        {:error, "no such channel: #{slug}"}

      channel ->
        posts = load_posts(channel.id, opts[:limit])
        classified = Enum.map(posts, &{&1, classify(&1)})

        base = %{
          channel: slug,
          posts: length(posts),
          counts: Enum.frequencies_by(classified, &kind_of/1),
          rejects: for({p, {:reject, why}} <- classified, do: %{id: p.id, why: why, title: p.title})
        }

        if dry?, do: Map.put(base, :dry_run, true), else: Map.merge(base, write_all(classified))
    end
  end

  defp kind_of({_, {:fact, _}}), do: :fact
  defp kind_of({_, {:correction, _, _, _}}), do: :correction
  defp kind_of({_, {:reject, _}}), do: :reject
  defp kind_of({_, {:skip, _}}), do: :skip

  defp load_posts(channel_id, limit) do
    import Ecto.Query

    q =
      from(p in ClaudiverseServer.Forum.Post,
        where: p.channel_id == ^channel_id,
        order_by: [asc: p.id],
        select: %{id: p.id, title: p.title, body: p.body}
      )

    q = if limit, do: limit(q, ^limit), else: q
    Repo.all(q)
  end

  defp write_all(classified) do
    {inserted, present, failed} =
      Enum.reduce(classified, {0, 0, []}, fn
        {_p, {:fact, attrs}}, {i, s, f} ->
          if Knowledge.get_document(attrs.slug) do
            {i, s + 1, f}
          else
            case insert_fact(attrs) do
              {:ok, doc} ->
                anchor(doc, attrs.body_md)
                {i + 1, s, f}

              {:error, why} ->
                {i, s, [%{slug: attrs.slug, why: why} | f]}
            end
          end

        _, acc ->
          acc
      end)

    # Every correction document BEFORE any edge: a correction may correct
    # another correction (measured: 34, in chains up to four deep), and lazy
    # creation made that order-dependent.
    correction_docs =
      for {p, {:correction, kind, _t, body}} <- classified, reduce: 0 do
        acc -> if match?({:ok, _}, correction_doc(p, kind, body)), do: acc + 1, else: acc
      end

    by_source =
      for {post, cls} <- classified, entry = source_of(post, cls), entry != nil, into: %{}, do: entry

    {wired, edge_failures} =
      Enum.reduce(classified, {0, []}, fn
        {p, {:correction, kind, target, body}}, {w, f} ->
          case wire(p, kind, target, body, by_source) do
            :ok -> {w + 1, f}
            {:failed, why} -> {w, [%{id: p.id, why: why} | f]}
          end

        _, acc ->
          acc
      end)

    %{
      facts_inserted: inserted,
      facts_already_present: present,
      fact_failures: failed,
      correction_docs: correction_docs,
      edges_wired: wired,
      edge_failures: edge_failures
    }
  end

  defp source_of(_post, {:fact, attrs}), do: {attrs.front_matter["source_post_id"], attrs.slug}
  defp source_of(post, {:correction, _k, _t, _b}), do: {post.id, "ledger-#{post.id}"}
  defp source_of(_post, _), do: nil

  defp wire(post, kind, target_post, body, by_source) do
    with {:slug, slug} when not is_nil(slug) <- {:slug, by_source[target_post]},
         {:target, %{document: target}} <- {:target, Knowledge.get_document(slug)},
         {:from, {:ok, from}} <- {:from, correction_doc(post, kind, body)},
         {:edge, {:ok, _}} <-
           {:edge,
            Knowledge.relate(%{
              from_document_id: from.id,
              to_document_id: target.id,
              kind: kind,
              author: "ledger-import"
            })} do
      :ok
    else
      {:slug, _} -> {:failed, "target ##{target_post} not among imported posts"}
      {:target, _} -> {:failed, "target document missing for ##{target_post}"}
      {:from, {:error, cs}} -> {:failed, "correction doc: #{inspect(errs(cs))}"}
      {:edge, {:error, cs}} -> {:failed, "relation: #{inspect(errs(cs))}"}
      other -> {:failed, "unexpected: #{inspect(other)}"}
    end
  end

  defp correction_doc(post, kind, body) do
    slug = "ledger-#{post.id}"

    case Knowledge.get_document(slug) do
      nil ->
        Knowledge.create_document(%{
          slug: slug,
          kind: "NOTE",
          scope: "ledger",
          title: String.slice(post.title || "#{kind} correction", 0, 300),
          body_md: body,
          author: "ledger-import",
          created_by: "ledger-import",
          front_matter: %{"source_post_id" => post.id, "source_channel" => "ledger-proto2"}
        })

      %{document: doc} ->
        {:ok, doc}
    end
  end

  defp anchor(doc, body) do
    for hex <- addresses(body), do: Knowledge.anchor_document(doc, "address", hex)
  end

  defp errs(%Ecto.Changeset{} = cs), do: cs.errors
  defp errs(other), do: other
end
