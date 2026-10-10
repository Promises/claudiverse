defmodule ClaudiverseServer.Repo.Migrations.CreateAnthropicAuths do
  @moduledoc """
  A server-managed pool of Anthropic subscription accounts, with failover.

  ⭐ WHY THE SERVER OWNS THIS. Rate limits are PER ACCOUNT, so a busy window
  rate-limits every seat at once — ~17 seats currently share a single login, and
  nothing knows a second account exists. Moving the pool here means one place
  decides who uses what, and one place can see that account A is exhausted while
  B has headroom.

  🔴 NAMED AnthropicAuths, NOT Accounts. `ClaudiverseServer.Accounts` already
  exists and means something entirely different — Phoenix email/password login
  for the web panel (Accounts.User, Accounts.UserToken). Reusing "account" would
  collide in the one place people grep.

  Supersedes patch-ref/patches.d/004-multi-account-failover.patch.disabled, which
  put a 30,796-byte credential store in the CLIENT and needed six patch injection
  points across three files. Every one of those points is a thing that breaks on
  an upstream release. Design: docs/ANTHROPIC_AUTHS_DESIGN.md
  """
  use Ecto.Migration

  def change do
    create table(:anthropic_auths) do
      add :label, :string, null: false
      add :account_email, :string

      # 🔴 ENCRYPTED AT REST, and be honest about what that buys: it keeps live
      # tokens out of casual `psql` output, logs and backups. It is not a
      # defence against a compromised host — the key is on the same machine.
      add :access_token, :binary
      add :refresh_token, :binary
      add :expires_at, :utc_datetime
      add :scopes, :string

      # available | cooling_down | needs_reauth
      #
      # ⚠️ `cooldown_until` is AUTHORITATIVE; this column is a cache of it so the
      # panel can render without recomputing. A stored status that nothing
      # re-checks is exactly how a field starts lying — every write that sets
      # `cooling_down` must set `cooldown_until` in the same changeset, and the
      # lease query filters on the TIMESTAMP, never on this string.
      add :status, :string, null: false, default: "available"
      add :cooldown_until, :utc_datetime
      add :cooldown_reason, :text

      add :priority, :integer, null: false, default: 100
      add :last_refreshed_at, :utc_datetime
      add :last_leased_at, :utc_datetime

      # Snapshot from GET https://api.anthropic.com/api/oauth/usage, refreshed by
      # a slow poller. This is what makes routing PROACTIVE rather than reactive:
      # without it the only way to discover a limit is to take a 429 on a real
      # request, which burns that turn. With it, the chooser can prefer the
      # account that has headroom BEFORE spending anything.
      # The 429 path stays as the backstop — a poll is a cache and can be stale.
      add :usage_snapshot, :map
      add :usage_checked_at, :utc_datetime

      timestamps()
    end

    create unique_index(:anthropic_auths, [:label])

    # The lease query's index: "usable auths, best first". Ordering by priority
    # then id keeps selection deterministic, which matters when two seats lease
    # in the same instant.
    create index(:anthropic_auths, [:status, :cooldown_until, :priority])
  end
end
