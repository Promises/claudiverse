import { useCallback, useEffect, useState } from "react";
import {
  completeAuthorization,
  deleteAuth,
  listAuths,
  refreshUsage,
  startAuthorization,
  type AnthropicAuth,
  type AuthorizationStart,
  type UsageSnapshot,
  type UsageLimit,
} from "../api/anthropicAuths";
import { Link } from "react-router-dom";
import { useDocumentTitle } from "../hooks/useDocumentTitle";
import styles from "./AccountsPage.module.css";

const STATUS_CLASS: Record<string, string> = {
  available: styles.available,
  cooling_down: styles.cooling,
  needs_reauth: styles.needsReauth,
};

function formatWhen(iso: string | null): string {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  return d.toLocaleString();
}

function formatCountdown(iso: string | null): string {
  if (!iso) return "—";
  const ms = new Date(iso).getTime() - Date.now();
  if (Number.isNaN(ms)) return "—";
  if (ms <= 0) return "now";
  const mins = Math.round(ms / 60000);
  if (mins < 60) return `${mins}m`;
  return `${Math.floor(mins / 60)}h ${mins % 60}m`;
}

/**
 * A usage bar, or nothing.
 *
 * `undefined` renders as "unknown", never as 0%. A poll can fail, and an
 * account that silently reads 0% used is the one you would route work to
 * first — the opposite of what a failed poll should cause.
 */
function UsageBar({ label, percent }: { label: string; percent?: number }) {
  if (typeof percent !== "number") {
    return (
      <div className={styles.usageRow}>
        <span className={styles.usageLabel}>{label}</span>
        <span className={styles.unknown}>unknown</span>
      </div>
    );
  }

  const clamped = Math.max(0, Math.min(100, percent));
  const fillClass =
    clamped >= 90 ? styles.barFillCritical : clamped >= 70 ? styles.barFillHigh : "";

  return (
    <div className={styles.usageRow}>
      <span className={styles.usageLabel}>{label}</span>
      <div className={styles.bar}>
        <div className={`${styles.barFill} ${fillClass}`} style={{ width: `${clamped}%` }} />
      </div>
      <span className={styles.usageValue}>{clamped.toFixed(0)}%</span>
    </div>
  );
}

/** "session" -> "Session", "weekly_all" -> "Weekly", "weekly_scoped" -> the model. */
function limitLabel(l: UsageLimit): string {
  const model = l.scope?.model?.display_name;
  if (model) return `Weekly · ${model}`;
  switch (l.kind) {
    case "session":
      return "Session";
    case "weekly_all":
      return "Weekly";
    default:
      return l.kind || l.group || "Limit";
  }
}

function Usage({ usage, checkedAt }: { usage: UsageSnapshot | null; checkedAt: string | null }) {
  if (!usage) {
    return (
      <div className={styles.usage}>
        <span className={styles.unknown}>
          No usage data. Routing falls back to reacting to rate limits.
        </span>
      </div>
    );
  }

  // Render from `limits`: each entry carries its own percent AND reset time, and
  // new limit kinds show up automatically instead of needing a new hardcoded row.
  const limits = (usage.limits || []).filter((l) => typeof l.percent === "number");

  if (limits.length === 0) {
    return (
      <div className={styles.usage}>
        <span className={styles.unknown}>Usage returned no limits.</span>
        <div className={styles.hint}>Checked {formatWhen(checkedAt)}</div>
      </div>
    );
  }

  return (
    <div className={styles.usage}>
      {limits.map((l, i) => (
        <UsageBar key={`${l.kind || l.group}-${i}`} label={limitLabel(l)} percent={l.percent} />
      ))}
      <div className={styles.hint}>
        Checked {formatWhen(checkedAt)}
        {limits[0]?.resets_at && ` · session resets ${formatCountdown(limits[0].resets_at)}`}
        {usage.extra_usage?.is_enabled && " · extra usage enabled"}
      </div>
    </div>
  );
}

function AuthCard({
  auth,
  onChanged,
}: {
  auth: AnthropicAuth;
  onChanged: () => void;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const poll = async () => {
    setBusy(true);
    setError(null);
    try {
      await refreshUsage(auth.id);
      onChanged();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const remove = async () => {
    if (!confirm(`Remove "${auth.label}"? Seats using it will fail over to another account.`)) {
      return;
    }
    setBusy(true);
    try {
      await deleteAuth(auth.id);
      onChanged();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setBusy(false);
    }
  };

  return (
    <div className={styles.card}>
      <div className={styles.cardHeader}>
        <span className={styles.label}>{auth.label}</span>
        {auth.account_email && <span className={styles.email}>{auth.account_email}</span>}
        <span className={styles.spacer} />
        <span className={`${styles.badge} ${STATUS_CLASS[auth.status] || ""}`}>
          {auth.status.replace("_", " ")}
        </span>
      </div>

      <div className={styles.meta}>
        <span>
          Token{" "}
          <span className={styles.metaValue}>{auth.token_valid ? "valid" : "stale"}</span>
        </span>
        <span>
          Priority <span className={styles.metaValue}>{auth.priority}</span>
        </span>
        <span>
          Last leased <span className={styles.metaValue}>{formatWhen(auth.last_leased_at)}</span>
        </span>
        {auth.status === "cooling_down" && (
          <span>
            Available in{" "}
            <span className={styles.metaValue}>{formatCountdown(auth.cooldown_until)}</span>
          </span>
        )}
      </div>

      {auth.cooldown_reason && auth.status !== "available" && (
        <div className={styles.hint}>{auth.cooldown_reason}</div>
      )}

      <Usage usage={auth.usage} checkedAt={auth.usage_checked_at} />

      <div className={styles.actions}>
        <button className={styles.button} onClick={poll} disabled={busy}>
          {busy ? "Checking…" : "Check usage"}
        </button>
        <button className={`${styles.button} ${styles.danger}`} onClick={remove} disabled={busy}>
          Remove
        </button>
      </div>

      {error && <div className={styles.error}>{error}</div>}
    </div>
  );
}

function EnrolForm({ onAdded }: { onAdded: () => void }) {
  const [label, setLabel] = useState("");
  const [start, setStart] = useState<AuthorizationStart | null>(null);
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const begin = async () => {
    setBusy(true);
    setError(null);
    try {
      setStart(await startAuthorization());
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const finish = async () => {
    if (!start) return;
    setBusy(true);
    setError(null);
    try {
      await completeAuthorization({
        label: label.trim(),
        code: code.trim(),
        verifier: start.verifier,
        state: start.state,
      });
      setLabel("");
      setCode("");
      setStart(null);
      onAdded();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className={styles.enrol}>
      <p className={styles.enrolTitle}>Add an account</p>

      <div className={styles.step}>
        <label className={styles.stepLabel} htmlFor="auth-label">
          1 · Name it
        </label>
        <input
          id="auth-label"
          className={styles.input}
          value={label}
          placeholder="max-primary"
          onChange={(e) => setLabel(e.target.value)}
          disabled={busy || !!start}
        />
      </div>

      {!start ? (
        <button className={styles.button} onClick={begin} disabled={busy || !label.trim()}>
          {busy ? "Preparing…" : "2 · Get authorization link"}
        </button>
      ) : (
        <>
          <div className={styles.step}>
            <span className={styles.stepLabel}>2 · Open this and sign in as the target account</span>
            <a className={styles.authLink} href={start.url} target="_blank" rel="noreferrer">
              {start.url}
            </a>
            <p className={styles.hint}>
              Sign out of Anthropic first, or you will silently enrol the account you are already
              signed in as — the flow gives no indication which one it used.
            </p>
          </div>

          <div className={styles.step}>
            <label className={styles.stepLabel} htmlFor="auth-code">
              3 · Paste the whole code from the callback page
            </label>
            <input
              id="auth-code"
              className={styles.input}
              value={code}
              placeholder="abc123…#state"
              onChange={(e) => setCode(e.target.value)}
              disabled={busy}
            />
            <p className={styles.hint}>
              Paste it verbatim, including anything after the <code>#</code>. That part is the state
              value and is checked against this attempt.
            </p>
          </div>

          <div className={styles.actions}>
            <button className={styles.button} onClick={finish} disabled={busy || !code.trim()}>
              {busy ? "Exchanging…" : "Add account"}
            </button>
            <button className={styles.button} onClick={() => setStart(null)} disabled={busy}>
              Cancel
            </button>
          </div>
        </>
      )}

      {error && <div className={styles.error}>{error}</div>}
    </div>
  );
}

export default function AccountsPage() {
  useDocumentTitle("Accounts");
  const [auths, setAuths] = useState<AnthropicAuth[]>([]);
  const [vaultConfigured, setVaultConfigured] = useState(true);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const res = await listAuths();
      setAuths(res.auths);
      setVaultConfigured(res.vault_configured);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  return (
    <div className={styles.page}>
      <Link to="/" className={styles.back}>
        &larr; Dashboard
      </Link>
      <div className={styles.header}>
        <h1 className={styles.title}>Anthropic accounts</h1>
      </div>
      <p className={styles.subtitle}>
        Seats lease a token from this pool. Rate limits are per account, so a second account is
        headroom during a busy window — not unlimited capacity.
      </p>

      {!vaultConfigured && (
        <div className={styles.warning}>
          <div className={styles.warningTitle}>Vault key not configured</div>
          Set <code>CV_VAULT_KEY</code> to base64 of 32 random bytes on the server. Until then
          accounts cannot be stored — credentials are never written unencrypted.
        </div>
      )}

      {loading ? (
        <p className={styles.empty}>Loading…</p>
      ) : error ? (
        <p className={styles.error}>{error}</p>
      ) : auths.length === 0 ? (
        <p className={styles.empty}>No accounts yet.</p>
      ) : (
        <div className={styles.list}>
          {auths.map((a) => (
            <AuthCard key={a.id} auth={a} onChanged={load} />
          ))}
        </div>
      )}

      <EnrolForm onAdded={load} />
    </div>
  );
}
