# cv-mcp: scheduled prompt tools

`cv_schedule_add`, `cv_schedule_list`, `cv_schedule_get`, `cv_schedule_pause`, `cv_schedule_resume`, `cv_schedule_remove` and `cv_schedule_runs` let a seat schedule a prompt to itself on a cron. The server keeps the schedule and fires it, so it survives seat restarts, compactions, reboots and server deploys, with no expiry. Claude Code's own `CronCreate` lasts one session and at most 7 days. How the server fires and delivers is in [schedules.md](../server/schedules.md). See [mcp.md](mcp.md) for the cv-mcp overview.

The tools are in the `full` group: every role but a worker.

## How it works

- **A seat schedules for itself.** Each call sends the seat's own title as `self`. The server lets a seat create, list and manage only schedules whose target is its own title; `target` defaults to it. A cv-mcp configured with an `app` token may target any seat.
- **The prompt is the whole brief.** A schedule may fire into a brand-new seat with no context, so the prompt should stand alone. Up to 20,000 characters (code points, not bytes), stored and delivered exactly. The tools never cut it: the list shows its length, sha256 and first 120 characters, and `cv_schedule_get` prints all of it.
- **Refusals read as refusals.** Every server refusal comes back as `REFUSED (HTTP <status>): could not <what>: <the server's reason>`, never as success.
- **Delivery.** At each due time the seat receives, as a user prompt:

  ```text
  [claudiverse] scheduled prompt "weekly-review" (due Sun 2026-10-18 12:00 CEST (Europe/Oslo)):
  <the prompt, exactly>
  ```

  A due time missed while the server was down fires once, with `, LATE: fired <time> after downtime` in the header. A busy seat gets it when it next goes idle; a seat that is not running gets it when it next starts. If it is still pending at the next occurrence, the newer one replaces it.

## Configuration

None of their own. They use cv-mcp's server URL, token and seat identity (see [mcp.md](mcp.md)). The default time zone is `Europe/Oslo`.

## Interface

Every tool result ends with a blank line and cv-mcp's timestamp line; the texts below omit it. `schedule` arguments take the schedule's id or its name.

### cv_schedule_add

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `name` | string | yes | Short and unique per user: 1 to 64 of `A-Z a-z 0-9 . _ -`, not all digits. |
| `cron` | string | yes | 5 fields: minute hour day-of-month month day-of-week. `0 12 * * 0` is Sundays at 12:00. |
| `tz` | string | no | The IANA zone the cron is read in. Default `Europe/Oslo`. 12:00 stays 12:00 local across daylight saving. |
| `prompt` | string | yes | The whole brief, up to 20,000 characters. |
| `target` | string | no | The seat title. Defaults to this seat; a seat can only target itself. |

Calls `POST /api/schedules`. On success it compares the sha256 of the prompt it sent with the one the server stored:

```text
scheduled: #2 weekly-review → ipsum-admin · 0 12 * * 0 (Europe/Oslo) · on · next Sun 2026-10-18 12:00 CEST (Europe/Oslo)
  prompt: 9500 chars, 9500 bytes, sha256 63c177fd4eef · "Weekly review: read the board, sum up the week and write next week's plan.\n..."…
stored exactly (sha256 63c177fd4eef, 9500 chars)
```

If they differ it says `⚠️ STORED TEXT DIFFERS from what was sent` with both hashes and lengths. Refusals, for example:

```text
REFUSED (HTTP 403): could not schedule other: a seat may only schedule prompts for itself: you are ipsum-admin, the target is ipsum-orchestrator
REFUSED (HTTP 422): could not schedule big: prompt: is 20001 characters; the limit is 20000. Nothing was saved
REFUSED (HTTP 422): could not schedule bad: tz: is not an IANA time zone (e.g. Europe/Oslo); cron: must have 5 fields (minute hour day-of-month month day-of-week), got 4
```

### cv_schedule_list

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `target` | string | no | An app token may list another seat's; a seat sees its own. |
| `full` | boolean | no | `true` prints every prompt in full after its line. |

Calls `GET /api/schedules`. Two lines per schedule: id, name, target, cron and zone, `on` or `PAUSED`, the next fire time in local time; then the prompt's characters, bytes, the first 12 hex digits of its sha256, and its first 120 characters JSON-quoted (so line ends show as `\n`), with `…` when there is more. `no schedules` when there are none.

### cv_schedule_get

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `schedule` | number or string | yes | Id or name. |

Calls `GET /api/schedules/:id`. The schedule's line, then the full prompt between two marker lines:

```text
----- prompt of weekly-review: 9500 chars, sha256 <64 hex>; verbatim between these lines -----
<the prompt, exactly>
----- end of prompt of weekly-review -----
```

The text between the markers is exactly the stored prompt (the newline before the end marker is the tool's).

### cv_schedule_pause, cv_schedule_resume

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `schedule` | number or string | yes | Id or name. |

Call `PATCH /api/schedules/:id` with `enabled: false` or `true`. A paused schedule does not fire, and a prompt it holds for its seat waits. Resuming fires next at its next time from now; occurrences missed while paused do not fire late. Returns `paused: <line>` or `resumed: <line>`.

### cv_schedule_remove

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `schedule` | number or string | yes | Id or name. |

Calls `DELETE /api/schedules/:id`. Deletes the schedule and its run history. Returns `removed schedule #<id> <name>`.

### cv_schedule_runs

| Parameter | Type | Required | Meaning |
|---|---|---|---|
| `schedule` | number or string | yes | Id or name. |
| `limit` | integer | no | Default 50, at most 500. |

Calls `GET /api/schedules/:id/runs`. The schedule's line, then one line per run, newest first:

```text
run #3 · delivered · due 2026-10-11T12:32:00Z · fired 2026-10-11T12:34:04Z · LATE · delivered 2026-10-11T12:34:14Z to session 1 · sha256 d3eeadba9d21
run #2 · waiting_for_seat · due 2026-10-11T12:30:00Z · fired 2026-10-11T12:30:22Z
run #1 · superseded · due 2026-10-11T12:29:00Z · fired 2026-10-11T12:29:22Z
```

Statuses: `delivered`, `queued` (the seat was busy), `waiting_for_seat` (no seat with the title was running), `superseded` (replaced by the next occurrence while pending). The sha256 is of the prompt the run delivered; compare it with the schedule's.

## Failure modes and troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `REFUSED (HTTP 400): ... pass self` | cv-mcp does not know this seat's title yet, and the token is a seat token. | Wait for the seat to register, or set `CLAUDIVERSE_SELF`. |
| `REFUSED (HTTP 403)` | The target, or the schedule's target, is another seat. | A seat schedules only for itself; use an app token to schedule for another seat. |
| A run stays `waiting_for_seat` | No seat with the target title is running. | It is delivered when one starts. Check the title. |
| The tools are missing | The seat's role is `worker`. | They are in the `full` group. |

## Related pages

- [schedules.md](../server/schedules.md): the server side, the API and the records
- [mcp.md](mcp.md), [cv-core.md](cv-core.md)

## Source

- `orchestrator/cv-mcp.mjs` (the tool registrations)
- `orchestrator/cv-schedules.mjs` (the wording of answers and refusals)
- `orchestrator/cv-core.mjs` (`scheduleAdd`, `scheduleList`, `scheduleGet`, `scheduleUpdate`, `scheduleRemove`, `scheduleRuns`)
- Test: `orchestrator/test/schedules.test.mjs`
