const API_BASE = import.meta.env.VITE_API_URL || "http://localhost:4000";

export interface JoinCode {
  code: string;
  expires_at: string;
  machine: string | null;
  server: string;
  /** The one-line installer command, with this code in it. */
  command: string;
}

/** POST /api/join_codes: a one-time code (15 minutes) for a new machine. */
export async function createJoinCode(machine?: string): Promise<JoinCode> {
  const token = localStorage.getItem("token");
  const res = await fetch(`${API_BASE}/api/join_codes`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(machine ? { machine } : {}),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error ? `${body.error} (HTTP ${res.status})` : `API error ${res.status}`);
  return body as JoinCode;
}
