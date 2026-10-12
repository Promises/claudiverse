import type { Host } from "../api/hosts";
import { relativeTime } from "../lib/relativeTime";
import styles from "./Machines.module.css";

interface Props {
  hosts: Host[];
  onStart: (host: string) => void;
}

/** What a machine is doing, in a few words: online, or when it was last seen. */
function machineStatus(h: Host): string {
  if (h.online) return "online";
  return h.last_seen_at ? `last seen ${relativeTime(h.last_seen_at)}` : "offline";
}

/**
 * The machines that run seats: online, or when each was last seen, and how
 * many seats run there. An online one can start a seat from here.
 */
export default function Machines({ hosts, onStart }: Props) {
  if (hosts.length === 0) return null;
  return (
    <section className={styles.panel} aria-label="Machines">
      <h3 className={styles.heading}>Machines</h3>
      <ul className={styles.list}>
        {hosts.map((h) => (
          <li key={h.name} className={styles.item}>
            <span className={`${styles.dot} ${h.online ? styles.dotOnline : styles.dotOffline}`} aria-hidden="true" />
            <span className={styles.name}>{h.name}</span>
            <span className={h.online ? styles.online : styles.meta}>{machineStatus(h)}</span>
            <span className={styles.meta}>
              {h.seats} {h.seats === 1 ? "seat" : "seats"} running
            </span>
            {h.online && (
              <button className={styles.startBtn} onClick={() => onStart(h.name)}>
                Start a seat
              </button>
            )}
          </li>
        ))}
      </ul>
    </section>
  );
}
