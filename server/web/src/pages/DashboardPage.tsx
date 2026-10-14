import { useState, useEffect, useCallback } from "react";
import { useNavigate, Link } from "react-router-dom";
import { useAuth } from "../contexts/AuthContext";
import { listSessions, deleteSession } from "../api/sessions";
import { listHosts, type Host } from "../api/hosts";
import type { Session } from "../lib/types";
import { relativeTime } from "../lib/relativeTime";
import BrandLogo from "../components/BrandLogo";
import AddMachine from "../components/AddMachine";
import Machines from "../components/Machines";
import StartSeat, { type StartedSpawn } from "../components/StartSeat";
import { useDocumentTitle } from "../hooks/useDocumentTitle";
import { useOperatorEvents, type OperatorEvent } from "../hooks/useOperatorEvents";
import styles from "./DashboardPage.module.css";

const ACTIVITY_LABEL: Record<string, string> = {
  busy: "Working",
  idle: "Idle — ready",
  disconnected: "Not connected",
};

// "unknown" renders NO dot. It means the Room did not answer within the
// list's budget — almost always because it is busy — so drawing the
// disconnected dot would state something false about a working seat.

/** A seat asked for with Start a seat, until its machine says how it went. */
interface Spawn extends StartedSpawn {
  state: "starting" | "started" | "failed";
  error?: string;
}

const EVENTS = ["host", "host_spawn"] as const;

export default function DashboardPage() {
  const { user, token, logout } = useAuth();
  useDocumentTitle(null);
  const navigate = useNavigate();
  const [sessions, setSessions] = useState<Session[]>([]);
  const [loading, setLoading] = useState(true);
  const [adding, setAdding] = useState(false);
  const [hosts, setHosts] = useState<Host[]>([]);
  // The form, and the machine it was opened from ("" when from the toolbar).
  const [starting, setStarting] = useState<string | null>(null);
  const [spawns, setSpawns] = useState<Spawn[]>([]);

  const refreshHosts = useCallback(async () => {
    try {
      setHosts(await listHosts());
    } catch {
      // The seats still show; the machines come with the next event.
    }
  }, []);

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

  useEffect(() => {
    refreshHosts();
  }, [refreshHosts]);

  // A machine came or went: read them again. A seat this page started: how it went.
  useOperatorEvents(token, EVENTS, (event: string, payload: OperatorEvent) => {
    if (event === "host") refreshHosts();
    if (event === "host_spawn") {
      setSpawns((prev) =>
        prev.map((s) =>
          s.spawnId === payload.spawn_id
            ? { ...s, state: payload.ok ? "started" : "failed", error: payload.ok ? undefined : String(payload.error ?? "") }
            : s,
        ),
      );
      if (payload.ok) {
        refresh();
        refreshHosts();
      }
    }
  });

  function started(spawn: StartedSpawn) {
    setStarting(null);
    setSpawns((prev) => [{ ...spawn, state: "starting" }, ...prev.filter((s) => s.title !== spawn.title)]);
  }

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
          <Link to="/github" className={styles.navLink}>
            GitHub
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
          <div className={styles.toolbarActions}>
            {!adding && (
              <button className={styles.addBtn} onClick={() => setAdding(true)}>
                Add a machine
              </button>
            )}
            {starting === null && (
              <button className={styles.startBtn} onClick={() => setStarting("")}>
                Start a seat
              </button>
            )}
          </div>
        </div>
        {adding && <AddMachine onClose={() => setAdding(false)} />}
        {starting !== null && (
          <StartSeat
            key={starting}
            hosts={hosts}
            initialHost={starting || undefined}
            onClose={() => setStarting(null)}
            onStarted={started}
          />
        )}
        {spawns.length > 0 && (
          <ul className={styles.spawns} aria-live="polite">
            {spawns.map((s) => (
              <li key={s.spawnId} className={styles[`spawn_${s.state}`]}>
                {s.state === "starting" && `Starting ${s.title} on ${s.host}…`}
                {s.state === "started" && `${s.title} is running on ${s.host}.`}
                {s.state === "failed" && `${s.title} did not start on ${s.host}: ${s.error}`}
                {s.state !== "starting" && (
                  <button
                    className={styles.dismissBtn}
                    onClick={() => setSpawns((prev) => prev.filter((x) => x.spawnId !== s.spawnId))}
                    aria-label="Dismiss"
                  >
                    &times;
                  </button>
                )}
              </li>
            ))}
          </ul>
        )}
        <Machines hosts={hosts} onStart={(name) => setStarting(name)} />

        {loading ? (
          <p className={styles.empty}>Loading...</p>
        ) : sessions.length === 0 ? (
          <p className={styles.empty}>
            No seats yet. Add a machine, then Start a seat.
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
                    {s.model && <span>{s.model}</span>}
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
