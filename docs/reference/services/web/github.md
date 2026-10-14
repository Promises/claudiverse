# GitHub page

The GitHub page (route `/github`, linked from the dashboard header) holds the tokens the server reads GitHub with, for subscriptions to pull requests and issues. It lists each token with what GitHub said about it, checks a token again or removes it, and has the form that adds one. The subtitle reads: "Tokens the server reads GitHub with, for subscriptions to pull requests and issues. Read-only: nothing here can change a repository."

## How it works

On load the page calls `GET /api/github/tokens` and renders one card per token, then the "Add a token" form. After any change (check, remove, add) it reloads the whole list. The server's side, what it asks GitHub and how it keeps the token, is in the server's [GitHub page](../../server/github.md).

A card shows:

| Field | From |
|---|---|
| Name, then the GitHub account | `label`, `login` |
| Badge | `status`: `ok`, `unauthorized` (GitHub refused it: wrong, expired or revoked) or `error` |
| Access | A classic token's scopes; for a fine-grained token, "fine-grained: GitHub does not report its permissions" |
| Repositories | `repos_count`, or "unknown" |
| Serving | The watched repositories this token reads (`serving`), or "no subscription" |
| Token | "expires in N days", "expires today", "expired N days ago", or "never expires" when GitHub sent no expiry |

When GitHub reports no expiry for a token, its card has a date field, "Expiry date, if the token has one", and a "Save date" button: enter the date GitHub showed when the token was made, and the expiry reads "… (as entered here)". Clearing the field and saving removes it. A token GitHub reports an expiry for has no such field.

A token that expires within 7 days (`expiring`) has an "Expiring soon" notice: "Make a new token on GitHub, add it here, then remove this one." The last error the server recorded is shown in red.

Below the tokens, "Subscriptions" lists what the seats watch of GitHub (`GET /api/github/subscriptions`): each title (`gh:owner/repo`, `gh:@me`, `@github` …) with the seats watching it, "Read with <token>" for a repository, and when it was last read. A repository no token reaches says "No token reaches owner/repo: it is not read."; one waiting for a token's list of repositories to load says "A token's list of repositories is not loaded yet: the server loads it within a minute." With none, the section says how a seat subscribes (`cv_subscribe`, for example `gh:owner/repo`).

The add form has a Name and a Token field. The token field is a password field (no autocomplete, no spellcheck), and it is cleared once the token is added; the server never sends a token back, so it is never shown again. "Add token" is disabled until both are filled. The server checks the token with GitHub before storing it, so the button reads "Checking with GitHub…" meanwhile, and GitHub's refusal is shown in the server's words, for example "GitHub refused the token (401): it is wrong, expired or revoked".

The form's hint says which token to make: a fine-grained token, read-only, with Issues, Pull requests, Commit statuses, Actions and Metadata, one per resource owner (your account, an organisation).

If the server has no `CV_VAULT_KEY`, a "Vault key not configured" notice says tokens cannot be stored.

## Interface

The page calls, through `server/web/src/api/github.ts`: `GET /api/github/tokens`, `GET /api/github/subscriptions`, `POST /api/github/tokens`, `POST /api/github/tokens/:id/check`, `DELETE /api/github/tokens/:id`. All need an app or super token, which is what the panel signs in with.

## Failure modes and troubleshooting

- "This page needs a fresh sign-in": the panel's sign-in is an older `api` one, which cannot hold GitHub tokens. Sign out and in again. The page shows this, and no form, whenever its scope is not `app` or `super`, or the server refuses as app-only.
- A token shows fewer repositories than expected: see the server's [GitHub page](../../server/github.md#failure-modes-and-troubleshooting).

## Related pages

- [Server: GitHub](../../server/github.md)
- [accounts.md](accounts.md), the other page that holds credentials

## Source

- `server/web/src/pages/GitHubPage.tsx` (styles from `AccountsPage.module.css`), `server/web/src/pages/GitHubPage.test.tsx`
- `server/web/src/api/github.ts`
- `server/web/src/lib/github.ts`, `server/web/src/lib/github.test.ts`
