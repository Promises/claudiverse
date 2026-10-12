# 6. Troubleshooting

## The server

**I can't find the setup code.** Run
`docker compose -f compose.yml logs server | grep -A3 "setup code"`. Only
the newest code works: a restart makes a new one. If the log shows none,
an account already exists; sign in instead.

**The web panel loads, but sign-in fails with a network error.** The panel calls
the API at `VITE_API_URL`, which was built into it. Check that your browser can
open `$VITE_API_URL/api/health`. If you change the value in `.env`, rebuild:
`docker compose -f compose.yml --env-file .env up -d --build`.

**Accounts says "Vault key not configured".** Set `CV_VAULT_KEY` in `.env` and
run `up -d` again. If the key ever changes, every account needs to be added again.

**"Too many failed sign-ins".** Wrong passwords and wrong setup codes are
limited per address. Wait for the time the message gives.

## A machine

**The host agent isn't online.** Read its log (`journalctl --user -u
claudiverse-host-agent` on Linux, `~/Library/Logs/claudiverse-host-agent.log`
on macOS). Check that the machine reaches the server with
`curl $SERVER/api/health`, and that the `name` in
`~/.config/claudiverse/host-agent.json` is the name you gave
`connect_machine`: a host token works only for its own name.

**Starting a profile says the machine refused it.** The reason is in the
answer and in the host agent's log. Usually the folder is outside `roots`,
doesn't exist, or the profile names a runtime or mode the machine doesn't offer.

## A seat

**It started, but nothing happens.** Look at it: `tmux attach -t <name>` on the
machine. A dialog may be waiting for an answer there.

**The status line reads "claudiverse offline".** The mod can't reach the
server. Check `server_url` with `claude plugin configure
claudiverse-seat@claudiverse`. The mod keeps retrying, and the seat registers
when the server answers.

**`API Error: 403 cv-proxy: missing or invalid X-Claudiverse-Token`.** The seat
token is wrong or was revoked. Mint new tokens with `connect_machine` and put the
seat token in the mod's settings and the host agent's config.

**`API Error: 429 cv-proxy: no pool account is available`.** Every account in the pool is cooling down.
The Accounts page says when each one comes back.
