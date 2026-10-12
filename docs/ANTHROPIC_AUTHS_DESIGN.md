# AnthropicAuths — server-managed account pool with failover

**Status: BUILT, not yet deployed.** Server, panel and runner integration are in
and locally verified. Nothing has run against a real Anthropic account — the one
thing that cannot be tested until an account is enrolled.

🔴 **THE CLIENT NEEDS NO PATCH.** The largest simplification came late and
deleted a third of this design. `CLAUDE_CODE_OAUTH_TOKEN` already exists
upstream: when set, `getClaudeAIOAuthTokens()` returns a record with
`refreshToken: null`, so `refreshOAuthTokenWithLock` returns `no_refresh_token`
and never posts. Local refresh is structurally impossible.
MEASURED, not read — a bogus value gives
`401 OAuth access token is invalid` and does NOT fall back to the working
keychain token, so both precedence and suppression hold.
⇒ The runner leases a token and sets one env var. Zero injection points, nothing
to re-author per release. For the record the real refresh lives at
`services/oauth/client.js:138`, gated by `checkAndRefreshOAuthTokenIfNeeded`
(`utils/auth.js:9907`), lazy on expiry and on 401 — there is no timer.

**Supersedes:** `patch-ref/patches.d/004-multi-account-failover.patch.disabled`
(disabled since 2026-06-09), which put a 30 KB disk-backed credential store in
the client and needed six injection points across three files. This design moves
the state to the server and gets the client surface down to one or two.

---

## The problem

The fleet runs ~17 seats against Anthropic subscription accounts. Rate limits are
per-account, so a busy window rate-limits every seat at once. There are two
accounts available; nothing currently knows about the second one.

Today there is also **no per-seat credential isolation at all** — every seat
shares one `~/.claude`. (MEASURED: no `CLAUDE_CONFIG_DIR` anywhere in
`cv-spawn.sh` or `cv-runner.mjs`.)

## Naming

**`AnthropicAuths`.** The server already has an `Accounts` context and it means
something else entirely — Phoenix email/password login for the web UI, with
`Accounts.User` and `Accounts.UserToken`. Reusing "account" for Anthropic
credentials would collide in the one place people grep.

---

## Decisions, with recommendations

### 1. The server stores full credentials — RECOMMENDED, and decided

The alternative was assignment-only: the server tracks which account is healthy
and hands out a *pointer*, while tokens stay in each machine's keychain. That
avoids building a vault at the cost of a one-time `claude login` per account per
machine.

**Decision: vault.** The operator's call — this is a private, self-hosted,
single-operator deployment, so the vault's main downside (a network-reachable
store of live credentials) is bounded by a threat model the operator owns
entirely. The upside is real: a new machine hosts seats with no local login step,
and there is exactly one place to look when an account misbehaves.

Encrypt at rest with a key from the environment (Cloak, or `:crypto` directly) —
cheap, and it keeps tokens out of casual `psql` output and backups.

### 2. The server is the ONLY thing that refreshes — RECOMMENDED, non-negotiable

**Refresh tokens MAY rotate.** ⚠️ Correcting an overstatement in the first draft
of this doc, which asserted they always do. The reference implementation writes
`token_data.get("refresh_token", refresh_token)` — defensively keeping the old
token when the response omits a new one. So the response *sometimes* carries a
replacement and sometimes does not.

The recommendation is unchanged, and the weaker premise is still sufficient:

- if it rotates, a client-side refresh silently kills the server's copy;
- if it does not, a client-side refresh accomplishes nothing the server did not
  already do.

Either way the client has no reason to hold the refresh token, and one arm is
catastrophic. When it does desync, the failure is invisible: the panel keeps
showing the account `available` while every seat on it is one expiry from dying.

⇒ When server-managed, the client's local refresh path is suppressed
unconditionally.

Serialise refresh **per auth** — a `GenServer` keyed by auth id, or
`SELECT … FOR UPDATE`. Two seats leasing simultaneously at expiry is enough to
break an account without it.

### 3. Mode is decided once at startup and is STICKY — RECOMMENDED

Separate two things that are easy to conflate:

- **mode** — server-managed vs local. Decided at launch from the presence of
  `CLAUDIVERSE_TOKEN`. Immutable for the life of the process.
- **reachability** — fluctuates. Affects only whether a *lease* succeeds.

If mode were re-evaluated per call, a dropped packet would flip a seat into local
mode mid-session, it would refresh locally, and it would desync the account
(§2) — a global failure caused by a transient local one.

Log the resolved mode once at startup. A seat in the wrong mode should be visible
rather than inferred.

### 4. Without a token, behave exactly like stock — RECOMMENDED

No `CLAUDIVERSE_TOKEN` ⇒ no lease, no failover, stock keychain, stock local
refresh. Same pattern the sidecar already uses (`if (!TOKEN) return;` in
`SidecarClient.js`). Someone running the binary by hand sees zero behavioural
change, and the patch is inert rather than merely quiet.

### 5. On unreachable-at-expiry, FAIL LOUD — RECOMMENDED

This is the interaction between §2 and §4, and it is the sharpest decision here.
If local refresh is disabled *because* we are server-managed, and the server then
goes unreachable, an expiring seat has no path to a valid token.

The tempting fallback — refresh locally just this once — is the worst available
option, because it rotates the token **exactly when the server cannot observe
that it happened**.

```
seat dies at expiry        ->  ONE seat. Obvious, restartable.
local-refresh fallback     ->  EVERY seat on that account. Silent.
                               Panel still reports healthy.
```

Choose on blast radius. A dead seat is cheap; a silently-dead account that
reports healthy is expensive and hard to diagnose.

### 5b. Prefer PROACTIVE routing over waiting for a 429 — RECOMMENDED

The reference implementation reads an endpoint the original design did not know
existed:

```
GET https://api.anthropic.com/api/oauth/usage
    Authorization: Bearer <token>
    anthropic-beta: oauth-2025-04-20
```

It returns session and weekly usage percentages, reset timestamps, a weekly
*pace*, per-model (Sonnet) breakdown, and extra-usage state — the exact inputs an
account chooser wants.

That upgrades failover from reactive to informed. Rather than discovering a limit
by taking a 429 on a real request and burning that turn, the server can poll both
accounts on a slow interval and lease the one with headroom. Keep the 429 path as
the backstop — polling is a cache and can be stale — but do not make it the only
signal.

It also gives the panel something worth showing: live usage per account, not just
`available` / `cooling_down`.

⚠️ UNVERIFIED: whether a token minted with Claude Code's client id and scopes is
accepted by this endpoint. The reference uses a different client with
`user:profile`. Cheap to test once one account is stored, and worth testing
before designing the chooser around it.

### 6. Failover mostly needs no in-process machinery — RECOMMENDED

`cv-runner.mjs` reaps only on `cv_task_done` (its header states this explicitly:
it never reaps on idleness, elapsed time or silence). So an **ephemeral worker**
that hits a 429 reports it, finishes, dies, and the next spawn leases the healthy
account. No credential swapping, no cache invalidation, no patch.

Only **long-lived seats** — watcher, orchestrator — need a mid-session swap.
Build the ephemeral path first; it covers most of the fleet and is strictly
simpler.

### 7. Per-seat isolation via `CLAUDE_CONFIG_DIR` — VERIFIED, and now unused

⚠️ Kept for the record: this was going to be how seats got isolated credentials,
and it works. It became unnecessary once `CLAUDE_CODE_OAUTH_TOKEN` turned out to
suppress local refresh outright — an env-var token needs no per-seat config dir
at all. Still the right mechanism if a future design needs isolated local
logins.

`Rre()` in `utils/secureStorage/macOsKeychainHelpers.js` builds the keychain
**service name** and appends `-<sha256(configDir)[0..8]>` when
`CLAUDE_CONFIG_DIR` (or `CLAUDE_SECURESTORAGE_CONFIG_DIR`) is set:

```
CLAUDE_CONFIG_DIR=/cv/auth/a  ->  keychain "Claude Code-3f2a91bc"
CLAUDE_CONFIG_DIR=/cv/auth/b  ->  keychain "Claude Code-8d14e0f7"
```

If that reading holds, per-account isolation is an upstream feature reachable
with an env var and **no patch at all** — which is what old 004 built a disk
store to provide.

✅ **VERIFIED 2026-09-11 by running it**, not by reading it:

```
control, no env var                 -> exit 0, "OK"                     (logged in)
CLAUDE_CONFIG_DIR=/tmp/cv-authprobe-a -> exit 1, "Not logged in · /login" (isolated)
control re-run afterwards           -> exit 0, "OK"     (default store undamaged)
```

The control matters: without it, the failure arm proves nothing. The default
namespace was re-tested after the probe and is unharmed, so this is safe to do on
a machine with a live login.

---

## Schema

```
anthropic_auths
  id                 uuid
  label              string      -- "max-primary" / "max-secondary"
  account_email      string      -- display only, so the panel is legible
  access_token       binary      -- encrypted
  refresh_token      binary      -- encrypted
  expires_at         utc_datetime
  scopes             string
  status             enum        -- available | cooling_down | needs_reauth
  cooldown_until     utc_datetime
  cooldown_reason    string      -- the 429 text, kept for diagnosis
  priority           integer
  last_refreshed_at  utc_datetime
  timestamps()
```

`status` is derived-ish but stored, because the panel needs to render it without
recomputing. Keep `cooldown_until` authoritative and treat `status` as a cache of
it — a stored status that nothing re-checks is how a field starts lying.

## API

```
POST /api/anthropic_auths/lease
  -> {auth_id, access_token, expires_at, label}
  Picks highest-priority `available`. Refreshes under lock if stale.

POST /api/anthropic_auths/:id/rate_limited  {resets_at, reason}
  -> {next: {...} | null}
  Marks cooling_down. Returns the next usable auth, or null if none.

POST /api/anthropic_auths/:id/unauthorized
  -> {access_token, expires_at} | {status: "needs_reauth"}
  Forces one refresh under lock. On failure, marks needs_reauth and surfaces it
  in the panel — a seat should never be the only thing that knows.
```

All three are authenticated with `CLAUDIVERSE_TOKEN`, same as the sidecar.

## Web panel: adding an account

There is a **working open-source reference** for this exact flow:
`trickv/hass-claude-usage`, a Home Assistant integration that authenticates
against Anthropic with the paste-the-code OAuth flow. It confirms the shape and
supplies concrete values, so this does not have to be derived from the bundle.

```
AUTHORIZE_URL   https://claude.ai/oauth/authorize
TOKEN_URL       https://console.anthropic.com/v1/oauth/token     <- console, not api
REDIRECT_URI    https://console.anthropic.com/oauth/code/callback
beta header     anthropic-beta: oauth-2025-04-20
```

⚠️ It uses **its own** `client_id` with scope `user:profile` — enough for usage
and profile, not for inference. We need Claude Code's client id
(`22422756-60c9-4084-8eb7-27705fd5cf9a`, from `constants/oauth.js`) and its
scopes. The FLOW transfers; the client identity does not.

Exchange payload (`POST` JSON to `TOKEN_URL`):

```json
{"grant_type": "authorization_code", "code": "...", "state": "...",
 "client_id": "...", "redirect_uri": "...", "code_verifier": "..."}
```

Refresh payload:

```json
{"grant_type": "refresh_token", "refresh_token": "...", "client_id": "..."}
```

🔑 **The pasted code arrives as `code#state`** — split on `#`, use the first part
as the code and validate the second against the `state` you generated. Miss this
and the exchange fails with an opaque error.

Authorize URL params: `code_challenge`, `code_challenge_method=S256`, `state`.

Use the **paste-the-code** variant, which needs no redirect URI registered
against a domain you do not control:

1. Panel generates a PKCE verifier + challenge, builds the authorize URL.
2. Operator opens it, logs into the target Anthropic account, copies the code.
3. Operator pastes the code into the panel.
4. Server exchanges code + verifier at `TOKEN_URL`, stores tokens encrypted.
5. Account appears as `available`.

The panel should also expose: current status per account, `cooldown_until`,
which sessions currently hold a lease, and a re-auth button for `needs_reauth`.

## Client integration — the binary leases itself

🔴 **SUPERSEDES the spawn-wrapper approach below.** `cv-spawn.sh` used to lease
and pass `CLAUDE_CODE_OAUTH_TOKEN` on the launch line. That only ever covered
sessions launched through that one script — a hand-launched seat or a long-lived
one like the watcher kept using the local keychain, silently.

`SidecarClient.js` now leases at module init whenever `CLAUDIVERSE_TOKEN` is set.
One mechanism, every session. The `cv-spawn` version was REMOVED rather than kept
as a second path: two mechanisms doing the same job drift, and the one being
removed covered a strict subset.

### Why it must be synchronous

`getClaudeAIOAuthTokens` is MEMOIZED and reads `process.env` on its FIRST call.
An async lease races the first API request — and if the local keychain still
holds valid credentials, that request simply SUCCEEDS on them, the memo fills,
and the pool is never used.

⚠️ That failure mode is not an error. It is everything appearing to work while
the feature does nothing, on a machine that is already logged in — i.e. every
developer machine. So the lease is a blocking `curl` at module init: ~100ms,
once, only when connected.

### Degradation

```
no CLAUDIVERSE_TOKEN            -> no lease, stock keychain, fully inert
CLAUDE_CODE_OAUTH_TOKEN preset  -> respected, no lease (explicit wins)
server unreachable / no curl    -> logged, falls through to local credentials
pool exists but all cooling     -> logged, falls through to local credentials
```

That last row deliberately differs from what `cv-spawn` did (refuse to spawn). A
human at a terminal should not be blocked by pool state, and the local keychain
account is usually one of the pooled ones anyway — so it fails at the API with a
real rate-limit message instead of a confusing startup abort.

## Client integration (historical — spawn wrapper)

**Spawn path (no patch).** The runner leases before spawning and writes the
leased credentials into a per-seat `CLAUDE_CONFIG_DIR`. Requires probe (1).

**In-session path (1-2 injection points).** On 401/429: report to claudiverse,
re-lease, rewrite the credential file, clear the cached accessor. Old 004's
`getClaudeAIOAuthTokens.cache.clear()` is the right shape; the cache-clear
primitive already exists.

Patches must be **anchor-driven** — no minified identifier on any added line.
That constraint is not stylistic: all nine chunked patches failed on a single
upstream version step before they were re-authored against anchored names.

## Behaviour table

```
no token                  -> stock. local keychain, local refresh, no failover
token + reachable         -> lease, server refresh, server failover
token + unreachable       -> retry, then FAIL LOUD. never refresh locally
token + all auths cooling -> fail with the earliest cooldown_until, so the
                             operator sees WHEN rather than just THAT
```

## What is measured and what is not

**MEASURED**
- Server-side `Accounts` is Phoenix user auth, not Anthropic accounts — the
  naming collision is real.
- No per-seat credential isolation exists today.
- `Rre()` appends a `sha256(configDir)` suffix to the keychain service name.
- OAuth constants and PKCE are present and sufficient to run the flow.
- `cv-runner.mjs` reaps only on `cv_task_done`.
- Old 004: six injection points across three files; `MultiAccountManager.js` is
  30,796 bytes.
- `trickv/hass-claude-usage` implements this OAuth flow end to end and supplies
  concrete endpoints, payload shapes, the `code#state` separator, the
  `anthropic-beta: oauth-2025-04-20` header, and a usage endpoint. Read from
  source on 2026-09-11.

- **`CLAUDE_CONFIG_DIR` isolates the credential store.** VERIFIED by running it
  with a control on both arms (see §7). The no-patch spawn path is viable.

**NOT MEASURED**
1. **Claude's own refresh call site is UNLOCATED.** The `utils/auth.js` hits are
   vendored Google auth (`oauth2TokenUrl`, `client_secret`), not Claude's flow.
   §2's suppression cannot be implemented until it is found — this is the real
   blocker on the in-session path.
2. That a mid-process credential swap takes effect.
2b. That `api/oauth/usage` accepts a token minted with Claude Code's client id
   and scopes (§5b). The reference uses a different client.
3. **That the refresh lock holds under concurrent lease.** ⚠️ Correcting an error
   in the first draft of this doc: this was listed as a probe to run *before*
   building, but it tests an endpoint that does not exist yet. It is a test to
   write *alongside* step 3, not a prerequisite. The failure is silent and
   cascading, so it needs a deliberate two-seats-at-expiry case rather than an
   incidental one.

## Build order — done

1. ~~Probe `CLAUDE_CONFIG_DIR` isolation~~ — verified §7.
2. ~~Context, schema, encryption~~ — `anthropic_auths.ex`, `anthropic_auth.ex`,
   `vault.ex`, migration `20260911100000`.
3. ~~Endpoints + per-auth refresh lock~~ — `anthropic_auth_controller.ex`,
   `refresh_lock.ex`, 8 routes.
4. ~~Panel~~ — `server/web/src/pages/AccountsPage.tsx` at `/accounts`.
5. ~~Runner integration~~ — `cv-spawn.sh` leases and sets
   `CLAUDE_CODE_OAUTH_TOKEN`.
6. ~~Locate Claude's refresh site~~ — found, and made moot by the env var.
7. ~~Usage poller~~ — `usage_poller.ex`. Not just a nicer panel: it is how a
   rate limit gets noticed at all, since stock seats cannot report a 429.

### Verified locally

```
vault      roundtrip · IV varies · TAMPERED ciphertext -> nil (GCM auth)
           garbage -> nil · missing key RAISES · short key RAISES
context    lease picks lowest priority · returns DECRYPTED token
           DB holds ciphertext · exclude_ids · cooling skipped
           elapsed cooldown leasable again
           changeset REJECTS cooling_down without a timestamp
lock       8 concurrent same-id -> 0 overlaps · 4 ids parallel (201ms)
           a raising refresh returns an error AND the lock survives
poller     over+reset -> cooled · over WITHOUT reset -> NOT cooled
           under -> untouched · cooled account excluded from lease
routes     all 8 resolve · panel typechecks and builds
```

### Not verified, and cannot be until an account is enrolled

- That the OAuth exchange succeeds against Anthropic with Claude Code's client
  id and the scopes in `oauth.ex`.
- That `api/oauth/usage` accepts a token minted with that client id (§5b). The
  reference uses a different client with `user:profile`. If it does not,
  proactive routing degrades to reactive and everything else still works.
- The real shape of the usage response. The panel reads optional keys and
  renders anything missing as "unknown" rather than 0%, so a shape surprise
  degrades visibly instead of silently.

### Deployment

Needs `CV_VAULT_KEY` (base64 of 32 bytes) in the server environment. Without it
the pool reports itself unconfigured in the panel and refuses to store anything —
it never falls back to plaintext.
