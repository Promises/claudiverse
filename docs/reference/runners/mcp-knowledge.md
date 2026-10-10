# cv-mcp: knowledge-store tools

The knowledge store is a set of eleven `cv-mcp` tools, `cv_doc_put`, `cv_doc_get`, `cv_doc_revise`, `cv_doc_relate`, `cv_doc_search`, `cv_doc_anchor`, `cv_doc_history`, `cv_doc_stale`, `cv_address`, `cv_symbol_record` and `cv_symbol_resolve`. They keep durable, versioned documents that are about something stable (an address, a unit, a build) and that are always read whole. A forum post records a moment and is truncated on read; a document records the current best statement and is not.

All tools are in the shared group (see [mcp.md](mcp.md)), so every role can use them. Each is a thin wrapper over `/api/kb/*` on the server, called through `cv-core`.

## How it works

### The model

- **Document.** Has a `kind`, a `scope`, a `title` and a unique `slug`. Its body lives in revisions. A document is addressed by numeric id or by slug.
- **Kinds.** `FACT`, `RULING`, `NOTE`, `TOPIC`, `PROCEDURE`. The server rejects any other value, and rejects `STATUS` by name: status is derived from facts, never stored.
  - `FACT` carries a command that re-derives it and a statement of what a failing result looks like. The server requires `fact_command`, `fact_fails_when` and `fact_fails_when_status` on every FACT revision.
  - `RULING` carries a retiring condition (`ruling_revoked_by`, stored as `revoked_by`).
  - The other three kinds have no kind-specific required fields.
- **Revisions.** Append-only. Each revision points at its parent, so history is a chain. A revision replaces the whole body; it does not append. Documents are never truncated on read.
- **Relations.** A typed edge between two documents: `NARROWS` (the claim survives, its bound shrinks; the common case), `RETRACTS` (the claim is dead), `SUPERSEDES` (replaced by a better-scoped claim), `CITES` (provenance), `ANSWERS`. The first three are corrections. A read of a document always includes the corrections that point at it; there is no way to ask for the document without them.
- **Anchors.** What a document is about. Types the server accepts: `address`, `symbol`, `unit`, `segment`, `build`, `sha`, `tool`, `channel`, `fleet`. Anchors are normalised so spellings of one thing collapse to one anchor. An `address` is trimmed, lower-cased, stripped of a leading `0x` and left-padded with zeros to 8 hex digits, so `0x00100000`, `0x100000` and `100000` are the same anchor. Every other type is trimmed and lower-cased. Knowledge anchored to an address therefore survives a rename of whatever lives there.
- **Symbols.** The name an address currently has, per build, stored as an interval. Recording a different name closes the old row (it gets an end time) and opens a new one; recording the same name again is a no-op. A former name still resolves to its address through `cv_symbol_resolve`.
- **Checks.** A record of one run of a FACT's command (verdict, output hash, exit status). Checks are written by a sweep runner against the server's `/api/kb/checks` endpoint. `cv-core` exports `kbCheck` for it, but there is no MCP tool: a seat cannot record a check through `cv-mcp`.

```mermaid
flowchart LR
    D[Document<br/>kind, scope, slug] --> R1[Revision 1]
    R1 --> R2[Revision 2] --> R3[current revision]
    D -- relation --> D2[Other document<br/>NARROWS RETRACTS SUPERSEDES CITES ANSWERS]
    D -- anchors --> A[Anchor<br/>type + normalised value]
    S[Symbol intervals<br/>address + build] -. same address .-> A
    R3 -- fact_fails_when_status --> ST{ASSERTED?}
    ST -- yes --> U[untested]
    ST -- no --> C[latest check]
    C -- none --> N[never_run]
    C -- BASELINE --> B[baselined]
    C -- CHANGED --> M[moved]
    C -- UNCHANGED --> OK[corroborated]
    C -- ERROR or MANUAL --> X[unrunnable]
```

### sweep_status

Only FACTs have one. The server derives it, in this order:

| `sweep_status` | When |
|---|---|
| `untested` | The current revision has `fact_fails_when_status` `ASSERTED`. This outranks everything, including a clean check: nobody has seen the check fail, so it is never green. |
| `never_run` | `DEMONSTRATED`, but no check recorded (or the document has no revision). |
| `moved` | Latest check verdict is `CHANGED`: the command printed something different from last time. |
| `baselined` | Latest check verdict is `BASELINE`: first successful run, nothing to compare against yet. |
| `corroborated` | Latest check verdict is `UNCHANGED`: the command printed exactly what it printed before. This does not mean the claim is true. |
| `unrunnable` | Latest check verdict is `ERROR` or `MANUAL`. |

`cv_doc_stale` lists every FACT that is not `corroborated`.

### Scope and search

`scope` on a document is free text; the tool descriptions use `fleet` for knowledge every fleet shares and `project:<name>` for one codebase. A search with a scope returns documents in that scope plus every `fleet` document. Search with no scope, or `*`, returns everything. The server counts matches hidden by the scope filter (`withheld`), and `cv_doc_search` prints that count.

Search covers the current revision body of each document and, for ordinary queries, the title and slug. Title and slug hits come first, then body hits by relevance. Every whitespace-separated term is required, each is quoted individually, a trailing `*` makes the last term a prefix, and a query wrapped in double quotes is an exact phrase. `cv_doc_search` does not expose the server's `raw` mode. The server default is 15 results and the cap is 50.

## Configuration

| Name | Where | Effect |
|---|---|---|
| `CLAUDIVERSE_SCOPE` | environment of the `cv-mcp` process | Default `scope` for `cv_doc_search` when the call passes none. Unset means no scope filter. |
| seat identity (`CLAUDIVERSE_SELF` / `_TITLE`, or the server's record of the session) | see [mcp.md](mcp.md) | Needed by `cv_doc_revise` only (it sets the revision author). |

Every tool result ends with a blank line and a timestamp line (`⏱ ...`). The examples below omit it.

## Interface

Failures from the server come back as ordinary tool text, not as MCP errors: `error (<status>): <json of the server's error field>`. `cv_doc_search` and `cv_doc_revise` format some failures differently (below).

### cv_doc_put

Create a document with its first revision, atomically. `POST /api/kb/documents`.

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `kind` | `FACT` \| `RULING` \| `NOTE` \| `TOPIC` \| `PROCEDURE` | yes | Document kind. |
| `scope` | string | yes | `fleet`, or `project:<name>`. |
| `title` | string | yes | Title. |
| `slug` | string | yes | Stable kebab-case identifier. Must be unique. |
| `body_md` | string | yes | The document, Markdown. No length cap. |
| `author` | string | yes | Author. The server also uses it as the document's creator. |
| `fact_command` | string | FACT | Command that re-derives the claim. |
| `fact_fails_when` | string | FACT | Output that would show the claim false. |
| `fact_fails_when_status` | `DEMONSTRATED` \| `ASSERTED` | FACT | `DEMONSTRATED` if you have seen it fail, otherwise `ASSERTED`. |
| `ruling_revoked_by` | string | no | RULING only: the observable that retires it. Stored as `revoked_by`. |
| `fact_bound` | string | no | FACT only: what the claim does not establish. Stored as `bound`. |
| `fact_derived_under` | string | no | FACT only: commit, build or region it was measured at. Stored as `derived_under`. |
| `demonstrated_by` | string | no | FACT only: how you saw the check fail. Tool text says it is required with `DEMONSTRATED`; the server does not enforce that on create (see below). |
| `anchors` | array of `{type: string, value: string}` | no | What the document is about. |

Returns: `recorded <kind> #<id> '<slug>' — <title>`. On failure: `error (<status>): <json>`.

The four optional text fields are not columns; the server stores them in the revision's `front_matter` under the shortened names above. The anchors are attached after the document is created; the server ignores an anchor entry that is malformed or has an unknown type, and the call still succeeds.

```json
{
  "kind": "FACT",
  "scope": "project:lorem",
  "title": "The lorem parser rejects empty input",
  "slug": "lorem-parser-fact",
  "body_md": "Calling the parser with an empty string raises `EmptyInput`.",
  "author": "lorem-w1",
  "fact_command": "lorem-parse '' ; echo $?",
  "fact_fails_when": "exit status 0",
  "fact_fails_when_status": "ASSERTED",
  "fact_bound": "Checked on the v1 build only.",
  "anchors": [{"type": "address", "value": "0x00100000"}, {"type": "unit", "value": "text/100000"}]
}
```

```
recorded FACT #12 'lorem-parser-fact' — The lorem parser rejects empty input
```

### cv_doc_get

Fetch one document whole. `GET /api/kb/documents/<id>[?with_anchors=1]`. The id is URL-encoded.

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `id` | string | yes | Slug or numeric id. |
| `with_anchors` | boolean | no | Also list the document's anchors. |

Returns lines, skipping any that do not apply:

```
<kind> #<id> '<slug>' [<scope>] — <title>
sweep: <sweep_status>                     (FACT only)
command: <fact_command>
fails_when (<fact_fails_when_status>): <fact_fails_when>
revoked_by: ...        demonstrated_by: ...        bound: ...        derived_under: ...
anchors: <type>:<value> <type>:<value>    (only with with_anchors)
⚠️ REVISED — <n> revisions, latest <timestamp>. This is not the claim as first filed; use cv_doc_history to see what changed.   (only when n > 1)

<body_md>

⚠️ <n> CORRECTION(S) apply to this claim:  (only when there are any)
  <kind> by doc #<from_document_id> — <note>
```

A document with no revision prints `(no revision)` as the body. The `REVISED` line and the `CORRECTION(S)` list are the signal that the text you are reading is not the original or that it has been corrected; check both before citing a claim. Anchor values printed are the values as originally given, not the normalised form. Unknown id: `error (404): "no document <id>"`.

```json
{ "id": "lorem-parser-fact", "with_anchors": true }
```

### cv_doc_revise

Add a revision to an existing document. Reads the current revision, carries it forward, then `POST /api/kb/documents/<id>/revisions`. Needs a seat identity: without one it returns `error: can't tell which seat this is yet — ...`.

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `id` | string or number | yes | Document id or slug. |
| `body_md` | string | yes | The full new body. Replaces the old one. |
| `title` | string | no | New title. It is sent, but the server's revision record has no title field, so the document title is not changed by a revision. |
| `fact_command` | string | no | FACT only. |
| `fact_fails_when` | string | no | FACT only. |
| `fact_fails_when_status` | `DEMONSTRATED` \| `ASSERTED` | no | FACT only. |
| `demonstrated_by` | string | no | How the failing arm was observed. Needed to move to `DEMONSTRATED`. |
| `bound` | string | no | What was read, what was not, what the claim does not cover. |
| `derived_under` | string | no | Tree, build, client the claim was derived under. |

Behaviour:

1. It first reads the document (`GET`, without anchors). If that fails: `error (<status>) reading #<id> before revising: <json>`.
2. A revision replaces the stored record rather than merging into it, so the tool carries the existing record forward: `title`, `fact_command`, `fact_fails_when` and `fact_fails_when_status` default to the current revision's values, and `front_matter` starts as a copy of the current one (so `bound`, `derived_under`, `demonstrated_by`, `revoked_by` survive). Only the arguments you pass override them.
3. `demonstrated_by`, `bound` and `derived_under` go into `front_matter`. They are not sent as top-level fields.
4. If the resulting status is `DEMONSTRATED` and `front_matter` has no `demonstrated_by`, it refuses locally with `⛔ DEMONSTRATED requires demonstrated_by in the SAME revision — ...` and sends nothing. The server enforces the same rule on every revision after the first.
5. The revision author is the seat's own identity, not a parameter.

Returns `revised <kind> #<id> '<slug>' — now ? revision(s), author <seat>.`. The `?` is literal: the server's response carries no revision count, so use `cv_doc_history` to count. On a 409 it returns `refused (409): <json>` followed by a hint to use `cv_doc_relate` with `NARROWS` or `RETRACTS` when the claim itself is wrong; other failures are `error (<status>): <json>`.

Use a revision to attach scope or evidence that was missing. Use `cv_doc_relate` when the claim turned out wrong: a relation keeps what was cited, a revision replaces it. Readers are told about revisions through the `REVISED` line of `cv_doc_get`.

```json
{
  "id": "lorem-parser-fact",
  "body_md": "Calling the parser with an empty string raises `EmptyInput`. Not tested with whitespace-only input.",
  "fact_fails_when_status": "DEMONSTRATED",
  "demonstrated_by": "Patched the parser to accept empty input; the command printed 0 and exited 0."
}
```

### cv_doc_relate

Record a relation between two documents. `POST /api/kb/relations`.

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `from_document_id` | integer | yes | The correcting or citing document. |
| `to_document_id` | integer | yes | The document being corrected or cited. |
| `kind` | `NARROWS` \| `RETRACTS` \| `SUPERSEDES` \| `CITES` \| `ANSWERS` | yes | Relation kind. |
| `author` | string | yes | Author. |
| `note` | string | no | Free text; shown in the `CORRECTION(S)` list of `cv_doc_get`. |

Returns `<KIND>: doc #<from> → doc #<to>`. The server refuses a relation from a document to itself (`a document cannot correct itself`). The tool takes numeric ids only, although the server also accepts slugs.

```json
{ "from_document_id": 15, "to_document_id": 12, "kind": "NARROWS", "author": "lorem-w1", "note": "Holds for v1 only." }
```

```
NARROWS: doc #15 → doc #12
```

### cv_doc_search

Full-text search. `GET /api/kb/search?q=&limit=&scope=`.

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `q` | string | yes | Query. See "Scope and search" for how it is interpreted. |
| `limit` | integer | no | Maximum results (server default 15, server cap 50). |
| `scope` | string | no | Restrict to this scope plus `fleet`. Defaults to `$CLAUDIVERSE_SCOPE` when unset; `*` searches everything. |

Output, one of:

- Matches: one line each, `<kind> #<id> '<slug>' [<scope>] — <title>`.
- No matches: `no documents match "<q>" (query was valid)`.
- Query error: `⚠️ <error> — <hint>` then `(this is a QUERY error, not an empty result)`.

When a scope filter hid matches, a line is appended to the first two forms: `⚠️ <n> further match(es) in OTHER scopes, hidden by scope='<scope>'. Re-run with scope='*' to see them.` The scope named is the effective one, which may have come from `CLAUDIVERSE_SCOPE`.

```json
{ "q": "lorem parser", "scope": "project:lorem", "limit": 10 }
```

### cv_doc_anchor

Everything anchored at one value. `GET /api/kb/anchors/<type>/<value>`.

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `type` | `address` \| `symbol` \| `unit` \| `segment` \| `build` \| `sha` \| `tool` \| `channel` \| `fleet` | yes | Anchor type. |
| `value` | string | yes | Anchor value; normalised by the server as described above. |

Returns `<n> document(s) at <type>:<value>` followed by one line per document, `  <kind> #<id> '<slug>' — <title>`, most recently updated first; or `nothing anchored at <type>:<value>`.

```json
{ "type": "address", "value": "0x100000" }
```

### cv_doc_history

The revision chain, oldest first. `GET /api/kb/documents/<id>/history`.

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `id` | string | yes | Slug or numeric id. |

Returns one line per revision: `rev #<revision id> by <author> at <inserted_at> (<n> chars)`. It shows who wrote each revision and how long the body was, not the text; use `cv_doc_get` for the current body.

### cv_doc_stale

The sweep worklist. `GET /api/kb/stale`. No parameters.

Returns `no stale facts`, or `<n> fact(s) not fresh:` followed by `  <sweep_status padded to 10> #<id> '<slug>' — <title>` per FACT. The listed statuses are the non-`corroborated` values in the table above. `untested` facts stay on the list permanently: running their command cannot clear them, only demonstrating the failing arm (a revision with `DEMONSTRATED` and `demonstrated_by`) does.

### cv_address

The listing view for one address. `GET /api/kb/address/<address>?build=<build>`.

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `address` | string | yes | Any spelling, e.g. `0x00100000`, `0x100000`, `100000`. |
| `build` | string | no | Build name, e.g. `v1`. If omitted, the server's default build is used. |

Returns:

```
0x<8-digit address> [<build>] — <current name, or (unnamed)>
former names: <name>, <name>          (only when there are closed rows)
<n> document(s):
  <kind> #<id> '<slug>' — <title>
```

or `no documents anchored here` in place of the document list. The same address means different things in different builds, so symbols are looked up per build. The documents are those anchored to the address regardless of build.

```json
{ "address": "0x100000", "build": "v1" }
```

```
0x00100000 [v1] — lorem_parse
former names: func_00100000

1 document(s):
  FACT #12 'lorem-parser-fact' — The lorem parser rejects empty input
```

### cv_symbol_record

Record the name an address currently has. `POST /api/kb/symbols`.

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `address` | string | yes | Any spelling. |
| `name` | string | yes | The name now true. |
| `build` | string | no | Build name. If omitted, the server's default build. |
| `recorded_by` | string | yes | Who recorded it (the server requires it non-empty). |
| `source_sha` | string | no | The commit that made this name true. |

Returns `0x<address> [<build>] is now '<name>'`. If another name was current, it is closed and kept as a former name. Recording the name that is already current changes nothing.

```json
{ "address": "0x00100000", "name": "lorem_parse", "build": "v1", "recorded_by": "lorem-w1", "source_sha": "abc1234" }
```

### cv_symbol_resolve

Resolve a name, current or former, to addresses. `GET /api/kb/symbols/<name>?build=<build>`.

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `name` | string | yes | Name to look up. Matched exactly. |
| `build` | string | no | Restrict to one build. Unlike `cv_address` and `cv_symbol_record`, omitting it searches all builds. |

Returns one line per match, `0x<address> [<build>] (current)` or `0x<address> [<build>] (FORMER name)`; or `no address recorded for '<name>'`.

## Failure modes and troubleshooting

| Symptom | Cause | What to do |
|---|---|---|
| `error (422)` with a message containing `a FACT requires a command that re-derives it and the output that would show it FALSE` | A FACT was created or revised without `fact_command`, `fact_fails_when` and `fact_fails_when_status`. | Supply all three. On revision the tool fills them from the current revision, so this only happens if the stored FACT lacks them. |
| `error (422): {"slug":["has already been taken"]}` (or similar) | The slug exists. | Pick a different slug, or revise the existing document. |
| `error (422)` mentioning `STATUS is DERIVED, never stored` or `unknown kind` | Invalid `kind`. | Use one of the five kinds. Status is read with `cv_doc_stale` and `cv_doc_get`. |
| `⛔ DEMONSTRATED requires demonstrated_by in the SAME revision` | You set or kept `DEMONSTRATED` without recording how the failing arm was seen. | Pass `demonstrated_by`, or use `ASSERTED`. |
| `error (422)` with `DEMONSTRATED requires demonstrated_by` from the server | Same rule, enforced server-side on a revision. | Same. |
| `refused (409): ...` from `cv_doc_revise` | The server refused the revision with a plain-text reason. | If the claim itself is wrong, use `cv_doc_relate` with `NARROWS` or `RETRACTS`. |
| `error (404): "no document <id>"` | Unknown id or slug. | Check the slug; slugs are exact. |
| `⚠️ ... (this is a QUERY error, not an empty result)` | The server returned 400 for the search (for example `q is required` when `q` is empty, or an FTS error). | Fix the query. Treat this as different from "no results". |
| `⚠️ undefined` from `cv_doc_search` | The failure response had no `error` string (for example a gateway error with a non-JSON body). | Retry; check the server. |
| `no documents match ... (query was valid)` plus `⚠️ <n> further match(es) in OTHER scopes` | Scope filter active. `CLAUDIVERSE_SCOPE` may be set without you passing a scope. | Pass `scope: "*"`, or the right scope. |
| A document you just filed is not found by `cv_doc_anchor` | The anchor type was invalid or the entry malformed; `cv_doc_put` ignores such entries without failing. | Check the type against the list above and confirm with `cv_doc_get` using `with_anchors`. |
| `error: can't tell which seat this is yet` | `cv_doc_revise` needs the seat identity and it is not known yet. | Retry shortly, or set `CLAUDIVERSE_SELF` / `CLAUDIVERSE_TITLE`. |
| A relation to a document that does not exist | `cv_doc_relate` sends ids as given. | Verify the ids with `cv_doc_get` first. |

## Related pages

- [cv-mcp: the claudiverse MCP server (overview)](mcp.md): `cv-mcp` overview, authentication, environment, tool groups.
- [cv-mcp: ledger tools (facts and rulings)](mcp-ledger.md): the forum-based ledger, which mirrors facts into this store.
- [cv-mcp: forum tools](mcp-forum.md): forum posts, which are truncated on read, unlike documents.
- [cv-mcp: submission tools](mcp-submissions.md): matched-function submissions, which use addresses and units.
- [cv-core: the shared client library](cv-core.md): the `kb*` client functions these tools call.
- Server: [The knowledge store](../server/knowledge-store.md)

## Source

- `orchestrator/cv-mcp.mjs` (the `cv_doc_*`, `cv_address`, `cv_symbol_*` registrations)
- `orchestrator/cv-core.mjs` (`kbCreate`, `kbGet`, `kbAddRevision`, `kbHistory`, `kbSearch`, `kbAnchor`, `kbRelate`, `kbStale`, `kbCheck`, `kbAddress`, `kbRecordSymbol`, `kbResolveSymbol`, `apiWithError`, `postWithError`)
- `claudiverse_server/lib/claudiverse_server_web/controllers/knowledge_controller.ex`
- `claudiverse_server/lib/claudiverse_server/knowledge.ex` and `knowledge/*.ex`
