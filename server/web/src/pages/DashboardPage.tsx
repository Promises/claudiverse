import { useState, useEffect, useCallback } from "react";
import { useNavigate, Link } from "react-router-dom";
import { useAuth } from "../contexts/AuthContext";
import { listSessions, deleteSession } from "../api/sessions";
import type { Session } from "../lib/types";
import BrandLogo from "../components/BrandLogo";
import AddMachine from "../components/AddMachine";
import { useDocumentTitle } from "../hooks/useDocumentTitle";
import styles from "./DashboardPage.module.css";

const ACTIVITY_LABEL: Record<string, string> = {
  busy: "Working",
  idle: "Idle — ready",
  disconnected: "Not connected",
};

// "unknown" renders NO dot. It means the Room did not answer within the
// list's budget — almost always because it is busy — so drawing the
// disconnected dot would state something false about a working seat.

/**
 * Coarse on purpose. A dashboard is scanned, not read: "4m" answers "did this
 * move recently", and second-level precision only adds digits to compare.
 */
function relativeTime(iso: string): string {
  const then = new Date(iso.endsWith("Z") ? iso : iso + "Z").getTime();
  if (Number.isNaN(then)) return "";
  const secs = Math.max(0, Math.round((Date.now() - then) / 1000));
  if (secs < 45) return "just now";
  const mins = Math.round(secs / 60);
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.round(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  return `${Math.round(hrs / 24)}d ago`;
}

export default function DashboardPage() {
  const { user, logout } = useAuth();
  useDocumentTitle(null);
  const navigate = useNavigate();
  const [sessions, setSessions] = useState<Session[]>([]);
  const [loading, setLoading] = useState(true);
  const [adding, setAdding] = useState(false);

  const refresh = useCallback(async () => {
    try {
      const res = await listSessions();
      setSessions(res.sessions);
    } catch {
      // ignore
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    refresh();
    const interval = setInterval(refresh, 5000);
    return () => clearInterval(interval);
  }, [refresh]);

  async function handleDelete(id: number) {
    await deleteSession(id);
    refresh();
  }

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <h1 className={styles.logo}>
          <BrandLogo />
          Claudiverse
        </h1>
        <div className={styles.headerRight}>
          <Link to="/forum" className={styles.navLink}>
            Forum
          </Link>
          <Link to="/accounts" className={styles.navLink}>
            Accounts
          </Link>
          <span className={styles.email}>{user?.email}</span>
          <button onClick={logout} className={styles.logoutBtn}>
            Sign out
          </button>
        </div>
      </header>

      <main className={styles.main}>
        <div className={styles.toolbar}>
          <h2>Seats</h2>
          {!adding && (
            <button className={styles.addBtn} onClick={() => setAdding(true)}>
              Add a machine
            </button>
          )}
        </div>
        {adding && <AddMachine onClose={() => setAdding(false)} />}

        {loading ? (
          <p className={styles.empty}>Loading...</p>
        ) : sessions.length === 0 ? (
          <p className={styles.empty}>
            No seats yet. Add a machine above, then start a seat on it.
          </p>
        ) : (
          <ul className={styles.list}>
            {sessions.map((s) => (
              <li key={s.id} className={styles.item}>
                <div
                  className={styles.itemContent}
                  onClick={() => navigate(`/sessions/${s.id}`)}
                >
                  <div className={styles.itemHeader}>
                    {/*
                      Activity dot BEFORE the title: it is the thing being
                      scanned for down a list of seats, so it sits where the eye
                      already starts rather than after a name of variable width.
                    */}
                    {/* Absent on an older server — see the type. Rendering the
                        dot anyway would assert "disconnected" about a seat we
                        simply have no signal for. */}
                    {s.activity && s.activity !== "unknown" && (
                    <span
                      className={`${styles.activityDot} ${
                        s.activity === "busy"
                          ? styles.dotBusy
                          : s.activity === "idle"
                            ? styles.dotIdle
                            : styles.dotOffline
                      }`}
                      title={ACTIVITY_LABEL[s.activity] ?? s.activity}
                      aria-label={ACTIVITY_LABEL[s.activity] ?? s.activity}
                    />
                    )}
                    <span className={styles.itemTitle}>{s.title}</span>
                    <StatusBadge status={s.status} />
                  </div>
                  {/*
                    Claude Code's own picker name, shown beneath the addressable
                    title rather than replacing it: the title is what cv_send
                    resolves, this is what a human recognises. Hidden when it is
                    absent (not yet auto-titled) or identical, so the row does
                    not repeat itself.
                  */}
                  {s.display_title && s.display_title !== s.title && (
                    <div className={styles.itemDisplayTitle}>{s.display_title}</div>
                  )}
                  <div className={styles.itemMeta}>
                    {s.fleet && <span className={styles.fleet}>{s.fleet}</span>}
                    <span>{s.model}</span>
                    {s.host && <span>on {s.host}</span>}
                    {s.working_directory && <span>{s.working_directory}</span>}
                    {/*
                      Relative, and of LAST ACTIVITY rather than creation. On a
                      live dashboard "4m ago" is the question being asked;
                      an absolute start time answers a different one.
                    */}
                    <span title={new Date(s.last_activity_at ?? s.inserted_at).toLocaleString()}>
                      {relativeTime(s.last_activity_at ?? s.inserted_at)}
                    </span>
                  </div>
                </div>
                <button
                  onClick={(e) => {
                    e.stopPropagation();
                    handleDelete(s.id);
                  }}
                  className={styles.deleteBtn}
                  title="Delete session"
                >
                  &times;
                </button>
              </li>
            ))}
          </ul>
        )}
      </main>
    </div>
  );
}

function StatusBadge({ status }: { status: string }) {
  const className = `${styles.badge} ${
    status === "running"
      ? styles.badgeRunning
      : status === "stopped"
        ? styles.badgeStopped
        : styles.badgeCrashed
  }`;

  return <span className={className}>{status}</span>;
}
