# 2. Anthropic accounts

The server keeps a **pool** of Claude accounts. Seats send their model requests
through the server, and the server sends each one with the best account that
has room left. When an account gets close to its limit, it cools down and the
seats move to the next one by themselves.

You add an account once, in the web panel. The machines that run seats never
need to log in.

## Add an account

1. In the web panel, open **Accounts** (`http://claudiverse.example:8080/accounts`).
2. Under **Add an account**, give it a name, for example `work`, and click
   **Get authorization link**.
3. **Sign out of claude.com first** in that browser. The sign-in page uses the
   account you are already signed in with, and it doesn't tell you which one.
4. Open the link and sign in as the account you are adding. Approve the access.
5. The callback page shows a code. Copy **all** of it, including the part after
   the `#`, paste it into step 3 of the form and click **Add account**.

The account appears as a card with its usage. Repeat for each account.

![The account pool: one account available, one cooling down at its weekly limit](../images/accounts.png)

## What the cards show

- **Available**: seats can use it.
- **Cooling down**: it reached `CV_USAGE_COOLDOWN_PCT` (95% by default) of a
  limit, or Anthropic answered with a rate limit. The card says why and when it
  comes back. An account added at its limit starts out cooling down.
- **Needs re-auth**: its login no longer works. Add it again with the same name.

Every 5 minutes the server reads each account's usage. **Check usage** reads it
right away. The Mac and Android apps can also make an account the preferred
one, which puts it first in line.

A second account adds headroom while the first one is busy. It doesn't make
anything unlimited: each account keeps its own limits.

## Next

[Set up a machine for seats](3-machine.md).
