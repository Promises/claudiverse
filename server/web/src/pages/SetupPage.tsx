import { useState } from "react";
import { useAuth } from "../contexts/AuthContext";
import { useNavigate, Link } from "react-router-dom";
import { ApiError } from "../api/auth";
import { useDocumentTitle } from "../hooks/useDocumentTitle";
import styles from "./AuthPage.module.css";

// The first account on a new server. The setup code is in the server's log
// (`docker compose logs server`); once an account exists the server refuses
// this page's request and sign-in is the only way in.
export default function SetupPage() {
  useDocumentTitle("Create your account");
  const { setup } = useAuth();
  const navigate = useNavigate();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [code, setCode] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError("");
    setLoading(true);
    try {
      await setup(email, password, code);
      navigate("/");
    } catch (err) {
      if (err instanceof ApiError && err.body.errors) {
        const errors = err.body.errors as Record<string, string[]>;
        const msgs = Object.entries(errors)
          .map(([k, v]) => `${k}: ${(v as string[]).join(", ")}`)
          .join("; ");
        setError(msgs);
      } else if (err instanceof ApiError) {
        setError((err.body as { error?: string }).error || "Could not create the account");
      } else {
        setError("Could not create the account");
      }
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className={styles.container}>
      <div className={styles.card}>
        <h1 className={styles.title}>Claudiverse</h1>
        <p className={styles.subtitle}>Create your account</p>

        <form onSubmit={handleSubmit} className={styles.form}>
          {error && <div className={styles.error}>{error}</div>}

          <label className={styles.label}>
            Email
            <input
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className={styles.input}
              required
            />
          </label>

          <label className={styles.label}>
            Password
            <input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className={styles.input}
              minLength={8}
              maxLength={72}
              required
            />
          </label>

          <label className={styles.label}>
            Setup code
            <input
              value={code}
              onChange={(e) => setCode(e.target.value)}
              className={styles.input}
              placeholder="ABCD-EFGH-…"
              autoComplete="off"
              spellCheck={false}
              required
            />
            <span className={styles.hint}>
              The installer printed it under &ldquo;The server is up&rdquo;. To see it again, on the server:{" "}
              <code>cd ~/claudiverse &amp;&amp; docker compose -f compose.yml logs server | grep -A3 &apos;setup code&apos;</code>
            </span>
          </label>

          <button type="submit" className={styles.button} disabled={loading}>
            {loading ? "Creating account..." : "Create account"}
          </button>
        </form>

        <p className={styles.link}>
          Already have an account? <Link to="/login">Sign in</Link>
        </p>
      </div>
    </div>
  );
}
