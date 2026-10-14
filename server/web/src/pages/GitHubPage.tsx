import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { addToken, checkToken, listSubscriptions, listTokens, removeToken, setExpiresOn, type GitHubSubscription, type GitHubToken } from "../api/github";
import { useDocumentTitle } from "../hooks/useDocumentTitle";
import { useAuth } from "../contexts/AuthContext";
import FreshSignIn from "../components/FreshSignIn";
import { hasAppPowers, isAppOnlyError } from "../lib/appOnly";
import { expiryText, scopeText } from "../lib/github";
import styles from "./AccountsPage.module.css";

const STATUS_CLASS: Record<GitHubToken["status"], string> = {
  ok: styles.available,
  unauthorized: styles.needsReauth,
  error: styles.needsReauth,
};

function TokenCard({ token, onChanged }: { token: GitHubToken; onChanged: () => void }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [expiresOn, setExpiresOnField] = useState(token.expires_on ?? "");

  const act = (fn: () => Promise<unknown>) => async () => {
    setBusy(true);
    setError(null);
    try {
      await fn();
      onChanged();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className={styles.card}>
      <div className={styles.cardHeader}>
        <span className={styles.label}>{token.label}</span>
        {token.login && <span className={styles.email}>{token.login}</span>}
        <span className={styles.spacer} />
        <span className={`${styles.badge} ${STATUS_CLASS[token.status] ?? ""}`}>{token.status}</span>
      </div>

      <div className={styles.meta}>
        <span>
          Access <span className={styles.metaValue}>{scopeText(token)}</span>
        </span>
        <span>
          Repositories <span className={styles.metaValue}>{token.repos_count ?? "unknown"}</span>
        </span>
        <span>
          Serving <span className={styles.metaValue}>{token.serving.length ? token.serving.join(", ") : "no subscription"}</span>
        </span>
        <span>
          Token <span className={styles.metaValue}>{expiryText(token.expires_at)}</span>
          {token.expiry_source === "manual" && " (as entered here)"}
        </span>
      </div>

      {token.expiry_source !== "github" && (
        <div className={styles.step}>
          <label className={styles.stepLabel} htmlFor={`gh-expiry-${token.id}`}>
            Expiry date, if the token has one
          </label>
          <input
            id={`gh-expiry-${token.id}`}
            className={styles.input}
            type="date"
            value={expiresOn}
            onChange={(e) => setExpiresOnField(e.target.value)}
            disabled={busy}
          />
          <p className={styles.hint}>GitHub reports no expiry for this token. Enter the one GitHub showed when you made it, and the panel warns 7 days ahead.</p>
          <div className={styles.actions}>
            <button
              className={styles.button}
              onClick={act(() => setExpiresOn(token.id, expiresOn || null))}
              disabled={busy || expiresOn === (token.expires_on ?? "")}
            >
              Save date
            </button>
          </div>
        </div>
      )}

      {token.expiring && (
        <div className={styles.warning}>
          <div className={styles.warningTitle}>Expiring soon</div>
          Make a new token on GitHub, add it here, then remove this one.
        </div>
      )}
      {token.last_error && <div className={styles.error}>{token.last_error}</div>}

      <div className={styles.actions}>
        <button className={styles.button} onClick={act(() => checkToken(token.id))} disabled={busy}>
          {busy ? "Checking…" : "Check again"}
        </button>
        <button className={`${styles.button} ${styles.danger}`} onClick={act(() => removeToken(token.id))} disabled={busy}>
          Remove
        </button>
      </div>

      {error && <div className={styles.error}>{error}</div>}
    </div>
  );
}

function Subscriptions({ subscriptions }: { subscriptions: GitHubSubscription[] }) {
  return (
    <section className={styles.list} aria-label="Subscriptions">
      <p className={styles.enrolTitle}>Subscriptions</p>
      {subscriptions.length === 0 ? (
        <p className={styles.empty}>
          No seat watches GitHub. A seat subscribes with <code>cv_subscribe</code>, for example <code>gh:owner/repo</code>.
        </p>
      ) : (
        subscriptions.map((s) => (
          <div key={s.title} className={styles.card}>
            <div className={styles.cardHeader}>
              <span className={styles.label}>{s.title}</span>
              <span className={styles.email}>{s.seats.join(", ")}</span>
            </div>
            <div className={styles.meta}>
              {s.repo &&
                (s.token ? (
                  <span>
                    Read with <span className={styles.metaValue}>{s.token.label}</span>
                  </span>
                ) : s.unreached === "repos_not_loaded" ? (
                  <span className={styles.hint}>A token's list of repositories is not loaded yet: the server loads it within a minute.</span>
                ) : (
                  <span className={styles.error}>No token reaches {s.repo}: it is not read.</span>
                ))}
              {s.last_read_at && (
                <span>
                  Last read <span className={styles.metaValue}>{new Date(s.last_read_at + "Z").toLocaleString()}</span>
                </span>
              )}
            </div>
          </div>
        ))
      )}
    </section>
  );
}

function AddForm({ onAdded }: { onAdded: () => void }) {
  const [label, setLabel] = useState("");
  const [secret, setSecret] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await addToken(label.trim(), secret.trim());
      setLabel("");
      setSecret("");
      onAdded();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <form className={styles.enrol} onSubmit={submit}>
      <p className={styles.enrolTitle}>Add a token</p>
      <div className={styles.step}>
        <label className={styles.stepLabel} htmlFor="gh-label">
          Name
        </label>
        <input id="gh-label" className={styles.input} value={label} placeholder="personal" onChange={(e) => setLabel(e.target.value)} disabled={busy} />
      </div>
      <div className={styles.step}>
        <label className={styles.stepLabel} htmlFor="gh-token">
          Token
        </label>
        <input
          id="gh-token"
          className={styles.input}
          type="password"
          autoComplete="off"
          spellCheck={false}
          value={secret}
          placeholder="github_pat_…"
          onChange={(e) => setSecret(e.target.value)}
          disabled={busy}
        />
        <p className={styles.hint}>
          A fine-grained token, read-only: Issues, Pull requests, Commit statuses, Actions and Metadata. One per resource owner
          (your account, an organisation). The server checks it with GitHub, then stores it encrypted; it is never shown again.
        </p>
      </div>
      <div className={styles.actions}>
        <button className={styles.button} type="submit" disabled={busy || !label.trim() || !secret.trim()}>
          {busy ? "Checking with GitHub…" : "Add token"}
        </button>
      </div>
      {error && <div className={styles.error}>{error}</div>}
    </form>
  );
}

export default function GitHubPage() {
  useDocumentTitle("GitHub");
  // Every GitHub token route is app-only: an older sign-in is told how to get one.
  const { scope } = useAuth();
  const [tokens, setTokens] = useState<GitHubToken[]>([]);
  const [subscriptions, setSubscriptions] = useState<GitHubSubscription[]>([]);
  const [vaultConfigured, setVaultConfigured] = useState(true);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!hasAppPowers(scope)) return setLoading(false);
    try {
      const [res, subs] = await Promise.all([listTokens(), listSubscriptions()]);
      setTokens(res.tokens);
      setSubscriptions(subs);
      setVaultConfigured(res.vault_configured);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, [scope]);

  useEffect(() => {
    load();
  }, [load]);

  const appOnly = !hasAppPowers(scope) || isAppOnlyError(error);

  return (
    <div className={styles.page}>
      <Link to="/" className={styles.back}>
        &larr; Dashboard
      </Link>
      <div className={styles.header}>
        <h1 className={styles.title}>GitHub</h1>
      </div>
      <p className={styles.subtitle}>
        Tokens the server reads GitHub with, for subscriptions to pull requests and issues. Read-only: nothing here can
        change a repository.
      </p>

      {!vaultConfigured && (
        <div className={styles.warning}>
          <div className={styles.warningTitle}>Vault key not configured</div>
          Set <code>CV_VAULT_KEY</code> to base64 of 32 random bytes on the server. Until then tokens cannot be stored —
          they are never written unencrypted.
        </div>
      )}

      {appOnly ? (
        <FreshSignIn />
      ) : loading ? (
        <p className={styles.empty}>Loading…</p>
      ) : error ? (
        <p className={styles.error}>{error}</p>
      ) : tokens.length === 0 ? (
        <p className={styles.empty}>No tokens yet.</p>
      ) : (
        <div className={styles.list}>
          {tokens.map((t) => (
            <TokenCard key={t.id} token={t} onChanged={load} />
          ))}
        </div>
      )}

      {!appOnly && !loading && !error && <Subscriptions subscriptions={subscriptions} />}
      {!appOnly && <AddForm onAdded={load} />}
    </div>
  );
}
