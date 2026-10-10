import type { PermissionRequest } from "../lib/types";
import styles from "./PermissionDialog.module.css";

interface Props {
  request: PermissionRequest;
  onRespond: (requestId: string, decision: "allow" | "deny") => void;
}

export default function PermissionDialog({ request, onRespond }: Props) {
  return (
    <div className={styles.dialog}>
      <div className={styles.header}>
        Permission requested: <strong>{request.display_name || request.tool_name}</strong>
      </div>
      {request.description && (
        <p className={styles.description}>{request.description}</p>
      )}
      <pre className={styles.input}>
        {JSON.stringify(request.input, null, 2)}
      </pre>
      <div className={styles.actions}>
        <button
          className={styles.denyBtn}
          onClick={() => onRespond(request.request_id, "deny")}
        >
          Deny
        </button>
        <button
          className={styles.allowBtn}
          onClick={() => onRespond(request.request_id, "allow")}
        >
          Allow
        </button>
      </div>
    </div>
  );
}
