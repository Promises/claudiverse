import { useState } from "react";
import { createJoinCode, type JoinCode } from "../api/joinCodes";
import styles from "./AddMachine.module.css";

/**
 * Add a machine: mints a one-time join code and shows the one-line installer
 * command that uses it. Run on the new machine, the installer redeems the
 * code for the machine's tokens, so no token is ever copied by hand.
 */
export default function AddMachine({ onClose }: { onClose: () => void }) {
  const [name, setName] = useState("");
  const [join, setJoin] = useState<JoinCode | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [copied, setCopied] = useState(false);

  async function mint() {
    setBusy(true);
    setError(null);
    try {
      setJoin(await createJoinCode(name.trim() || undefined));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  async function copy() {
    if (!join) return;
    await navigator.clipboard.writeText(join.command);
    setCopied(true);
  }

  return (
    <section className={styles.panel} aria-label="Add a machine">
      <h3 className={styles.heading}>Add a machine</h3>
      {!join ? (
        <>
          <p className={styles.hint}>
            On the machine that will run seats, you will paste one command. It installs what the machine needs and joins
            it to this server. The code in it works once, for 15 minutes.
          </p>
          <div className={styles.form}>
            <input
              className={styles.nameInput}
              placeholder="Machine name (optional: its hostname by default)"
              value={name}
              onChange={(e) => setName(e.target.value)}
              aria-label="Machine name"
            />
            <button className={styles.primaryBtn} onClick={mint} disabled={busy}>
              {busy ? "Making…" : "Make the command"}
            </button>
            <button className={styles.secondaryBtn} onClick={onClose}>
              Cancel
            </button>
          </div>
        </>
      ) : (
        <>
          <p className={styles.hint}>Run this on the new machine, in a terminal:</p>
          <pre className={styles.command} data-testid="join-command">{join.command}</pre>
          <div className={styles.meta}>
            <span>
              Join code <strong>{join.code}</strong>
              {join.machine ? ` for ${join.machine}` : ""}, valid until {new Date(join.expires_at).toLocaleTimeString()}
            </span>
            <span>
              <button className={styles.secondaryBtn} onClick={copy}>
                {copied ? "Copied" : "Copy"}
              </button>{" "}
              <button className={styles.secondaryBtn} onClick={onClose}>
                Done
              </button>
            </span>
          </div>
        </>
      )}
      {error && <p className={styles.error}>{error}</p>}
    </section>
  );
}
