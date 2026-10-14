# Data model

Everything the Claudiverse server persists lives in one SQLite database (Ecto, `Ecto.Adapters.SQLite3` via `exqlite`) plus a few files beside it. This page lists every table, the two FTS5 virtual tables, what is deliberately kept only in memory, and the migration history. Column names, types and defaults are copied from the migrations in `server/api/priv/repo/migrations/`; the Ecto schemas under `server/api/lib/claudiverse_server/` were cross-checked against them (differences are called out).

There are 30 application tables, 2 FTS5 virtual tables (plus SQLite's own FTS5 shadow tables and Ecto's `schema_migrations`).

## Conventions

- **Primary keys.** Every table has an auto-increment integer `id` (Ecto default), except `cv_subscriptions`, whose primary key is the string `listener_title`.
- **Timestamps.** `timestamps()` adds `inserted_at` and `updated_at` as Ecto `naive_datetime` (stored as text by SQLite). Where the table says `timestamps(updated_at: false)` there is no `updated_at`. `human_requests` and `app_builds` use `timestamps(type: :utc_datetime)`. Columns declared `:utc_datetime` are also stored as text.
- **Types.** Ecto `:string` is `varchar(255)` in the migration; `:text` is unbounded; `:map` is JSON stored as text; `:binary` is a blob; `{:array, :string}` is JSON text.
- **Enumerations are plain strings.** Statuses, kinds and verdicts are `:string` columns; the allowed values are enforced by changesets, not by the database. The only `Ecto.Enum` fields are on `sessions` (`type`, `mode`, `status`).
- **Foreign keys** are written as `references(...)` in the migrations, with the `on_delete` behaviour listed per table below. Where a column is "an id" with no `references`, the database does not enforce it.
- **Ownership.** "Context" is the module that holds the queries and writes for the table. Controllers never touch tables directly.

## Sessions, accounts and tokens

```mermaid
erDiagram
    users ||--o{ user_tokens : "delete_all"
    users ||--o{ sessions : "delete_all"
    users ||--o{ human_requests : "delete_all"
    users ||--o{ profiles : "delete_all"
    sessions ||--o{ messages : "delete_all"
    sessions ||--o{ cv_events : "delete_all"
    sessions ||--o{ human_requests : "delete_all"
    profiles }o..o{ sessions : "profile_id (no FK)"
    cv_subscriptions {
        string listener_title PK
    }
```

### `users`

Purpose: web/app/seat accounts (email and password). Schema `Accounts.User`, context `Accounts`. Feature page: [auth.md](auth.md).

| Column | Type | Null / default |
|---|---|---|
| `email` | string | not null |
| `hashed_password` | string | not null |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: unique on `email`.

### `user_tokens`

Purpose: bearer tokens (sign-in tokens, the shared seat token, app and host tokens). Schema `Accounts.UserToken`, context `Accounts`. Feature page: [auth.md](auth.md).

| Column | Type | Null / default |
|---|---|---|
| `user_id` | references `users` | not null; `on_delete: :delete_all` |
| `token` | binary | not null |
| `context` | string | not null |
| `label` | string | null (added by `add_label_to_user_tokens`); the client a sign-in token was handed to (`desktop`, `android`, `server/web`). Null for tokens minted out of band, which a logout or the token list never revokes |
| `inserted_at` | naive_datetime | not null (no `updated_at`) |

Indexes: `user_id`; unique on `(context, token)`.

### `sessions`

Purpose: one row per Claude Code seat/session as the server knows it (sidecar-connected, spawned, or proxy-mirrored). Schema `Sessions.Session`, context `Sessions`. Feature pages: [sessions-and-rooms.md](sessions-and-rooms.md), [access-and-notify.md](access-and-notify.md), [profiles-and-hosts.md](profiles-and-hosts.md).

| Column | Type | Null / default | Added by |
|---|---|---|---|
| `title` | string | null | create |
| `type` | string | not null, default `"spawned"`; schema `Ecto.Enum` `[:sidecar, :spawned, :proxy]` | create |
| `mode` | string | default `"json"`; `Ecto.Enum` `[:json, :pty]` | create |
| `status` | string | not null, default `"running"`; `Ecto.Enum` `[:running, :stopped, :crashed]` | create |
| `working_directory` | string | null | create |
| `model` | string | default `"sonnet"` | create |
| `permission_mode` | string | default `"default"` | create |
| `user_id` | references `users` | not null; `on_delete: :delete_all` | create |
| `claude_session_id` | string | null. Claude Code's own session UUID; lets a reconnect reuse a row instead of inserting a new one. Null on legacy and `spawned` rows | `add_claude_session_id_to_sessions` |
| `display_title` | string | null. Sentence-case name from the transcript's `ai-title` record; display only, never used to address a seat | `add_display_title_to_sessions` |
| `host` | string | null. The machine (`CLAUDIVERSE_HOST`, else hostname) | `add_placement_to_sessions` |
| `fleet` | string | null (`CLAUDIVERSE_FLEET`) | `add_placement_to_sessions` |
| `origin` | string | null: `manual`, `spawn` or `runner` (`CLAUDIVERSE_ORIGIN`); null is treated as not-a-runner | `add_placement_to_sessions` |
| `can_notify` | boolean | not null, default `false`. Opt-in per seat (`CLAUDIVERSE_NOTIFY=1`) to ask for the operator | `add_can_notify_to_sessions` |
| `client_version` | string | null. Claude Code version line reported by the seat | `add_client_version_to_sessions` |
| `conversation_id` | string | null. The conversation to resume when it differs from `claude_session_id` (a seat started with `claude --resume X`) | `add_conversation_id_to_sessions` |
| `profile_id` | integer | null. Profile the seat was started from. No foreign key | `create_profiles` |
| `profile_revision` | integer | null. Profile revision at start | `create_profiles` |
| `tmux_session` | string | null | `create_profiles` |
| `access` | string | null. `basic`, `notify` or `full`; null means derived (`Sessions.Access`) | `add_access_to_sessions` |
| `notify_grant` | boolean | null. Operator's paging switch; null means derived | `add_notify_grant_to_sessions` |
| `notify_until` | utc_datetime | null. Optional expiry of the grant | `add_notify_grant_to_sessions` |
| `inserted_at`, `updated_at` | naive_datetime | not null | create |

The schema also has a virtual field `last_activity_at` (`naive_datetime`), filled by the session list query from `max(messages.inserted_at)`; it is not a column.

Indexes: `user_id`; `status`; `(user_id, claude_session_id)` named `sessions_user_claude_session_id_index`, partial `WHERE claude_session_id IS NOT NULL` (a plain index, not unique, despite the migration comment saying "one live row per"); `profile_id`.

### `messages`

Purpose: the stored transcript/mirror of a session (one row per mirrored message). Schema `Sessions.Message`, context `Sessions`. Feature pages: [sessions-and-rooms.md](sessions-and-rooms.md), [mirror-inbox-liveness.md](mirror-inbox-liveness.md).

| Column | Type | Null / default |
|---|---|---|
| `type` | string | not null |
| `payload` | map | not null |
| `sequence` | integer | not null. Seeded per Room from `max(sequence)+1` then incremented in memory, so ties and gaps are possible |
| `session_id` | references `sessions` | not null; `on_delete: :delete_all` |
| `inserted_at` | naive_datetime | not null (no `updated_at`) |

Indexes: `session_id`; `(session_id, sequence)`; `(session_id, inserted_at)` (added by `index_messages_session_inserted_at`, so "last activity" is one index seek). Live-only frame types (for example `stream_event`) are broadcast but not stored.

### `cv_events`

Purpose: queryable log of session state transitions (and later client debug snapshots), so it survives restarts. Schema `Sessions.CvEvent`, context `Sessions`. Feature page: [sessions-and-rooms.md](sessions-and-rooms.md).

| Column | Type | Null / default |
|---|---|---|
| `session_id` | references `sessions` | not null; `on_delete: :delete_all` |
| `kind` | string | not null |
| `from_state`, `to_state`, `trigger` | string | null |
| `detail` | map | null |
| `inserted_at` | naive_datetime | not null (no `updated_at`) |

Indexes: `(session_id, inserted_at)`; `kind`.

### `cv_subscriptions`

Purpose: persisted notification-router subscriptions (listener title to watched titles), so a restart does not wipe them. Schema `Sessions.CvSubscription`, context `Sessions` (used by `Notifications.Router`). Feature page: [notifications.md](notifications.md).

| Column | Type | Null / default |
|---|---|---|
| `listener_title` | string, **primary key** | not null |
| `watch` | map | not null |
| `inserted_at`, `updated_at` | naive_datetime | not null |

No other indexes, no foreign keys. The router's per-listener queue and idle flag are not stored (see below).

### `human_requests`

Purpose: a seat asking for the operator; at most one open request per session (asking again updates it). Schema `HumanRequests.HumanRequest`, context `HumanRequests`. Feature page: [human-requests.md](human-requests.md).

| Column | Type | Null / default |
|---|---|---|
| `session_id` | references `sessions` | not null; `on_delete: :delete_all` |
| `user_id` | references `users` | not null; `on_delete: :delete_all` |
| `summary` | text | not null |
| `detail` | text | null |
| `status` | string | not null, default `"open"` |
| `resolved_at` | utc_datetime | null |
| `inserted_at`, `updated_at` | utc_datetime | not null |

Indexes: `(session_id, status)`; `(user_id, status)`. There is no unique index; the "one open request per session" rule described in the migration is not a database constraint.

### `join_codes`

Purpose: one-time codes a new machine joins with (`JoinCodes`): **Add a machine** mints one, the machine's installer redeems it for its seat and host tokens. Schema `JoinCodes.JoinCode`. Feature page: [profiles-and-hosts.md](profiles-and-hosts.md).

| Column | Type | Null / default |
|---|---|---|
| `user_id` | references `users` | not null; `on_delete: :delete_all` |
| `code_hash` | string | not null. The sha256 (hex) of the code, normalised (upper case, no dashes); the code itself is never stored |
| `machine` | string | null. The name it was minted for; null when the machine names itself |
| `expires_at` | utc_datetime | not null. 15 minutes after minting |
| `used_at` | utc_datetime | null until the one redeem that succeeded |
| `used_by_machine` | string | null. The machine name it was redeemed for |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: unique `(code_hash)`; `(user_id)`.

### `machines`

Purpose: the machines a user's host agents have joined as, and when each was last seen (`Hosts.seen/3`, on every join and leave), so `GET /api/hosts` lists a machine that is offline now. Schema `Hosts.Machine`. Feature page: [profiles-and-hosts.md](profiles-and-hosts.md).

| Column | Type | Null / default |
|---|---|---|
| `user_id` | references `users` | not null; `on_delete: :delete_all` |
| `name` | string | not null. The host name, as in `host:<name>` |
| `last_seen_at` | utc_datetime | not null. The agent's last join or leave |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: unique `(user_id, name)`.

### `fleet_settings`

Purpose: what the operator sets per fleet (`Fleets`): `paused`, which a bulk restart leaves out by default. A fleet with no row is not paused. Feature page: [profiles-and-hosts.md](profiles-and-hosts.md).

| Column | Type | Null / default |
|---|---|---|
| `user_id` | references `users` | not null; `on_delete: :delete_all` |
| `fleet` | string | not null |
| `paused` | boolean | not null, default `false` |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: unique `(user_id, fleet)`.

### `github_tokens`

Purpose: the operator's GitHub tokens (`GitHub`), one per resource owner, and what GitHub said about each at its last check. Schema `GitHub.Token`. Feature page: [github.md](github.md).

| Column | Type | Null / default |
|---|---|---|
| `user_id` | references `users` | not null; `on_delete: :delete_all` |
| `label` | string | not null |
| `token` | binary | not null; AES-256-GCM ciphertext (`Vault`, associated data `github_tokens.v1`) |
| `kind` | string | not null; `fine_grained`, `classic` or `other`, from its prefix |
| `login` | string | GitHub account |
| `scopes` | string | a classic token's `X-OAuth-Scopes`; null for fine-grained |
| `expires_at` | utc_datetime | null: none reported by GitHub |
| `expires_on` | date | an expiry the operator entered, used when GitHub reports none |
| `repos` | text | JSON list of `owner/name` it reaches |
| `repos_count` | integer | repos `GET /user/repos` lists |
| `status` | string | not null, default `ok`; `unauthorized`, `error` |
| `last_error` | string | |
| `checked_at` | utc_datetime | |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: unique `(user_id, label)`.

### `github_cursors`

Purpose: where each GitHub source was read up to (`GitHub.Poller`), so a restart fires nothing twice. Schema `GitHub.Cursor`. Feature page: [github.md](github.md).

| Column | Type | Null / default |
|---|---|---|
| `user_id` | references `users` | not null; `on_delete: :delete_all` |
| `source` | string | not null; `repo:owner/name`, `search:<review-requested\|assigned\|mentioned>`, `token:<id>` |
| `data` | map | not null, default `{}`; a repository's `since` and `ci` (per open pull request: head `sha`, checks `state`), a search's last `keys`, a token's `warned_for` |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: unique `(user_id, source)`.

### `usage_samples`

Purpose: the account pool's usage history (`AnthropicAuths.UsageHistory`), one row per account per usage reading, thinned as it ages. Schema `AnthropicAuths.UsageSample`. Feature page: [account-pool.md](account-pool.md).

| Column | Type | Null / default |
|---|---|---|
| `anthropic_auth_id` | references `anthropic_auths` | not null; `on_delete: :delete_all` |
| `at` | utc_datetime | not null. When it was read |
| `weekly_pct`, `session_pct` | float | null when the reading had no such limit |
| `weekly_resets_at`, `session_resets_at` | utc_datetime | null when none was reported |

No timestamps: `at` is the row's time. Indexes: `(anthropic_auth_id, at)`.

### `runner_slots`

Purpose: each runner slot's last heartbeat, kept (`Runners`), so whether a slot was alive through a window can be answered after a server restart. Schema `Runners.Slot`. Feature page: [tasks-and-runners.md](tasks-and-runners.md).

| Column | Type | Null / default |
|---|---|---|
| `user_id` | references `users` | not null; `on_delete: :delete_all` |
| `slot` | string | not null. The runner's `--slot` |
| `fleet`, `host`, `lane` | string | null. From its last report |
| `state` | string | not null. `idle`, `busy`, `halted` or `stopped` |
| `beating_since` | utc_datetime | not null. When its current run of beats began |
| `last_seen_at` | utc_datetime | not null. Its last heartbeat |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: unique `(user_id, slot)`.

## Seat profiles

### `profiles`

Purpose: one record per managed seat, started by its machine's host agent. Schema `Profiles.Profile`, context `Profiles`. Feature page: [profiles-and-hosts.md](profiles-and-hosts.md).

| Column | Type | Null / default |
|---|---|---|
| `user_id` | references `users` | not null; `on_delete: :delete_all` |
| `name` | string | not null |
| `revision` | integer | not null, default `1` |
| `machine` | string | not null |
| `folder` | string | not null |
| `fleet` | string | null |
| `role` | string | not null, default `"member"` |
| `can_notify` | boolean | not null, default `false` |
| `runtime` | string | not null, default `"stock+mod"` |
| `model` | string | null |
| `effort` | string | null |
| `permission_mode` | string | not null, default `"auto"` (`"default"` before `profiles_permission_mode_defaults_to_auto`) |
| `mcp` | `{:array, :string}` | not null, default `[]` |
| `pooled` | boolean | not null, default `false` in the migration; **`true` in the Ecto schema** (see Notes below) |
| `autostart` | boolean | not null, default `false` |
| `protected` | boolean | not null, default `false`. A bulk restart leaves the seat out unless named (`Restarts`) |
| `resume` | string | not null, default `"latest"` |
| `debug` | boolean | not null, default `false` |
| `last_start` | map | null |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: unique on `(user_id, name)`. `sessions.profile_id` points here by value only (no FK), so deleting a profile leaves the session's `profile_id` dangling.

## Forum and handoffs

```mermaid
erDiagram
    direction LR
    forum_channels ||--o{ forum_posts : "delete_all"
    forum_channels ||--o{ forum_subscriptions : "delete_all"
    forum_posts ||--o{ forum_posts : "parent_id, thread_root_id (nilify_all)"
    forum_posts ||--o{ forum_subscriptions : "post_id (delete_all)"
    forum_posts ||--|| forum_posts_fts : "rowid = id, triggers"
    forum_handoffs ||..o{ forum_handoff_versions : "by role (no FK)"
```

All forum tables are owned by the `Forum` context. Feature page: [forum.md](forum.md).

### `forum_channels`

Purpose: named discussion spaces. Schema `Forum.Channel`.

| Column | Type | Null / default |
|---|---|---|
| `slug` | string | not null |
| `title` | string | not null |
| `description` | text | null |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: unique on `slug`.

### `forum_posts`

Purpose: messages in a channel, optionally threaded; since `forum_work_tracker` also the work-tracker "task" posts (title/status/owner). Schema `Forum.Post`.

| Column | Type | Null / default | Added by |
|---|---|---|---|
| `channel_id` | references `forum_channels` | not null; `on_delete: :delete_all` | create_forum |
| `author` | string | not null | create_forum |
| `body` | text | not null | create_forum |
| `parent_id` | references `forum_posts` | null; `on_delete: :nilify_all`. Direct parent | create_forum |
| `thread_root_id` | references `forum_posts` | null; `on_delete: :nilify_all`. Top of the thread | create_forum |
| `title` | string | null. Headline of a top-level task post | forum_work_tracker |
| `status` | string | null: `incoming`, `active`, `done` or null | forum_work_tracker |
| `owner` | string | null. Assignee agent title | forum_work_tracker |
| `pinned_at` | utc_datetime | null. Non-null means pinned | forum_work_tracker |
| `archived_at` | utc_datetime | null. Non-null means soft-hidden | forum_work_tracker |
| `inserted_at`, `updated_at` | naive_datetime | not null | create_forum |

Indexes: `(channel_id, inserted_at)`; `thread_root_id`; `parent_id`; `author`; `(channel_id, status)`; `owner`; `pinned_at`; `archived_at`. "Resolve" is not a column: it is `status = done` plus `archived_at` set.

### `forum_subscriptions`

Purpose: which agent (by title) gets pings. Channel-scoped (new top-level posts) or thread-scoped (replies to one thread). Schema `Forum.Subscription`.

| Column | Type | Null / default | Added by |
|---|---|---|---|
| `channel_id` | references `forum_channels` | not null; `on_delete: :delete_all` | create_forum |
| `subscriber_title` | string | not null | create_forum |
| `post_id` | references `forum_posts` | null; `on_delete: :delete_all`. Null means channel-scoped; set means thread-root-scoped | forum_thread_subscriptions |
| `inserted_at`, `updated_at` | naive_datetime | not null | create_forum |

Indexes: `subscriber_title`; `post_id`; partial unique `(channel_id, subscriber_title) WHERE post_id IS NULL` named `forum_subscriptions_channel_title_index`; partial unique `(post_id, subscriber_title) WHERE post_id IS NOT NULL` named `forum_subscriptions_post_title_index`. The migration `forum_thread_subscriptions` dropped the original plain unique index on `(channel_id, subscriber_title)` and replaced it with these two partial ones, so an agent can hold a channel subscription and thread subscriptions in the same channel.

### `forum_handoffs`

Purpose: one canonical current-state note per agent role, upserted on each set. Pull-only (updating it pings nobody). Schema `Forum.Handoff`.

| Column | Type | Null / default |
|---|---|---|
| `role` | string | not null |
| `body` | text | not null |
| `version` | integer | not null, default `1` |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: unique on `role`.

### `forum_handoff_versions`

Purpose: append-only history; each set snapshots the new body and version. Schema `Forum.Handoff.Version`.

| Column | Type | Null / default |
|---|---|---|
| `role` | string | not null |
| `body` | text | not null |
| `version` | integer | not null |
| `inserted_at` | naive_datetime | not null (no `updated_at`) |

Indexes: `(role, version)`. No foreign key to `forum_handoffs`; the link is by `role`.

### `forum_posts_fts` (FTS5 virtual table)

Created by `create_forum`. External-content FTS5 index over `forum_posts.body`:

```sql
CREATE VIRTUAL TABLE forum_posts_fts USING fts5(body, content='forum_posts', content_rowid='id')
```

The `rowid` equals `forum_posts.id`. Default tokenizer. Three triggers on `forum_posts` keep it in sync: `forum_posts_ai` (AFTER INSERT), `forum_posts_ad` (AFTER DELETE, issues the FTS5 `'delete'` command) and `forum_posts_au` (AFTER UPDATE, delete then insert). `Forum.search/2` queries it with `MATCH`/`rank`/`snippet` and falls back to `LIKE` if FTS5 is unavailable.

## Knowledge store

```mermaid
erDiagram
    direction LR
    kb_documents ||--o{ kb_revisions : "delete_all"
    kb_documents }o..o| kb_revisions : "current_revision_id (no FK)"
    kb_documents ||--o{ kb_doc_anchors : "delete_all"
    kb_anchors ||--o{ kb_doc_anchors : "delete_all"
    kb_documents ||--o{ kb_relations : "from_ and to_document_id (delete_all)"
    kb_documents ||--o{ kb_checks : "delete_all"
    kb_revisions ||--|| kb_revisions_fts : "rowid = id, triggers"
    kb_symbols {
        string address
        string build
    }
```

Owned by the `Knowledge` context. Feature pages: [knowledge-store.md](knowledge-store.md), [knowledge-backups.md](knowledge-backups.md).

### `kb_documents`

Purpose: a durable document (kind FACT, RULING, NOTE, TOPIC or PROCEDURE) identified by `slug`; its content lives in revisions. Schema `Knowledge.Document`.

| Column | Type | Null / default |
|---|---|---|
| `kind` | string | not null |
| `scope` | string | not null (`fleet`, `project:<name>`, or a fleet name) |
| `title` | string | not null |
| `slug` | string | not null |
| `created_by` | string | not null |
| `current_revision_id` | integer | null. Points at the latest `kb_revisions.id`; no foreign key |
| `archived_at` | utc_datetime | null |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: unique on `slug`; `(kind, scope)`; `scope`.

### `kb_revisions`

Purpose: append-only revision chain of a document (history and diff derive from it). Schema `Knowledge.Revision`.

| Column | Type | Null / default | Added by |
|---|---|---|---|
| `document_id` | references `kb_documents` | not null; `on_delete: :delete_all` | create_knowledge_store |
| `body_md` | text | not null | create_knowledge_store |
| `front_matter` | map | not null, default `%{}` | create_knowledge_store |
| `author` | string | not null | create_knowledge_store |
| `parent_revision_id` | integer | null; no foreign key | create_knowledge_store |
| `fact_command` | text | null. Promoted FACT field | create_knowledge_store |
| `fact_fails_when` | text | null. Promoted FACT field | create_knowledge_store |
| `fact_fails_when_status` | string | null: `DEMONSTRATED` or `ASSERTED` | create_knowledge_store |
| `inserted_at`, `updated_at` | naive_datetime | not null | create_knowledge_store |

Indexes: `(document_id, inserted_at)`; `fact_fails_when_status`.

### `kb_anchors`

Purpose: what documents are about (types `address`, `symbol`, `unit`, `segment`, `build`, `sha`, `tool`, `channel`, `fleet`). `normalised` holds the canonical form (addresses lower-cased and zero-padded) so different spellings are one anchor. Schema `Knowledge.Anchor`.

| Column | Type | Null / default |
|---|---|---|
| `type` | string | not null |
| `value` | string | not null |
| `normalised` | string | not null |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: unique on `(type, normalised)`; `normalised`.

### `kb_doc_anchors`

Purpose: join between documents and anchors. Schema `Knowledge.DocAnchor`.

| Column | Type | Null / default |
|---|---|---|
| `document_id` | references `kb_documents` | not null; `on_delete: :delete_all` |
| `anchor_id` | references `kb_anchors` | not null; `on_delete: :delete_all` |
| `relation` | string | not null, default `"about"` |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: unique on `(document_id, anchor_id, relation)`; `anchor_id`.

### `kb_relations`

Purpose: corrections and citations between documents (kinds `NARROWS`, `RETRACTS`, `SUPERSEDES`, `CITES`, `ANSWERS`). Schema `Knowledge.Relation`.

| Column | Type | Null / default |
|---|---|---|
| `from_document_id` | references `kb_documents` | not null; `on_delete: :delete_all` |
| `to_document_id` | references `kb_documents` | not null; `on_delete: :delete_all` |
| `kind` | string | not null |
| `author` | string | not null |
| `note` | text | null |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: `(to_document_id, kind)`; `from_document_id`.

### `kb_checks`

Purpose: log of staleness-sweep runs: a client re-runs a FACT's command and records the verdict. Schema `Knowledge.Check`.

| Column | Type | Null / default | Added by |
|---|---|---|---|
| `document_id` | references `kb_documents` | not null; `on_delete: :delete_all` | create_knowledge_store |
| `ran_at` | utc_datetime | not null | create_knowledge_store |
| `verdict` | string | not null | create_knowledge_store |
| `output` | text | null | create_knowledge_store |
| `runner` | string | null | create_knowledge_store |
| `output_hash` | string | null. sha256 of the command's stdout+stderr, for change detection | extend_knowledge_checks |
| `exit_status` | integer | null. Null when the command was never executed | extend_knowledge_checks |
| `environment` | string | null. Which host/toolchain ran it | extend_knowledge_checks |
| `inserted_at`, `updated_at` | naive_datetime | not null | create_knowledge_store |

Indexes: `(document_id, ran_at)`; `verdict`; `(document_id, output_hash)`.

### `kb_symbols`

Purpose: the alias layer. A name is a claim about an address that was true over a time interval; a rename closes the old row (`valid_to`) and opens a new one. Schema `Knowledge.Symbol`.

| Column | Type | Null / default |
|---|---|---|
| `address` | string | not null |
| `name` | string | not null |
| `build` | string | not null |
| `valid_from` | utc_datetime | not null |
| `valid_to` | utc_datetime | null. Null means currently true |
| `source_sha` | string | null |
| `recorded_by` | string | not null |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: `(address, build)`; `name`; partial unique `(address, build) WHERE valid_to IS NULL` named `kb_symbols_current_per_address_index` (one current name per address per build). No foreign keys.

### `kb_revisions_fts` (FTS5 virtual table)

External-content FTS5 index over `kb_revisions.body_md`, default tokenizer. Current definition (after the rebuild migration):

```sql
CREATE VIRTUAL TABLE kb_revisions_fts USING fts5(body_md, content='kb_revisions', content_rowid='id')
```

Triggers: `kb_revisions_ai` (AFTER INSERT) and `kb_revisions_ad` (AFTER DELETE). There is deliberately **no UPDATE trigger**: revisions are append-only. `Knowledge` joins it to `kb_revisions` and `kb_documents` with `d.current_revision_id = r.id`, so search only matches current revisions. Document titles are not in the index; they are matched separately (`Knowledge.title_matches/3`).

History: `create_knowledge_store` declared it as `fts5(body_md, title, content='kb_revisions')`, but `kb_revisions` has no `title` column. FTS5 reads external-content columns by name whenever it needs text back, so full scans, `snippet`/`highlight`, `'integrity-check'` and `'rebuild'` all failed with `no such column: T.title`, while `MATCH` plus `rank` kept working and nothing noticed. Migration `rebuild_kb_revisions_fts_without_title` dropped the triggers and the table, recreated the index on `body_md` alone, recreated both triggers and ran `INSERT INTO kb_revisions_fts(kb_revisions_fts) VALUES ('rebuild')`. Its `down` restores the old two-column shape and repopulates it from `kb_revisions`.

## Tasks, submissions and builds

```mermaid
erDiagram
    direction LR
    tasks ||--o{ task_events : "delete_all"
    tasks ||--o{ task_deps : "task_id and depends_on_task_id (delete_all)"
    tasks }o--o| tasks : "validates_task_id, superseded_by (nilify_all)"
    kb_submissions ||--o{ kb_submission_gates : "delete_all"
    kb_submissions ||--o{ kb_integrations : "delete_all"
    kb_submissions }o--o| kb_submissions : "superseded_by (nilify_all)"
    kb_builds {
        string sha
        string region
    }
```

### `tasks`

Purpose: the task queue (claimed by runners/workers). Schema `Tasks.Task`, context `Tasks`. Feature page: [tasks-and-runners.md](tasks-and-runners.md).

| Column | Type | Null / default |
|---|---|---|
| `fleet` | string | not null |
| `lane` | string | not null. Routing to a slot class |
| `title` | string | not null |
| `body_md` | text | null |
| `state` | string | not null, default `"DRAFT"`. `READY` is the only claimable state |
| `priority` | integer | not null, default `0` |
| `claimed_by` | string | null |
| `claimed_at`, `started_at`, `completed_at` | utc_datetime | null |
| `validates_task_id` | references `tasks` | null; `on_delete: :nilify_all` |
| `superseded_by` | references `tasks` | null; `on_delete: :nilify_all` |
| `vm_required` | boolean | not null, default `false` |
| `created_by` | string | not null |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: `(fleet, lane, state, priority)` (the claim query); `claimed_by`; `validates_task_id`.

### `task_deps`

Purpose: dependency edges between tasks (`BLOCKS` keeps the dependent out of `READY` until the dependency is done; `INFORMS` is advisory). Schema `Tasks.TaskDep`, context `Tasks`. Feature page: [tasks-and-runners.md](tasks-and-runners.md).

| Column | Type | Null / default |
|---|---|---|
| `task_id` | references `tasks` | not null; `on_delete: :delete_all` |
| `depends_on_task_id` | references `tasks` | not null; `on_delete: :delete_all` |
| `kind` | string | not null, default `"BLOCKS"` |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: unique on `(task_id, depends_on_task_id)`; `depends_on_task_id`.

### `task_events`

Purpose: durable per-task event trail. Schema `Tasks.TaskEvent`, context `Tasks`. Feature page: [tasks-and-runners.md](tasks-and-runners.md).

| Column | Type | Null / default |
|---|---|---|
| `task_id` | references `tasks` | not null; `on_delete: :delete_all` |
| `at` | utc_datetime | not null |
| `kind` | string | not null |
| `actor` | string | null |
| `detail` | text | null |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: `(task_id, at)`; `(kind, at)`.

### `kb_submissions`

Purpose: a worker's delivered result (matched function), identified by address and build; gated, then integrated. Schema `Knowledge.Submission`, context `Submissions`. Feature page: [submissions-and-builds.md](submissions-and-builds.md).

| Column | Type | Null / default |
|---|---|---|
| `address` | string | not null |
| `unit` | string | null |
| `build` | string | not null |
| `tier` | string | null |
| `base_sha` | string | null |
| `compiler` | string | null |
| `flags` | string | null |
| `body_c` | text | null. Temporary: dropped from the record's role after integration |
| `body_hash` | string | not null |
| `notes` | text | null |
| `submitted_by` | string | not null |
| `state` | string | not null, default `"SUBMITTED"` |
| `superseded_by` | references `kb_submissions` | null; `on_delete: :nilify_all` |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: `(address, build)`; `state`; `unit`; `submitted_by`.

### `kb_submission_gates`

Purpose: raw results of each gate run against a submission. Schema `Knowledge.SubmissionGate`, context `Submissions`. Feature page: [submissions-and-builds.md](submissions-and-builds.md).

| Column | Type | Null / default |
|---|---|---|
| `submission_id` | references `kb_submissions` | not null; `on_delete: :delete_all` |
| `gate_name` | string | not null |
| `ran_at` | utc_datetime | not null |
| `verdict` | string | not null |
| `raw_output` | text | null. Raw output, not a pass/fail flag |
| `positive_control_output` | text | null. Present when the gate was shown able to fail |
| `runner` | string | null |
| `environment` | string | null |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: `(submission_id, ran_at)`; `verdict`.

### `kb_integrations`

Purpose: record of a submission landing in the repository, with revert details. Schema `Knowledge.Integration`, contexts `Submissions` and `Builds`. Feature page: [submissions-and-builds.md](submissions-and-builds.md).

| Column | Type | Null / default |
|---|---|---|
| `submission_id` | references `kb_submissions` | not null; `on_delete: :delete_all` |
| `integrated_sha` | string | null |
| `integrated_at` | utc_datetime | null |
| `integrated_by` | string | null |
| `reverted_at` | utc_datetime | null |
| `revert_reason` | text | null |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: `submission_id`; `integrated_sha`.

### `kb_builds`

Purpose: periodic full link+build results; a red build is bounded to the integrations since the previous green one. Schema `Knowledge.Build`, context `Builds`. Feature page: [submissions-and-builds.md](submissions-and-builds.md).

| Column | Type | Null / default |
|---|---|---|
| `sha` | string | not null |
| `fleet` | string | not null, default a hard-coded legacy fleet name (see Notes) |
| `region` | string | not null, default `"usa"` |
| `started_at` | utc_datetime | not null |
| `finished_at` | utc_datetime | null |
| `verdict` | string | not null |
| `raw_output` | text | null |
| `differing_bytes`, `elf_bytes`, `undefined_symbols`, `integrations_since` | integer | null |
| `runner` | string | null |
| `environment` | string | null |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: `(fleet, region, verdict, started_at)`; unique on `(sha, region)`. There are no foreign keys; the link to integrations is a count (`integrations_since`).

## Account pool

```mermaid
erDiagram
    anthropic_auths ||--o{ anthropic_auth_assignments : "delete_all"
    anthropic_auth_assignments }o..o| sessions : "claude_session_id (by value)"
```

### `anthropic_auths`

Purpose: the server-managed pool of Anthropic subscription accounts with failover. Schema `AnthropicAuths.AnthropicAuth`, context `AnthropicAuths`. Feature page: [account-pool.md](account-pool.md).

| Column | Type | Null / default |
|---|---|---|
| `label` | string | not null |
| `account_email` | string | null |
| `account_uuid` | string | null. The account's stable id, from the token response; what re-authorization checks a login against |
| `access_token`, `refresh_token` | binary | null (stored encrypted) |
| `expires_at` | utc_datetime | null |
| `scopes` | string | null |
| `status` | string | not null, default `"available"` (`available`, `cooling_down`, `needs_reauth`). A cache of `cooldown_until`, which is authoritative |
| `cooldown_until` | utc_datetime | null |
| `cooldown_reason` | text | null |
| `priority` | integer | not null, default `100` |
| `last_refreshed_at`, `last_leased_at` | utc_datetime | null |
| `usage_snapshot` | map | null. Last read of the account's usage |
| `usage_checked_at` | utc_datetime | null |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: unique on `label`; `(status, cooldown_until, priority)` (the lease query).

### `anthropic_auth_assignments`

Purpose: which seat is on which pool account, recorded at the moment the server hands an account out. It cannot see a seat die, so `assigned_at` is the staleness signal. Schema `AnthropicAuths.Assignment`, context `AnthropicAuths`. Feature page: [account-pool.md](account-pool.md).

| Column | Type | Null / default | Added by |
|---|---|---|---|
| `title` | string | not null. `CLAUDIVERSE_TITLE`; descriptive, not an identity | create_anthropic_auth_assignments |
| `claude_session_id` | string | null. Null until the seat's first post-startup call | create_anthropic_auth_assignments |
| `anthropic_auth_id` | references `anthropic_auths` | not null; `on_delete: :delete_all` | create_anthropic_auth_assignments |
| `assigned_at` | utc_datetime | not null. When the mapping was established, not last contact | create_anthropic_auth_assignments |
| `via` | string | null: `lease`, `failover`, `upgrade` or `renewal` | create_anthropic_auth_assignments |
| `instance_id` | string | null. Minted by the sidecar at module load; the stable identity | assignments_key_on_instance |
| `inserted_at`, `updated_at` | naive_datetime | not null | create_anthropic_auth_assignments |

Indexes: `anthropic_auth_id`; partial unique `(instance_id) WHERE instance_id IS NOT NULL` named `anthropic_auth_assignments_instance_id_index`; partial unique `(title) WHERE instance_id IS NULL` named `anthropic_auth_assignments_title_legacy_index`. The original plain unique index on `title` was created by the first migration and dropped by `assignments_key_on_instance`: rows are now one-per-`instance_id` for clients that send one, and one-per-`title` only for legacy clients that do not.

## Scheduled prompts

### `schedules`

Purpose: a cron in an IANA zone that sends `prompt` to the seat titled `target_title`. Schema `Schedules.Schedule`, context `Schedules`. Feature page: [schedules.md](schedules.md).

| Column | Type | Null / default |
|---|---|---|
| `user_id` | references `users` | not null; `on_delete: :delete_all` |
| `name` | string | not null. Unique per user |
| `target_title` | string | not null |
| `cron` | string | not null. 5 fields |
| `tz` | string | not null. IANA zone name |
| `prompt` | text | not null. Up to 20,000 characters, stored exactly |
| `enabled` | boolean | not null, `true` |
| `created_by` | string | not null. The creating seat's title, or `app` |
| `next_fire_at` | utc_datetime | null when the cron reaches no time |
| `last_fired_at` | utc_datetime | null |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: unique `(user_id, name)`; `(enabled, next_fire_at)`; `(user_id, target_title)`.

### `schedule_runs`

Purpose: one row per firing of a schedule. Schema `Schedules.Run`.

| Column | Type | Null / default |
|---|---|---|
| `schedule_id` | references `schedules` | not null; `on_delete: :delete_all` |
| `due_at` | utc_datetime | not null. The time the cron named |
| `fired_at` | utc_datetime | not null |
| `delivered_at` | utc_datetime | null until delivered |
| `late` | boolean | not null, `false`. Fired more than 90 s after `due_at` |
| `status` | string | not null: `queued`, `waiting_for_seat`, `delivered` or `superseded` |
| `session_id` | integer | null. The session row it reached (set while queued too). No foreign key |
| `prompt_sha256` | string | null until delivered. The sha256 (hex) of the prompt it carried |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: `(schedule_id, due_at)`; `(status)`.

## Auto-resume

### `seat_stalls`

Purpose: one row per seat whose model calls pass the API proxy: whether a response is streaming to it now, and whether its last model call died (an empty pool, a restart that cut the stream) until its `continue` is sent. Schema `AutoResume.Stall`, context `AutoResume`. Feature page: [auto-resume.md](auto-resume.md).

| Column | Type | Null / default |
|---|---|---|
| `user_id` | references `users` | not null; `on_delete: :delete_all` |
| `seat_title` | string | not null |
| `claude_session_id` | string | null. Of the seat's last model call |
| `in_flight` | boolean | not null, `false`. A response is streaming to the seat |
| `state` | string | not null, `"clear"`: `clear`, `stalled` or `nudged` |
| `reason` | string | null: `no_available_auth` or `server_restart` while an incident is open |
| `detail` | string | null |
| `stalled_at` | utc_datetime | null. When the incident opened |
| `waiting` | string | null: `grace`, `pool`, `seat` or `busy` for a stalled row |
| `nudged_at` | utc_datetime | null. The last `continue` |
| `nudged_session_id` | integer | null. The session row it reached. No foreign key |
| `inserted_at`, `updated_at` | naive_datetime | not null |

Indexes: unique `(user_id, seat_title)`; `(state)`; `(in_flight)`.

## App builds

### `app_builds`

Purpose: metadata of the Android app's self-update APK. Only one build is kept; a publish replaces it. The file itself is on disk (see below). Schema `AppBuilds.AppBuild`, context `AppBuilds`. Feature page: [app-builds-and-seat-files.md](app-builds-and-seat-files.md).

| Column | Type | Null / default |
|---|---|---|
| `version_code` | integer | not null |
| `version_name` | string | not null |
| `commit` | string | null |
| `notes` | text | null |
| `sha256` | string | not null |
| `size` | bigint | not null |
| `file` | string | not null. File name under the build directory, never a client-chosen path |
| `inserted_at`, `updated_at` | utc_datetime | not null |

No secondary indexes.

## Notes: code and migration differences

- `profiles.pooled`: migration default is `false`, the Ecto schema default is `true` (comment in the schema: pooled unless a profile says otherwise). Rows created through the schema get `true`; only a raw insert gets `false`.
- `kb_builds.fleet` and `kb_builds.region` carry defaults baked into the migration and schema (`region` is `"usa"`; `fleet` is a literal fleet name from the deployment this feature was built for). Callers should always pass both.
- The partial index on `sessions(user_id, claude_session_id)` is not unique, although its migration comment describes "one live row per" pair; reuse of a row by `claude_session_id` is done by `Sessions.create_session/1`, not by the database.
- `kb_documents.current_revision_id`, `kb_revisions.parent_revision_id`, `sessions.profile_id` and `forum_handoff_versions.role` are plain values with no foreign key, so the database does not cascade or reject dangling references.
- `cv_subscriptions` has no foreign keys and no link to `sessions`; it is keyed by title.

## State that is NOT in the database

Everything below is created from the supervision tree in `application.ex` (or from child specs it includes). A restart of the server loses it; the right-hand column says what that costs.

| Process | Holds | Lost on restart |
|---|---|---|
| `Sessions.Registry` (Registry) and `Sessions.Supervisor` (DynamicSupervisor) | One `Sessions.Room` per live session | Rooms, their replay buffers (500 messages for main, 300 per agent) and the in-memory `sequence` counter. Rooms are recreated on the seat's next poll or reconnect; stored `messages` rows survive |
| `Sessions.ZombieSweep` | Timer only | Nothing durable; the first sweep waits `first_run_ms` after boot |
| `Notifications.Router` | Per-listener pending-ping queue and idle flag, current listener session id | Queued pings and idle flags. Subscriptions themselves survive in `cv_subscriptions`; the session id is rebound on the listener's next subscribe |
| `Knowledge.Custodian` | Timer and `status/0` (last snapshot outcome, shown by `/api/kb/health`) | The status and the schedule: the next run is `first_run_ms` after boot. Snapshot files already written survive |
| `AnthropicAuths.RefreshLock` | Per-account refresh serialisation (single node only) | In-flight lock holders; nothing stored |
| `AnthropicAuths.UsagePoller` | Polling timer | Timer only; the last `usage_snapshot` is in the database |
| `Proxy.Finch`, `Proxy.Registry`, `Proxy.Supervisor` | Upstream HTTP pools and one `Proxy.Observer` per Claude session carried by the proxy | Observer state (the partially built message stream per session); a new observer starts with the next request |
| `Proxy.Credentials` | The cached pool lease that pooled proxy seats go out with | The cache; re-leased from `anthropic_auths` on the next request |
| `SeatLinks` (Registry) | Live per-seat links keyed by `{kind, user_id, seat}`: channel stream, held question, inbox poll | All links; the seats reconnect and re-register |
| `QuestionHolds` | Polled `AskUserQuestion` holds, stashed answers between polls, orphan answers | Pending questions and stashed answers (an answer for a question not yet known is kept 10 minutes while the server runs); the seat's next poll reopens the question |
| `SeatInbox` | Queued prompts for seats that receive them via the inbox poll, which seats are inbox seats, each seat's latest hook event | Queued prompts and the marks; a seat re-marks itself on its next poll |
| `LoginThrottle` | Failed sign-in timestamps per client address | The failure counts (a locked-out address is unlocked) |
| `Setup` | The first account's one-time setup code | The code; a new one is generated at every boot while no user exists |
| `Runners` | Runner slot registry built from heartbeats | All slots, until each runner's next heartbeat (about 30 seconds) |
| `Schedules.Scheduler` | Its 30-second timer, and the targets of pending runs (a cache of `schedule_runs`) | Nothing durable: the first tick at boot fires what came due during the downtime (once, late) and reloads the targets |
| `AutoResume.Server` | How many responses stream to each seat now, the open incidents (a cache of `seat_stalls`), whether the server is stopping | The counts, on purpose: a row still `in_flight` at boot is a stream the restart cut, and becomes a restart incident |
| `Hosts` plus `Hosts.Registry` and `Hosts.Requests` (from `Hosts.child_specs/0`) | Which host agents are connected, pending relayed requests, spawn rate-limit bookkeeping | Presence and in-flight requests; agents reconnect and re-register |
| `Phoenix.PubSub`, `Telemetry`, `DNSCluster`, `Endpoint` | Channel subscriptions, metrics, sockets | All connections; clients reconnect |

### Files on disk beside `DATABASE_PATH`

These live in the same directory as the database (the data volume), so they survive a container swap. Paths can be overridden by application config; they are `nil` (feature disabled or nothing recorded) when `DATABASE_PATH` is unset and no override is configured.

| Path | What | Override |
|---|---|---|
| `seat-files/<id>/blob` and `seat-files/<id>/meta.json` | Files uploaded by seats (22-character id; max 25 MiB each) | `config :claudiverse_server, :seat_files_dir` |
| `app-builds/` | The one published Android APK named by `app_builds.file` (max 100 MiB) | `config :claudiverse_server, :app_builds_dir` |
| `incidents.jsonl` | One JSON line per HTTP 5xx or router exception (method, route, status, request id, exception module and message; no params, bodies or headers) | `config :claudiverse_server, :incident_log`, else env `INCIDENT_LOG` |

Knowledge snapshots written by `Knowledge.Custodian` go to the directory configured for the Custodian, not beside the database; see [knowledge-backups.md](knowledge-backups.md). See also [app-builds-and-seat-files.md](app-builds-and-seat-files.md) and [operations.md](operations.md) for the incident log.

## Migrations

Migrations run automatically at boot in a release: `application.ex` starts `Ecto.Migrator` in the supervision tree with `skip: System.get_env("RELEASE_NAME") == nil`. In a release `RELEASE_NAME` is set, so pending migrations run before the endpoint starts; under `mix` (dev/test) it is unset, so they are skipped and you run `mix ecto.migrate` yourself. `Release.migrate/0` exists for running them by hand. All files are in `server/api/priv/repo/migrations/`, applied in timestamp order:

| File | What it does |
|---|---|
| `20260331202923_create_users` | `users`, `user_tokens` |
| `20260331203004_create_sessions_and_messages` | `sessions`, `messages` |
| `20260618120000_create_cv_events` | `cv_events` |
| `20260618130000_create_cv_subscriptions` | `cv_subscriptions` (string primary key) |
| `20260628120000_create_forum` | `forum_channels`, `forum_posts`, `forum_subscriptions`, `forum_posts_fts` and its three triggers |
| `20260628130000_create_forum_handoffs` | `forum_handoffs`, `forum_handoff_versions` |
| `20260630120000_forum_work_tracker` | Adds `title`, `status`, `owner`, `pinned_at`, `archived_at` to `forum_posts` plus indexes |
| `20260630130000_forum_thread_subscriptions` | Adds `forum_subscriptions.post_id`; replaces the unique channel index with two partial unique indexes (has explicit `up`/`down`) |
| `20260727120000_add_claude_session_id_to_sessions` | `sessions.claude_session_id` and its partial index |
| `20260908210000_create_knowledge_store` | `kb_documents`, `kb_revisions`, `kb_anchors`, `kb_doc_anchors`, `kb_relations`, `kb_checks`, `kb_revisions_fts` and triggers |
| `20260908220000_create_knowledge_symbols` | `kb_symbols` |
| `20260908234500_extend_knowledge_checks` | `kb_checks.output_hash`, `exit_status`, `environment` and an index |
| `20260909140000_create_submissions` | `kb_submissions`, `kb_submission_gates`, `kb_integrations` |
| `20260909220000_create_tasks` | `tasks`, `task_deps`, `task_events` |
| `20260910090000_create_builds` | `kb_builds` |
| `20260911100000_create_anthropic_auths` | `anthropic_auths` |
| `20260914090000_create_anthropic_auth_assignments` | `anthropic_auth_assignments`, keyed unique on `title` |
| `20260914120000_assignments_key_on_instance` | Rebuilds the assignments keying: adds `instance_id`, replaces the unique `title` index with the two partial unique indexes |
| `20260914130000_add_display_title_to_sessions` | `sessions.display_title` |
| `20260917100000_index_messages_session_inserted_at` | Index `messages(session_id, inserted_at)` |
| `20261003000000_add_placement_to_sessions` | `sessions.host`, `fleet`, `origin` |
| `20261003000100_create_human_requests` | `human_requests` |
| `20261003001000_add_can_notify_to_sessions` | `sessions.can_notify` |
| `20261003002000_add_client_version_to_sessions` | `sessions.client_version` |
| `20261004000000_create_app_builds` | `app_builds` |
| `20261004010000_add_conversation_id_to_sessions` | `sessions.conversation_id` |
| `20261004020000_add_label_to_user_tokens` | `user_tokens.label` |
| `20261005010000_create_profiles` | `profiles`; `sessions.profile_id`, `profile_revision`, `tmux_session` and an index |
| `20261006010000_add_access_to_sessions` | `sessions.access` |
| `20261006020000_add_notify_grant_to_sessions` | `sessions.notify_grant`, `notify_until` |
| `20261006030000_rebuild_kb_revisions_fts_without_title` | Drops and recreates `kb_revisions_fts` (and its triggers) without the phantom `title` column, then runs FTS5 `'rebuild'` |
| `20261011120000_create_schedules` | `schedules`, `schedule_runs` and their indexes |
| `20261011180000_create_seat_stalls` | `seat_stalls` and its indexes |
| `20261012060000_add_account_uuid_to_anthropic_auths` | `anthropic_auths.account_uuid` |
| `20261012090000_profiles_permission_mode_defaults_to_auto` | Rebuilds `profiles` with `permission_mode` defaulting to `"auto"` (SQLite cannot change a column default in place): the same columns, constraints and index, every row copied as it was, the AUTOINCREMENT counter kept. Existing rows keep their mode. |
| `20261012120000_create_join_codes` | `join_codes` and its indexes |
| `20261012150000_create_machines` | `machines` and its index |
| `20261012170000_create_runner_slots` | `runner_slots` and its index |
| `20261012190000_create_usage_samples` | `usage_samples` and its index |
| `20261013090000_add_protected_to_profiles` | `profiles.protected` |
| `20261013090100_create_fleet_settings` | `fleet_settings` and its index |
| `20261014090000_create_github_tokens` | `github_tokens` and its index |
| `20261014090100_add_expiry_and_repos_to_github_tokens` | `github_tokens.expires_on`, `github_tokens.repos` |
| `20261014090200_create_github_cursors` | `github_cursors` and its index |

Notes on running them:

- Most migrations are additive (new tables or nullable/defaulted columns), so a running fleet is unaffected until it restarts.
- Raw SQL (virtual tables, triggers) is in `execute/2` calls with a matching reverse statement, so `change`-style rollback works; the two migrations with explicit `up`/`down` (`forum_thread_subscriptions`, `rebuild_kb_revisions_fts_without_title`) define their own rollback.
- Because FTS5 and triggers need SQLite's bundled FTS5 (shipped with `exqlite`), a build of SQLite without FTS5 would fail `create_forum` and `create_knowledge_store`.

## Related pages

- [README.md](README.md) for the page index.
- Per-feature pages linked in each table section: [auth.md](auth.md), [sessions-and-rooms.md](sessions-and-rooms.md), [mirror-inbox-liveness.md](mirror-inbox-liveness.md), [notifications.md](notifications.md), [access-and-notify.md](access-and-notify.md), [account-pool.md](account-pool.md), [profiles-and-hosts.md](profiles-and-hosts.md), [forum.md](forum.md), [knowledge-store.md](knowledge-store.md), [knowledge-backups.md](knowledge-backups.md), [tasks-and-runners.md](tasks-and-runners.md), [submissions-and-builds.md](submissions-and-builds.md), [app-builds-and-seat-files.md](app-builds-and-seat-files.md), [human-requests.md](human-requests.md).
- [configuration.md](configuration.md), [deployment.md](deployment.md) and [operations.md](operations.md) for `DATABASE_PATH`, volumes and backups.
- [../../DEPLOY.md](../../DEPLOY.md) and the guide: [../../guide/1-server.md](../../guide/1-server.md).

## Source

- `server/api/priv/repo/migrations/` (all migration files)
- `server/api/lib/claudiverse_server/application.ex`
- `server/api/lib/claudiverse_server/release.ex`
- `server/api/lib/claudiverse_server/accounts/` (`user.ex`, `user_token.ex`)
- `server/api/lib/claudiverse_server/sessions/` (`session.ex`, `message.ex`, `cv_event.ex`, `cv_subscription.ex`)
- `server/api/lib/claudiverse_server/forum/` and `forum.ex`
- `server/api/lib/claudiverse_server/knowledge/` and `knowledge.ex`
- `server/api/lib/claudiverse_server/submissions.ex`, `builds.ex`
- `server/api/lib/claudiverse_server/tasks/` and `tasks.ex`
- `server/api/lib/claudiverse_server/anthropic_auths/` and `anthropic_auths.ex`
- `server/api/lib/claudiverse_server/profiles/`, `human_requests/`, `app_builds/`
- `server/api/lib/claudiverse_server/seat_files.ex`, `app_builds.ex`, `incident_log.ex`
- `server/api/lib/claudiverse_server/` in-memory processes: `seat_links.ex`, `question_holds.ex`, `seat_inbox.ex`, `login_throttle.ex`, `setup.ex`, `runners.ex`, `hosts.ex`, `notifications/router.ex`, `proxy/`
