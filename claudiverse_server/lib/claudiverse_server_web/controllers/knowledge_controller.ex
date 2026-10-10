defmodule ClaudiverseServerWeb.KnowledgeController do
  @moduledoc """
  HTTP surface for the knowledge store (mirrors `/api/forum/*`).

  Distinct from the forum on purpose: a post is a moment, a document is a
  current best statement. The forum's ~1,499-char read truncation is a feed
  affordance and is NOT applied here — a document is returned whole, because
  truncating one is tail-biased and drops exactly the `bound` and
  `derived_under` fields that qualify a claim.

  The MCP `cv_doc_*` tools wrap these endpoints.
  """
  use ClaudiverseServerWeb, :controller

  alias ClaudiverseServer.Knowledge
  alias ClaudiverseServer.Knowledge.Custodian

  # POST /api/kb/documents
  def create(conn, params) do
    attrs = params |> promote_front_matter() |> atomise()

    case Knowledge.create_document(attrs) do
      {:ok, doc} ->
        maybe_anchor(doc, params["anchors"])
        json(conn, %{ok: true, document: doc_json(doc)})

      {:error, %Ecto.Changeset{} = cs} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: errors(cs)})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
    end
  end

  # GET /api/kb/documents/:id   (id may be a numeric id or a slug)
  #
  # `corrections` is ALWAYS present — empty list when nothing corrects this
  # document. There is deliberately no flag to omit it: you cannot be handed a
  # claim whose retraction exists but is not shown.
  def show(conn, %{"id" => id} = params) do
    key = if String.match?(id, ~r/^\d+$/), do: String.to_integer(id), else: id

    case Knowledge.get_document(key, with_anchors: params["with_anchors"] in ["1", "true"]) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "no document #{id}"})

      %{document: doc, revision: rev, corrections: corr, anchors: anchors} ->
        json(conn, %{
          document: doc_json(doc),
          revision: revision_json(rev),
          corrections: Enum.map(corr, &relation_json/1),
          anchors: anchors && Enum.map(anchors, &anchor_json/1),
          sweep_status: doc.kind == "FACT" && to_string(Knowledge.sweep_status(doc)),
          # ⭐ On the DEFAULT read path on purpose. A FACT may now be revised, so
          # a reader who cites it must be told when the claim they are reading is
          # not the original — the same reason `corrections` is never optional.
          revisions: Knowledge.revision_summary(doc)
        })
    end
  end

  # POST /api/kb/documents/:id/revisions
  def add_revision(conn, %{"id" => id} = params) do
    key = if String.match?(id, ~r/^\d+$/), do: String.to_integer(id), else: id

    case Knowledge.get_document(key) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "no document #{id}"})

      %{document: doc} ->
        case Knowledge.add_revision(doc, atomise(params)) do
          {:ok, updated} ->
            json(conn, %{ok: true, document: doc_json(updated)})

          # A FACT refuses revision by design; say so with the remedy rather
          # than a bare 422.
          {:error, reason} when is_binary(reason) ->
            conn |> put_status(:conflict) |> json(%{error: reason})

          {:error, cs} ->
            conn |> put_status(:unprocessable_entity) |> json(%{error: errors(cs)})
        end
    end
  end

  # GET /api/kb/documents/:id/history
  def history(conn, %{"id" => id}) do
    key = if String.match?(id, ~r/^\d+$/), do: String.to_integer(id), else: id

    case Knowledge.get_document(key) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "no document #{id}"})

      %{document: doc} ->
        json(conn, %{revisions: Enum.map(Knowledge.history(doc.id), &revision_json/1)})
    end
  end

  # GET /api/kb/search?q=&limit=
  def search(conn, %{"q" => q} = params) do
    limit = params |> Map.get("limit", "15") |> to_int(15)

    # `raw=1` sends FTS5 operator syntax through (OR, NEAR, column filters).
    # Without it every whitespace-separated term is REQUIRED and quoted on its
    # own, so `-O2 -G0` and `tools/ee/vm.sh` are literal searches instead of
    # ArgumentErrors; a query wrapped in double quotes stays an exact phrase.
    # See Knowledge.search/2.
    raw = params["raw"] in ["1", "true"]

    # One corpus, several fleets. `scope` filters to that scope PLUS `fleet`
    # (shared operational knowledge); `scope=*` or omitting it searches
    # everything. Whatever the filter withholds is COUNTED and returned, never
    # dropped in silence.
    scope = params["scope"]

    case Knowledge.search(q, limit: limit, raw: raw, scope: scope) do
      # A syntax error must NOT be reported as "no results" — a crash and an
      # empty corpus are otherwise the same observation to the caller, which is
      # exactly how the hyphen bug survived for as long as it did.
      {:error, msg} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "search syntax: #{msg}",
          hint: "plain queries are quoted automatically; raw=1 means YOU own the FTS5 syntax"
        })

      results ->
        json(conn, %{
          results: results,
          scope: scope,
          withheld: Knowledge.search_withheld(q, raw: raw, scope: scope)
        })
    end
  end

  def search(conn, _), do: conn |> put_status(:bad_request) |> json(%{error: "q is required"})

  # GET /api/kb/anchors/:type/:value — everything anchored here
  def anchor(conn, %{"type" => type, "value" => value}) do
    docs = Knowledge.documents_for_anchor(type, value)
    json(conn, %{type: type, value: value, documents: Enum.map(docs, &doc_json/1)})
  end

  # GET /api/kb/address/:address?build=usa_v200 — the LISTING VIEW
  #
  # Everything known at one address: the current name, every alias it has ever
  # had, and the documents anchored there. This is the overview the fleet has
  # never had — today the equivalent is grepping several stores by hand.
  def address(conn, %{"address" => address} = params) do
    build = params["build"] || "usa_v200"
    l = Knowledge.address_listing(address, build)

    json(conn, %{
      address: l.address,
      build: l.build,
      current_symbol: l.current_symbol && symbol_json(l.current_symbol),
      aliases: Enum.map(l.aliases, &symbol_json/1),
      documents: Enum.map(l.documents, &doc_json/1)
    })
  end

  # POST /api/kb/symbols — record the name an address currently has
  def record_symbol(conn, %{"address" => a, "name" => n} = params) do
    build = params["build"] || "usa_v200"

    case Knowledge.record_symbol(a, n, build,
           recorded_by: params["recorded_by"] || "unknown",
           source_sha: params["source_sha"]
         ) do
      {:ok, sym} -> json(conn, %{ok: true, symbol: symbol_json(sym)})
      {:error, cs} -> conn |> put_status(:unprocessable_entity) |> json(%{error: errors(cs)})
    end
  end

  # GET /api/kb/symbols/:name — resolve a name, INCLUDING a dead one
  def resolve_symbol(conn, %{"name" => name} = params) do
    json(conn, %{name: name, addresses: Knowledge.addresses_for_name(name, params["build"])})
  end

  # POST /api/kb/relations
  @doc """
  Create a relation. Accepts `from`/`to` as SLUGS or ids, as well as the raw
  `from_document_id`/`to_document_id`.

  A slug is the stable public handle for a document; internal row ids are not.
  Requiring callers to resolve ids first means every client re-implements the
  lookup — and a client that resolves the wrong one writes a correction
  pointing at the wrong claim, which reads exactly like a correct one.
  """
  def relate(conn, params) do
    with {:ok, from_id} <- resolve_doc(params["from"] || params["from_document_id"]),
         {:ok, to_id} <- resolve_doc(params["to"] || params["to_document_id"]) do
      attrs =
        params
        |> Map.drop(["from", "to", "from_document_id", "to_document_id"])
        |> Map.put("from_document_id", from_id)
        |> Map.put("to_document_id", to_id)
        |> atomise()

      case Knowledge.relate(attrs) do
        {:ok, rel} -> json(conn, %{ok: true, relation: relation_json(rel)})
        {:error, cs} -> conn |> put_status(:unprocessable_entity) |> json(%{error: errors(cs)})
      end
    else
      {:error, missing} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "no document #{inspect(missing)}"})
    end
  end

  defp resolve_doc(nil), do: {:error, nil}
  defp resolve_doc(id) when is_integer(id), do: {:ok, id}

  defp resolve_doc(ref) when is_binary(ref) do
    case Knowledge.get_document(ref) do
      %{document: %{id: id}} -> {:ok, id}
      _ -> {:error, ref}
    end
  end

  # GET /api/kb/stale — the sweep worklist
  def stale(conn, _params) do
    rows =
      Knowledge.stale_facts()
      |> Enum.map(fn {doc, status} ->
        %{document: doc_json(doc), sweep_status: to_string(status)}
      end)

    json(conn, %{stale: rows, count: length(rows)})
  end

  # POST /api/kb/checks — record a sweep result
  def record_check(conn, params) do
    attrs =
      params
      |> atomise()
      |> Map.put_new(:ran_at, DateTime.utc_now() |> DateTime.truncate(:second))

    case Knowledge.record_check(attrs) do
      {:ok, check} -> json(conn, %{ok: true, check_id: check.id})
      {:error, cs} -> conn |> put_status(:unprocessable_entity) |> json(%{error: errors(cs)})
    end
  end

  # --- helpers --------------------------------------------------------------

  defp maybe_anchor(_doc, nil), do: :ok

  defp maybe_anchor(doc, anchors) when is_list(anchors) do
    Enum.each(anchors, fn
      %{"type" => t, "value" => v} -> Knowledge.anchor_document(doc, t, v)
      _ -> :ok
    end)
  end

  defp maybe_anchor(_doc, _), do: :ok

  # Fields the STORE supports but that had no route through the API, so callers
  # passed them and `Map.take(@known)` below DROPPED THEM SILENTLY — the write
  # returned ok and the value was gone.
  #
  # MEASURED 2026-09-11, and this is why it matters: ~20 FACTs were filed with
  # an explicit `fact_bound` stating what each did NOT establish. Every one was
  # discarded; `front_matter` came back `{}` on all of them. Four RULINGs lost
  # their `ruling_revoked_by` the same way. Both fields are REQUIRED by the
  # project's own rules, and the tool meant to carry them ate them.
  #
  # They ride in front_matter rather than new columns: front_matter exists for
  # exactly this (kind-specific schema), the Revision moduledoc already
  # specifies `demonstrated_by` living there, and no migration is needed.
  #
  # ⛔ Adding a key here is only half the fix — it must ALSO be exposed by the
  # cv_doc_put tool schema, or Zod strips it one layer earlier and this never
  # sees it. That double-drop is what hid the bug.
  @front_matter_fields ~w(ruling_revoked_by fact_bound fact_derived_under demonstrated_by)

  defp promote_front_matter(params) do
    Enum.reduce(@front_matter_fields, params, fn field, acc ->
      case Map.get(acc, field) do
        v when is_binary(v) and v != "" ->
          key = String.replace_prefix(field, "ruling_", "") |> String.replace_prefix("fact_", "")
          fm = Map.get(acc, "front_matter") || %{}
          Map.put(acc, "front_matter", Map.put(fm, key, v))

        _ ->
          acc
      end
    end)
  end

  @known ~w(kind scope title slug created_by body_md author front_matter
            address name build recorded_by source_sha
            fact_command fact_fails_when fact_fails_when_status
            from_document_id to_document_id document_id verdict output runner ran_at note)
  defp atomise(params) do
    params
    |> Map.take(@known)
    |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
  end

  defp to_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      _ -> default
    end
  end

  defp to_int(_, default), do: default

  defp doc_json(d),
    do: %{
      id: d.id,
      kind: d.kind,
      scope: d.scope,
      title: d.title,
      slug: d.slug,
      created_by: d.created_by,
      updated_at: d.updated_at
    }

  defp revision_json(nil), do: nil

  defp revision_json(r),
    do: %{
      id: r.id,
      body_md: r.body_md,
      author: r.author,
      front_matter: r.front_matter,
      fact_command: r.fact_command,
      fact_fails_when: r.fact_fails_when,
      fact_fails_when_status: r.fact_fails_when_status,
      inserted_at: r.inserted_at
    }

  defp relation_json(r),
    do: %{
      id: r.id,
      kind: r.kind,
      from_document_id: r.from_document_id,
      to_document_id: r.to_document_id,
      author: r.author,
      note: r.note
    }

  defp symbol_json(s),
    do: %{
      name: s.name,
      address: s.address,
      build: s.build,
      valid_from: s.valid_from,
      valid_to: s.valid_to,
      current: is_nil(s.valid_to),
      source_sha: s.source_sha,
      recorded_by: s.recorded_by
    }

  defp anchor_json(a), do: %{type: a.type, value: a.value, normalised: a.normalised}

  defp errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
      end)
    end)
  end

  @doc """
  Durability status: when the last snapshot ran and whether it passed.

  Exists because a scheduled backup that fails only into a log file is a
  backup nobody knows is broken. `last: "never"` with `enabled: true` after
  the first interval has passed is itself a finding.
  """
  def health(conn, _params) do
    json(conn, %{ok: true, snapshots: describe(Custodian.status())})
  end

  defp describe(%{last: :never} = s),
    do: %{enabled: s.enabled, dir: s.dir, last: "never"}

  defp describe(%{last: %{ok: true, at: at, info: i}} = s) do
    %{
      enabled: s.enabled,
      dir: s.dir,
      last: %{
        ok: true,
        at: at,
        path: i.path,
        bytes: i.bytes,
        seconds: i.seconds,
        tables: i.tables,
        rows: i.rows
      }
    }
  end

  defp describe(%{last: %{ok: false, at: at, error: e}} = s),
    do: %{enabled: s.enabled, dir: s.dir, last: %{ok: false, at: at, error: e}}

  @doc """
  Facts a runner should execute now.

  The runner is a CLIENT by necessity, not by preference: measured over
  `#ledger-proto2`, 2,304 of 3,978 runnable commands need the lorem-fleet EE toolchain
  and 406 need the ipsum-fleet containers — none of which exist on this server. A
  server-side sweep would report ERROR for most of the corpus and those errors
  would be indistinguishable from facts going stale.
  """
  def sweep_worklist(conn, params) do
    opts = [
      limit: int_param(params, "limit", 50),
      min_age_hours: int_param(params, "min_age_hours", 24)
    ]

    json(conn, %{ok: true, worklist: Knowledge.sweep_worklist(opts)})
  end

  @doc """
  Record one sweep run.

  ⭐ The client reports what it OBSERVED — output and exit status. The verdict
  is derived server-side by comparing against the previous run: a client that
  decided its own verdict could report UNCHANGED forever and nothing here would
  notice.
  """
  def record_run(conn, %{"document_id" => id} = params) do
    case Knowledge.record_run(id, params) do
      {:ok, check} ->
        json(conn, %{
          ok: true,
          verdict: check.verdict,
          document_id: check.document_id,
          ran_at: check.ran_at
        })

      {:error, cs} ->
        conn |> put_status(:unprocessable_entity) |> json(%{ok: false, errors: errors(cs)})
    end
  end

  @doc """
  Counts by sweep state — the dashboard number.

  ⚠️ `untested` is reported separately and is never folded into a total that
  reads as coverage. An ASSERTED fact is not a fact awaiting a run; it is one
  whose failing branch nobody has ever seen, and no amount of running clears it.
  """
  def sweep_summary(conn, _params) do
    by_state =
      Knowledge.stale_facts()
      |> Enum.frequencies_by(fn {_doc, status} -> status end)

    json(conn, %{
      ok: true,
      needs_attention: by_state,
      note:
        "untested = ASSERTED, never clearable by running the command; " <>
          "corroborated facts are omitted and are NOT counted as verified"
    })
  end

  defp int_param(params, key, default) do
    case params[key] do
      nil -> default
      v when is_integer(v) -> v
      v -> case Integer.parse(to_string(v)) do
             {n, _} -> n
             :error -> default
           end
    end
  end
end
