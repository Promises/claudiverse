defmodule ClaudiverseServer.Knowledge do
  @moduledoc """
  The knowledge store: durable, versioned, anchored documents.

  Separate from the forum by design. A post is a moment; a document is a current
  best statement. The forum's ~1,499-char read truncation is a reasonable feed
  affordance and is left in place there — it is only destructive when a document
  lives in the feed.

  ## The invariants this module enforces

  These are the point of the module. Callers cannot opt out, and each has a test
  that fails when the invariant is removed.

    1. **A read never returns a claim without its corrections.** `cv_fact_get`
       has this property today and it must survive the migration: you cannot be
       handed a claim whose retraction exists but is not shown.
    2. **A FACT is never SILENTLY different from the claim that was cited.**
       Revised 2026-09-11: revisions were rejected outright, which left no way
       to attach a bound discovered later — ~20 facts were filed with a
       `fact_bound` the API had silently discarded, and the corpus was stuck
       with claims whose scope could never be recorded. Revisions are now
       allowed, and the property is held by the READ PATH instead: revision
       count and latest author ride on the default GET, so a drifted citation
       announces itself. Correction by RELATION is still preferred for a claim
       that turned out wrong (prefer NARROWS — the usual outcome is that a claim
       was right and smaller than stated); revision is for attaching scope and
       evidence. ⛔ `ASSERTED -> DEMONSTRATED` requires `demonstrated_by` in the
       same revision — that is the one edit that turns a never-green fact green.
    3. **`ASSERTED` is never swept green.** A fact whose failing arm has never
       been observed is reported UNTESTED, permanently, whatever its last check
       said. A check with no reachable negative is decoration.
    4. **STATUS is not storable.** Enforced in `Document.changeset/2`.

    5. **Symbol writes are alias-aware.** A rename CLOSES the previous row and
       opens a new one; it never rewrites history, so a document written under
       the old spelling is still found by it.
  """
  import Ecto.Query

  alias ClaudiverseServer.Repo
  alias ClaudiverseServer.Knowledge.{Document, Revision, Anchor, DocAnchor, Relation, Check, Symbol}

  @default_search_limit 15
  @max_search_limit 50

  # --- create ---------------------------------------------------------------

  defp default_created_by(attrs) do
    cond do
      present?(attrs[:created_by]) or present?(attrs["created_by"]) -> attrs
      present?(attrs[:author]) -> Map.put(attrs, :created_by, attrs[:author])
      present?(attrs["author"]) -> Map.put(attrs, "created_by", attrs["author"])
      true -> attrs
    end
  end

  defp present?(nil), do: false
  defp present?(v) when is_binary(v), do: String.trim(v) != ""
  defp present?(_), do: true

  @doc """
  Create a document with its first revision, atomically.

  A FACT additionally requires `fact_command`, `fact_fails_when` and
  `fact_fails_when_status` — a fact without a command that can fail is not
  evidence.
  """
  def create_document(attrs) do
    kind = attrs[:kind] || attrs["kind"]

    # `created_by` and `author` are the same person in every real call, and a
    # caller that supplies one has no way to know the other is also required.
    # Found by first real use: cv_doc_put sent `author` and got a 422 naming a
    # field it had never heard of. Defaulting here fixes every client at once,
    # including ones already deployed and unable to be updated.
    attrs = default_created_by(attrs)

    Repo.transaction(fn ->
      with {:ok, doc} <- %Document{} |> Document.changeset(attrs) |> Repo.insert(),
           {:ok, rev} <- insert_revision(doc, attrs, kind, nil),
           {:ok, doc} <- set_current(doc, rev) do
        doc
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Append a revision.

  ## INVARIANT 2, as revised 2026-09-11: a FACT may be revised, but never silently

  The original rule rejected FACT revisions outright, because "the claim that
  was cited and the claim that stands are SILENTLY different things". The word
  doing the work there is *silently* — the hazard was never the edit, it was a
  reader being handed a changed claim with no signal that it changed.

  That is the same hazard `corrections` solves, and it is solved the same way:
  revision count and authorship ride on the DEFAULT read path, so a citation
  that has drifted announces itself. A history that is merely queryable is worth
  nothing, because nobody queries it.

  ⛔ What forced the change: ~20 FACTs were filed with an explicit `fact_bound`
  that the API silently discarded (fixed, `5ab5e8d`). With revisions rejected
  there was NO way to attach the bounds afterwards — the corpus was stuck with
  claims whose scope could never be recorded. A bound discovered later must be
  attachable, or bounds only ever get weaker in practice.

  ⚠️ One transition is still guarded: `ASSERTED -> DEMONSTRATED` is the single
  edit that turns a never-green fact green, so it requires `demonstrated_by` in
  the same revision. Otherwise a fact could be promoted to green by editing one
  word.
  """
  def add_revision(%Document{} = doc, attrs) do
    Repo.transaction(fn ->
      with {:ok, rev} <- insert_revision(doc, attrs, doc.kind, doc.current_revision_id),
           {:ok, doc} <- set_current(doc, rev) do
        doc
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp insert_revision(doc, attrs, kind, parent_id) do
    cs =
      %Revision{}
      |> Revision.changeset(
        attrs
        |> normalise_keys()
        |> Map.put(:document_id, doc.id)
        |> Map.put(:parent_revision_id, parent_id)
      )

    cs = if kind == "FACT", do: Revision.validate_fact_fields(cs), else: cs
    # Guarded on REVISIONS only — see validate_demonstration/1 for why creation
    # is deliberately left permissive.
    cs = if is_nil(parent_id), do: cs, else: validate_demonstration(cs)
    Repo.insert(cs)
  end

  # ⛔ The one EDIT that turns a never-green fact green. Promoting a check to
  # DEMONSTRATED without saying HOW the failing arm was seen is exactly the
  # unbacked-green this corpus exists to prevent, so the evidence must arrive in
  # the same revision.
  #
  # ⚠️ Deliberately NOT applied at creation, and this is a scope decision rather
  # than an oversight. Requiring it there is arguably right — CLAUDE.md already
  # states the rule, and ~20 FACTs were filed DEMONSTRATED with no evidence
  # behind it — but it is a breaking change for every existing caller: enabling
  # it on creation failed 18 of this project's OWN test fixtures, which file
  # DEMONSTRATED without demonstrated_by. `cv_fact_add` already refuses that
  # combination client-side; closing the same hole at creation for every client
  # is a separate call, with that blast radius stated up front.
  defp validate_demonstration(cs) do
    status = Ecto.Changeset.get_field(cs, :fact_fails_when_status)
    fm = Ecto.Changeset.get_field(cs, :front_matter) || %{}

    demonstrated_by =
      Map.get(fm, "demonstrated_by") || Map.get(fm, :demonstrated_by)

    if status == "DEMONSTRATED" and (is_nil(demonstrated_by) or demonstrated_by == "") do
      Ecto.Changeset.add_error(
        cs,
        :fact_fails_when_status,
        "DEMONSTRATED requires demonstrated_by — say HOW you saw the check produce its failure (the mutation injected, the control that fired). Use ASSERTED if you have not seen it fail."
      )
    else
      cs
    end
  end

  @doc """
  How many revisions a document has, and who wrote the latest.

  ⭐ This rides on the DEFAULT read path, not behind a history call. A revised
  claim must announce itself to someone who cites it, exactly as a corrected one
  does — a history that is merely queryable is worth nothing, because nobody
  queries it.
  """
  def revision_summary(%Document{} = doc) do
    q =
      from(r in Revision,
        where: r.document_id == ^doc.id,
        select: %{count: count(r.id), latest: max(r.inserted_at)}
      )

    Repo.one(q) || %{count: 0, latest: nil}
  end

  defp set_current(doc, rev) do
    doc |> Ecto.Changeset.change(current_revision_id: rev.id) |> Repo.update()
  end

  defp normalise_keys(attrs) do
    Map.new(attrs, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    ArgumentError -> attrs
  end

  # --- read -----------------------------------------------------------------

  @doc """
  Fetch a document with its current revision and — ⭐ ALWAYS, INVARIANT 1 — the
  corrections pointing at it.

  There is deliberately no un-threaded read. `corrections` is a list, empty when
  nothing corrects this document; it is never omitted, so a caller cannot
  accidentally read a retracted claim as if it stood.
  """
  def get_document(id_or_slug, opts \\ []) do
    case fetch_doc(id_or_slug) do
      nil ->
        nil

      doc ->
        %{
          document: doc,
          revision: current_revision(doc),
          corrections: corrections_for(doc.id),
          anchors: if(opts[:with_anchors], do: anchors_for(doc.id), else: nil)
        }
    end
  end

  defp fetch_doc(id) when is_integer(id), do: Repo.get(Document, id)
  defp fetch_doc(slug) when is_binary(slug), do: Repo.get_by(Document, slug: slug)

  defp current_revision(%Document{current_revision_id: nil}), do: nil
  defp current_revision(%Document{current_revision_id: id}), do: Repo.get(Revision, id)

  @doc "Corrections pointing AT this document, newest first."
  def corrections_for(document_id) do
    kinds = Relation.correction_kinds()

    from(r in Relation,
      where: r.to_document_id == ^document_id and r.kind in ^kinds,
      order_by: [desc: r.inserted_at]
    )
    |> Repo.all()
  end

  @doc "Full revision chain, oldest first — the history view."
  def history(document_id) do
    from(r in Revision, where: r.document_id == ^document_id, order_by: [asc: r.id]) |> Repo.all()
  end

  # --- anchors --------------------------------------------------------------

  @doc "Attach a document to an anchor, creating the anchor if new."
  def anchor_document(%Document{} = doc, type, value, relation \\ "about") do
    with {:ok, anchor} <- upsert_anchor(type, value) do
      %DocAnchor{}
      |> DocAnchor.changeset(%{document_id: doc.id, anchor_id: anchor.id, relation: relation})
      |> Repo.insert(on_conflict: :nothing)
    end
  end

  defp upsert_anchor(type, value) do
    normalised = Anchor.normalise(type, value)

    case Repo.get_by(Anchor, type: type, normalised: normalised) do
      nil -> %Anchor{} |> Anchor.changeset(%{type: type, value: value}) |> Repo.insert()
      found -> {:ok, found}
    end
  end

  def anchors_for(document_id) do
    from(a in Anchor,
      join: da in DocAnchor,
      on: da.anchor_id == a.id,
      where: da.document_id == ^document_id
    )
    |> Repo.all()
  end

  @doc """
  Everything anchored at a value — the listing view.

  Resolves through the normalised form, so a document anchored at `0x00336B88`
  is found by `0x336b88`, and a symbol's OLD name still resolves after a rename.
  """
  def documents_for_anchor(type, value) do
    normalised = Anchor.normalise(type, value)

    from(d in Document,
      join: da in DocAnchor,
      on: da.document_id == d.id,
      join: a in Anchor,
      on: a.id == da.anchor_id,
      where: a.type == ^type and a.normalised == ^normalised,
      order_by: [desc: d.updated_at]
    )
    |> Repo.all()
  end


  # --- symbols: names as aliases -------------------------------------------

  @doc """
  Record the name an address currently has.

  ⭐ INVARIANT 5. If a different name is already current for this address, that
  row is CLOSED (`valid_to` set) and a new one opened — history is never
  rewritten, so the old spelling keeps resolving. Recording the same name again
  is a no-op rather than a duplicate.
  """
  def record_symbol(address, name, build, opts \\ []) do
    norm = Anchor.normalise("address", address)
    now = opts[:at] || DateTime.utc_now() |> DateTime.truncate(:second)
    by = opts[:recorded_by] || "unknown"

    Repo.transaction(fn ->
      case current_symbol(norm, build) do
        %Symbol{name: ^name} = existing ->
          existing

        %Symbol{} = existing ->
          {:ok, _} = existing |> Ecto.Changeset.change(valid_to: now) |> Repo.update()
          insert_symbol(norm, name, build, now, by, opts[:source_sha])

        nil ->
          insert_symbol(norm, name, build, now, by, opts[:source_sha])
      end
    end)
  end

  defp insert_symbol(address, name, build, from, by, sha) do
    case %Symbol{}
         |> Symbol.changeset(%{
           address: address,
           name: name,
           build: build,
           valid_from: from,
           recorded_by: by,
           source_sha: sha
         })
         |> Repo.insert() do
      {:ok, sym} -> sym
      {:error, cs} -> Repo.rollback(cs)
    end
  end

  @doc "The name currently true for an address in a build, or nil."
  def current_symbol(address, build) do
    norm = Anchor.normalise("address", address)

    from(s in Symbol,
      where: s.address == ^norm and s.build == ^build and is_nil(s.valid_to)
    )
    |> Repo.one()
  end

  @doc "Every name this address has ever had, oldest first."
  def symbol_history(address, build) do
    norm = Anchor.normalise("address", address)

    from(s in Symbol,
      where: s.address == ^norm and s.build == ^build,
      order_by: [asc: s.valid_from]
    )
    |> Repo.all()
  end

  @doc """
  Resolve a name to addresses — INCLUDING names that are no longer current.
  Searching a dead spelling must still find its address; that is the whole
  reason names are stored as intervals.
  """
  def addresses_for_name(name, build \\ nil) do
    q = from(s in Symbol, where: s.name == ^name, select: %{address: s.address, build: s.build, current: is_nil(s.valid_to)})
    q = if build, do: where(q, [s], s.build == ^build), else: q
    Repo.all(q)
  end

  @doc """
  The LISTING VIEW: everything known at an address — current name, every alias it
  has ever had, and the documents anchored there. This is the overview the fleet
  does not have today.
  """
  def address_listing(address, build) do
    norm = Anchor.normalise("address", address)

    %{
      address: norm,
      build: build,
      current_symbol: current_symbol(norm, build),
      aliases: symbol_history(norm, build),
      documents: documents_for_anchor("address", norm)
    }
  end

  # --- relations ------------------------------------------------------------

  def relate(attrs) do
    %Relation{} |> Relation.changeset(attrs) |> Repo.insert()
  end

  # --- search ---------------------------------------------------------------

  @doc """
  Full-text over revision bodies, newest revision per document.

  ## The query is QUOTED into an FTS5 phrase by default

  ⛔ MEASURED against the imported ledger (4,112 facts): a bare `-` or `/` in
  the query makes FTS5 raise `ArgumentError` — `"fopt-stack"`,
  `"tools/ee/vm.sh"` and `"-fopt-stack"` all crashed. Those are compiler flags
  and file paths, i.e. exactly what this corpus is searched for, so the failure
  landed on the most valuable queries.

  A trailing `*` is preserved OUTSIDE the quotes so prefix search still works
  (`func_0033*`). Pass `raw: true` to send FTS5 syntax through untouched (`OR`,
  `NEAR`, column filters) — deliberately opt-in, because a crash is a worse
  default than losing operator syntax.

  ## ⛔ `ORDER BY rank` is load-bearing — without it NEW documents are invisible

  FTS5 returns matches in ROWID order when no ordering is given, and rowid is
  insertion order. The imported ledger (4,112 facts) occupies the lowest rowids,
  so every small `LIMIT` was filled entirely by the oldest corpus and NOTHING
  written since the import could be reached.

  MEASURED 2026-09-11: `search("GetRandomInt")` returned 32 matches; the two
  `project:lorem-project` documents were at positions 31 and 32. At the default
  limit of 15 they did not appear at all. A document filed two minutes earlier
  was unfindable, and the failure is SILENT — it looks exactly like a corpus
  that does not contain the term, which is the same ambiguity the `{:error, _}`
  clause below exists to prevent.

  `rank` is bm25, lower is better, so relevance replaces insertion order and
  recency stops being a disqualifier. The FTS table is NOT aliased because FTS5
  auxiliary functions resolve `rank` against the table name in scope.
  """
  def search(query, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_search_limit) |> min(@max_search_limit)
    fts = if opts[:raw], do: query, else: to_fts_query(query)
    scope = opts[:scope]

    # ⛔ SCOPE FILTERING MUST NOT SILENTLY NARROW. One corpus serves several
    # fleets, so an unscoped search returns another project's documents — and
    # that got materially worse the moment ORDER BY rank landed, because before
    # it the other project's documents were buried past the default limit and
    # nobody noticed the mixing.
    #
    # A filter that quietly drops matches is the same class of defect: the
    # caller cannot tell "no such knowledge" from "filtered away". So the filter
    # reports what it withheld, and `scope: "*"` turns it off entirely.
    #
    # `fleet` scope is ALWAYS included: it exists for operational knowledge every
    # fleet shares (shimmed grep, runner semantics), and cutting a project off
    # from it would defeat the reason that scope exists.
    {where, args} =
      if scope in [nil, "*"] do
        {"", [fts, limit]}
      else
        {" AND (d.scope = ?2 OR d.scope = 'fleet')", [fts, scope, limit]}
      end

    sql = """
    SELECT d.id, d.kind, d.scope, d.title, d.slug
    FROM kb_revisions_fts
    JOIN kb_revisions r ON r.id = kb_revisions_fts.rowid
    JOIN kb_documents d ON d.id = r.document_id
    WHERE kb_revisions_fts MATCH ?1 AND d.current_revision_id = r.id#{where}
    ORDER BY rank
    LIMIT ?#{length(args)}
    """

    case Repo.query(sql, args) do
      {:ok, %{rows: rows}} ->
        body_hits = Enum.map(rows, &row_to_hit/1)

        # A raw query carries FTS5 operator syntax (OR, NEAR, column filters)
        # that LIKE cannot honour, so the title pass runs only for ordinary
        # literal queries.
        title_hits = if opts[:raw], do: [], else: title_matches(query, limit, scope)

        (title_hits ++ body_hits)
        |> Enum.uniq_by(& &1.id)
        |> Enum.take(limit)

      # A search ERROR must never surface as "no results". That ambiguity is
      # what made this bug survive: a crash and an empty corpus are the same
      # observation to the caller.
      {:error, err} ->
        {:error, Exception.message(err)}
    end
  rescue
    # The driver raises rather than returning {:error, _} for malformed MATCH
    # syntax, so the clause above never caught it. Keep BOTH: one for query
    # errors, one for driver raises.
    e -> {:error, Exception.message(e)}
  end

  @doc """
  How many documents match but were withheld by a scope filter.

  ⭐ Reported, never silent. A caller that cannot distinguish "no such knowledge"
  from "filtered away" will conclude the corpus is empty and act on it — which is
  the same failure the malformed-query/empty-list distinction exists to prevent.
  """
  def search_withheld(query, opts \\ []) do
    scope = opts[:scope]

    if scope in [nil, "*"] do
      0
    else
      fts = if opts[:raw], do: query, else: to_fts_query(query)

      sql = """
      SELECT count(*)
      FROM kb_revisions_fts
      JOIN kb_revisions r ON r.id = kb_revisions_fts.rowid
      JOIN kb_documents d ON d.id = r.document_id
      WHERE kb_revisions_fts MATCH ?1 AND d.current_revision_id = r.id
        AND d.scope <> ?2 AND d.scope <> 'fleet'
      """

      case Repo.query(sql, [fts, scope]) do
        {:ok, %{rows: [[n]]}} -> n
        _ -> 0
      end
    end
  rescue
    _ -> 0
  end

  defp row_to_hit([id, kind, scope, title, slug]),
    do: %{id: id, kind: kind, scope: scope, title: title, slug: slug}

  # ⛔ TITLES ARE NOT IN THE FTS INDEX, and cannot be.
  #
  # kb_revisions_fts is an EXTERNAL-CONTENT table (`content='kb_revisions'`),
  # but `title` is a column of kb_documents. FTS5 external content can only
  # index columns of its content table, which is why the insert trigger writes
  # a literal '' into the title column. So the column exists, is always empty,
  # and every title term was silently unfindable.
  #
  # MEASURED 2026-09-11: a document titled "zarquon calibration verdict" whose
  # body omits the word returns [] for search("zarquon").
  #
  # Fixed with a LIKE pass rather than by reindexing, because a LIKE over ~5k
  # short titles is trivial, it CANNOT GO STALE when a title changes, and it
  # avoids duplicating every body into a standalone index. Title hits rank
  # FIRST: a term in the title is a stronger signal than a mention in prose.
  defp title_matches(query, limit, scope) do
    # Every term must appear in the TITLE or the SLUG. Matching the whole query
    # as one substring meant a two-word query found nothing unless the title
    # held those words contiguously — the same defect as the FTS phrase quoting.
    # The slug is included because it is often the most exact name a document
    # has, and the FTS index never contained it.
    likes =
      query
      |> query_terms()
      |> Enum.map(fn t -> "%" <> String.replace(t, ~r/([\\%_])/, "\\\\\\1") <> "%" end)

    if likes == [] do
      []
    else
      conds =
        likes
        |> Enum.with_index(1)
        |> Enum.map(fn {_, i} -> "(d.title LIKE ?#{i} ESCAPE '\\' OR d.slug LIKE ?#{i} ESCAPE '\\')" end)
        |> Enum.join(" AND ")

      n = length(likes)

      # The scope filter has to apply here too, or title hits leak across
      # projects — and because title hits are ranked FIRST, a leak here is the
      # most visible possible one.
      {where, args} =
        if scope in [nil, "*"] do
          {"", likes ++ [limit]}
        else
          {" AND (d.scope = ?#{n + 1} OR d.scope = 'fleet')", likes ++ [scope, limit]}
        end

      sql = """
      SELECT d.id, d.kind, d.scope, d.title, d.slug
      FROM kb_documents d
      WHERE #{conds}#{where}
      ORDER BY d.id DESC
      LIMIT ?#{length(args)}
      """

      case Repo.query(sql, args) do
        {:ok, %{rows: rows}} -> Enum.map(rows, &row_to_hit/1)
        # The FTS arm already returned; a title-pass failure must not erase it.
        {:error, _} -> []
      end
    end
  end

  # Build the FTS5 MATCH expression for an ordinary (non-raw) query.
  #
  # 🔴 EVERY TERM IS REQUIRED; ADJACENCY IS NOT. The query used to be quoted as
  # ONE phrase, so "save slot frame layout" matched only a document holding
  # those words contiguously and in order. MEASURED on the live corpus
  # 2026-09-27: a real query returned 0 as a phrase and 1 with each term
  # required — and 0 reads as "no such record", the silent-zero failure.
  #
  # Each term is still QUOTED individually, which keeps the crash fix: a bare
  # `-` or `/` makes FTS5 raise, and flags and paths are what this corpus is
  # searched for. A trailing `*` stays outside the last term's quotes, so
  # prefix search survives. A query the caller wraps in double quotes is kept
  # as an exact phrase — the one case where adjacency was asked for.
  defp to_fts_query(query) do
    trimmed = String.trim(query)
    {body, star} = split_star(trimmed)

    if String.length(body) >= 2 and String.starts_with?(body, ~s(")) and
         String.ends_with?(body, ~s(")) do
      quote_term(String.slice(body, 1..-2//1)) <> star
    else
      case query_terms(body) do
        [] -> quote_term(body) <> star
        terms -> Enum.map_join(terms, " ", &quote_term/1) <> star
      end
    end
  end

  defp split_star(q) do
    if String.ends_with?(q, "*"), do: {String.trim_trailing(q, "*"), "*"}, else: {q, ""}
  end

  # Whitespace-separated terms, with a caller's surrounding quotes and a
  # trailing prefix `*` stripped. Shared by the FTS arm and the title arm so
  # both interpret a query the same way.
  defp query_terms(query) do
    {body, _} = query |> String.trim() |> split_star()

    body
    |> String.trim(~s("))
    |> String.split(~r/\s+/, trim: true)
  end

  defp quote_term(t), do: ~s(") <> String.replace(t, ~s("), ~s("")) <> ~s(")

  # --- staleness ------------------------------------------------------------

  @doc """
  ⭐ INVARIANT 3. The sweep state of a FACT, which is NOT simply its last check:

    * `:untested`      — `fails_when_status` is ASSERTED. Nobody has ever seen
      this check fail, so it can never be reported green, whatever any run
      said. ⛔ This outranks every other state, including a clean run.
    * `:never_run`     — DEMONSTRATED, but no check recorded yet.
    * `:moved`         — the last run printed something DIFFERENT. The fact's
      evidence has shifted underneath it; re-read the claim.
    * `:unrunnable`    — the last run errored, or the command is a prose
      procedure needing a human. Not corroborated, and not stale either.
    * `:baselined`     — the command ran ONCE and its output was recorded.
      ⚠️ This corroborates nothing: with nothing to compare against, a first
      run establishes only that the command executes. It stays on the worklist
      so it gets a second run, which is the one that can say anything.
    * `:corroborated`  — the command re-ran and printed exactly what it printed
      before.

  ⛔ `:corroborated` deliberately does NOT mean "true", and is not named
  `:fresh`. Measured over `#ledger-proto2`: ~99% of `fails_when` fields are
  prose, so nothing decides them mechanically. All this state asserts is that
  the evidence is still where the claim left it — the claim itself may be
  wrongly reasoned from evidence that never moved.
  """
  def sweep_status(%Document{kind: "FACT"} = doc) do
    rev = current_revision(doc)

    cond do
      is_nil(rev) -> :never_run
      rev.fact_fails_when_status == "ASSERTED" -> :untested
      true -> last_check_status(doc.id)
    end
  end

  def sweep_status(%Document{}), do: :not_a_fact

  defp last_check_status(document_id) do
    case last_check(document_id) do
      nil -> :never_run
      %Check{verdict: "CHANGED"} -> :moved
      %Check{verdict: "UNCHANGED"} -> :corroborated
      %Check{verdict: "BASELINE"} -> :baselined
      %Check{} -> :unrunnable
    end
  end

  @doc "The most recent check for a document, or nil."
  def last_check(document_id) do
    from(c in Check, where: c.document_id == ^document_id, order_by: [desc: c.ran_at], limit: 1)
    |> Repo.one()
  end

  def record_check(attrs) do
    %Check{} |> Check.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Every FACT not currently corroborated, with its reason — the sweep worklist.

  ⚠️ `:untested` facts stay ON this list forever by design. An ASSERTED fact
  cannot be cleared by running its command, because the command was never seen
  to fail — running it green proves only that the green branch works. They are
  listed so their count is visible, not so they can be worked off.
  """
  def stale_facts do
    from(d in Document, where: d.kind == "FACT", order_by: [asc: d.id])
    |> Repo.all()
    |> Enum.map(&{&1, sweep_status(&1)})
    |> Enum.reject(fn {_doc, status} -> status == :corroborated end)
  end

  @doc """
  Facts a runner should execute now, newest-first, excluding ones checked
  within `min_age_hours`.

  ⛔ Excludes `:untested` (ASSERTED). Running those commands would produce
  UNCHANGED and make an untested fact *look* worked-on while its actual defect
  — a failure branch nobody has ever observed — is untouched. Motion without
  progress, recorded as progress.
  """
  def sweep_worklist(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    min_age = Keyword.get(opts, :min_age_hours, 24)
    cutoff = DateTime.utc_now() |> DateTime.add(-min_age * 3600, :second)

    # ⛔ NOT built on stale_facts/0. That excludes :corroborated, so a fact
    # would be checked twice and then dropped from coverage FOREVER — and any
    # drift after that point would be invisible. Re-checking is governed by
    # min_age_hours; corroboration is not a finish line.
    from(d in Document, where: d.kind == "FACT", order_by: [asc: d.id])
    |> Repo.all()
    |> Enum.map(&{&1, sweep_status(&1)})
    |> Enum.reject(fn {_doc, status} -> status == :untested end)
    |> Enum.reject(fn {doc, _} ->
      case last_check(doc.id) do
        %Check{ran_at: at} -> DateTime.compare(at, cutoff) == :gt
        nil -> false
      end
    end)
    |> Enum.take(limit)
    |> Enum.map(fn {doc, status} ->
      rev = current_revision(doc)

      %{
        id: doc.id,
        slug: doc.slug,
        title: doc.title,
        status: status,
        command: rev && rev.fact_command,
        fails_when: rev && rev.fact_fails_when,
        last_output_hash: with(%Check{output_hash: h} <- last_check(doc.id), do: h)
      }
    end)
  end

  @doc """
  Record a sweep run, deriving the verdict by COMPARING output to the previous
  run rather than trusting the caller's classification.

  ⭐ The runner reports what it observed — exit status and output. It does not
  get to say whether that means CHANGED: a client that decides its own verdict
  can report UNCHANGED forever and no server-side check would notice.
  """
  def record_run(document_id, attrs) do
    output = attrs[:output] || attrs["output"] || ""
    exit_status = attrs[:exit_status] || attrs["exit_status"]
    environment = attrs[:environment] || attrs["environment"]
    runner = attrs[:runner] || attrs["runner"]
    manual? = attrs[:manual] || attrs["manual"] || false

    # ⭐ The hash covers the EXIT STATUS as well as the output: a command that
    # starts failing while printing the same thing has changed, and hashing
    # output alone would report UNCHANGED.
    hash = fingerprint(exit_status, output)
    previous = last_check(document_id)

    verdict =
      cond do
        manual? ->
          "MANUAL"

        not ran?(exit_status) ->
          "ERROR"

        is_nil(previous) or is_nil(previous.output_hash) ->
          "BASELINE"

        # ⛔ A hash computed under a DIFFERENT formula is not comparable, and
        # comparing it anyway reports CHANGED for every fact at once —
        # indistinguishable from the whole world moving underneath us.
        # OBSERVED: adding exit status to the fingerprint turned 9 of 11 checks
        # CHANGED in a single pass, on a repository nothing had touched.
        # Re-baseline instead, and say so rather than raising a false alarm.
        not comparable?(previous.output_hash) ->
          "BASELINE"

        previous.output_hash == hash ->
          "UNCHANGED"

        true ->
          "CHANGED"
      end

    record_check(%{
      document_id: document_id,
      ran_at: DateTime.utc_now() |> DateTime.truncate(:second),
      verdict: verdict,
      output: truncate(output),
      output_hash: if(verdict in Check.ran(), do: hash),
      exit_status: exit_status,
      environment: environment,
      runner: runner
    })
  end

  # The fingerprint is VERSIONED. Any change to what goes into it — adding a
  # field, changing normalisation — makes old hashes incomparable, and an
  # unversioned hash cannot tell that apart from the evidence itself changing.
  # Bump this whenever the formula changes; old checks then re-baseline quietly
  # instead of firing as drift.
  @fingerprint_version "v2"

  defp fingerprint(exit_status, output) do
    digest = :crypto.hash(:sha256, "#{exit_status}\n#{output}") |> Base.encode16(case: :lower)
    "#{@fingerprint_version}:#{digest}"
  end

  defp comparable?(hash), do: String.starts_with?(hash, @fingerprint_version <> ":")

  # ⛔ A non-zero exit is NOT an error. `grep` exits 1 when it matches nothing,
  # and "matches nothing" is the EXPECTED measurement for every fact whose
  # claim is that something is absent — which this corpus is full of.
  #
  # Measured on the first real sweep batch: 2 of 11 executed checks were
  # marked ERROR while their output was a valid memory read and a valid grep
  # result. And ERROR stores no hash, so those checks could never baseline and
  # therefore could never detect change — they would have been re-run forever,
  # permanently blind, while looking like a transient problem.
  #
  # Only "could not run at all" is an error: command not found (127), not
  # executable (126), killed/timeout (124, 137), or no status at all.
  defp ran?(nil), do: false
  defp ran?(status) when status in [124, 126, 127, 137], do: false
  defp ran?(status) when is_integer(status), do: true
  defp ran?(_), do: false

  # A truncated output must SAY it was truncated. A silently cut tail reads as
  # a complete smaller result, and caveats live at the end.
  @max_output 8_000
  defp truncate(s) when byte_size(s) <= @max_output, do: s

  defp truncate(s) do
    binary_part(s, 0, @max_output) <>
      "\n\n… [TRUNCATED: #{byte_size(s)} bytes total, #{byte_size(s) - @max_output} not stored]"
  end
end
