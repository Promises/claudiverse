import { useEffect, useState, type FormEvent } from "react";
import { listFolders, spawnSeat, type Host } from "../api/hosts";
import {
  MODELS,
  defaultTitle,
  folderChoices,
  formProblem,
  modesFor,
  spawnRequest,
  type StartSeatForm,
} from "../lib/startSeat";
import styles from "./StartSeat.module.css";

export interface StartedSpawn {
  spawnId: string;
  host: string;
  title: string;
}

interface Props {
  hosts: Host[];
  /** The machine to start on, when the form was opened from it. */
  initialHost?: string;
  onClose: () => void;
  onStarted: (spawn: StartedSpawn) => void;
}

/**
 * Start a seat on a machine, as the apps' New seat does (the server's spawn):
 * a folder inside the machine's roots, a name (the folder's by default), the
 * permission mode (auto by default), the model (the machine's Claude Code
 * chooses by default) and whether it uses the server's account pool (on by
 * default). Model and pooling are offered only where the machine's agent can
 * apply them.
 */
export default function StartSeat({ hosts, initialHost, onClose, onStarted }: Props) {
  const online = hosts.filter((h) => h.online);
  const [hostName, setHostName] = useState(initialHost ?? online[0]?.name ?? "");
  const host = online.find((h) => h.name === hostName);
  const [subfolders, setSubfolders] = useState<Record<string, string[]>>({});
  const [form, setForm] = useState<StartSeatForm>({ path: "", title: "", mode: "auto", model: "", pooled: true });
  const [titleEdited, setTitleEdited] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // The machine's folders: each root and its subfolders, read from the machine.
  const roots = host?.roots;
  useEffect(() => {
    if (!hostName || !roots) return;
    let gone = false;
    Promise.all(roots.map((r) => listFolders(hostName, r).then((l) => [r, l.dirs] as const).catch(() => [r, []] as const)))
      .then((pairs) => {
        if (!gone) setSubfolders(Object.fromEntries(pairs));
      });
    return () => {
      gone = true;
    };
  }, [hostName, roots]);

  const folders = folderChoices(roots ?? [], subfolders);
  const path = folders.includes(form.path) ? form.path : (folders[0] ?? "");
  const title = titleEdited ? form.title : path ? defaultTitle(path) : "";
  const modes = modesFor(host);
  const mode = modes.some((m) => m.id === form.mode) ? form.mode : modes[0].id;
  const offers = host?.spawn?.options ?? [];
  const poolOnly = host?.spawn?.pool_only === true;
  const current: StartSeatForm = { ...form, path, title, mode };
  const problem = host ? formProblem(current) : null;

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (!host || problem) return;
    setBusy(true);
    setError(null);
    try {
      const { spawn_id } = await spawnSeat(host.name, spawnRequest(current, host));
      onStarted({ spawnId: spawn_id, host: host.name, title });
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  }

  if (online.length === 0) {
    return (
      <section className={styles.panel} aria-label="Start a seat">
        <h3 className={styles.heading}>Start a seat</h3>
        <p className={styles.hint}>
          No machine is online. Add a machine, or start the host agent on one that was set up before.
        </p>
        <div className={styles.actions}>
          <button type="button" className={styles.secondaryBtn} onClick={onClose}>
            Close
          </button>
        </div>
      </section>
    );
  }

  return (
    <form className={styles.panel} aria-label="Start a seat" onSubmit={submit}>
      <h3 className={styles.heading}>Start a seat</h3>
      <div className={styles.fields}>
        <label className={styles.field} htmlFor="start-machine">
          <span className={styles.label}>Machine</span>
          <select id="start-machine" className={styles.input} value={hostName} onChange={(e) => setHostName(e.target.value)}>
            {online.map((h) => (
              <option key={h.name} value={h.name}>
                {h.name}
              </option>
            ))}
          </select>
        </label>

        <label className={styles.field} htmlFor="start-folder">
          <span className={styles.label}>Folder</span>
          <select
            id="start-folder"
            className={styles.input}
            value={path}
            onChange={(e) => setForm({ ...form, path: e.target.value })}
            disabled={folders.length === 0}
          >
            {folders.length === 0 && <option value="">This machine allows no folders</option>}
            {folders.map((f) => (
              <option key={f} value={f}>
                {f}
              </option>
            ))}
          </select>
        </label>

        <label className={styles.field} htmlFor="start-name">
          <span className={styles.label}>Name</span>
          <input
            id="start-name"
            className={styles.input}
            value={title}
            onChange={(e) => {
              setTitleEdited(true);
              setForm({ ...form, title: e.target.value });
            }}
            spellCheck={false}
            autoComplete="off"
          />
        </label>

        <label className={styles.field} htmlFor="start-mode">
          <span className={styles.label}>Permission mode</span>
          <select id="start-mode" className={styles.input} value={mode} onChange={(e) => setForm({ ...form, mode: e.target.value })}>
            {modes.map((m) => (
              <option key={m.id} value={m.id}>
                {m.label}
              </option>
            ))}
          </select>
        </label>

        <label className={styles.field} htmlFor="start-model">
          <span className={styles.label}>Model</span>
          <select
            id="start-model"
            className={styles.input}
            value={offers.includes("model") ? form.model : ""}
            onChange={(e) => setForm({ ...form, model: e.target.value })}
            disabled={!offers.includes("model")}
          >
            {MODELS.map((m) => (
              <option key={m.id} value={m.id}>
                {m.label}
              </option>
            ))}
          </select>
        </label>

        <label className={styles.check} htmlFor="start-pooled">
          <input
            id="start-pooled"
            type="checkbox"
            checked={poolOnly || (offers.includes("pooled") ? form.pooled : host?.spawn?.pooled === true)}
            onChange={(e) => setForm({ ...form, pooled: e.target.checked })}
            disabled={poolOnly || !offers.includes("pooled")}
          />
          <span>Use the server's account pool</span>
        </label>
      </div>

      {poolOnly && <p className={styles.hint}>{hostName} has no Claude login of its own, so its seats always use the pool.</p>}
      {host && !host.spawn && (
        <p className={styles.hint}>
          {hostName}'s host agent is older than this form: the model and the pool are its own defaults. Run the installer
          again on {hostName} to choose them here.
        </p>
      )}
      {problem && <p className={styles.problem}>{problem}</p>}
      {error && (
        <p className={styles.error} role="alert">
          {error}
        </p>
      )}

      <div className={styles.actions}>
        <button type="submit" className={styles.primaryBtn} disabled={busy || !!problem}>
          {busy ? "Starting…" : "Start the seat"}
        </button>
        <button type="button" className={styles.secondaryBtn} onClick={onClose}>
          Cancel
        </button>
      </div>
    </form>
  );
}
