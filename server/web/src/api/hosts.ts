const API_BASE = import.meta.env.VITE_API_URL || "http://localhost:4000";

/** What a plain spawn may ask for on a machine (its agent's join, 0.13+). */
export interface HostSpawn {
  options: string[];
  /** The machine has no Claude login of its own: its seats always use the pool. */
  pool_only: boolean;
  /** Whether its seats use the pool when nothing is asked. */
  pooled: boolean;
  /** The Claude Code version a new seat there runs (0.14+), or null. */
  version?: string | null;
}

export interface Host {
  name: string;
  online: boolean;
  /** Running seats on it. */
  seats: number;
  /** The folders seats may work in (empty while offline). */
  roots: string[];
  version: string | null;
  modes: string[];
  /** null: offline, or an agent older than 0.13 (no model or pooling). */
  spawn: HostSpawn | null;
  /** Its agent's last join or leave; null if never seen since the server recorded it. */
  last_seen_at: string | null;
}

export interface FolderListing {
  path: string;
  parent: string | null;
  /** Subfolder names (for path ""; the roots, as full paths). */
  dirs: string[];
  truncated: boolean;
}

export interface SpawnRequest {
  path: string;
  title: string;
  mode: string;
  model?: string;
  pooled?: boolean;
}

async function request<T>(path: string, options: RequestInit = {}): Promise<T> {
  const token = localStorage.getItem("token");
  const res = await fetch(`${API_BASE}${path}`, {
    ...options,
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
  });
  const body = await res.json().catch(() => ({}));
  // The server's own words: they say what to change ("update it", "one spawn per 10 s").
  if (!res.ok) throw new Error(body.error ?? `API error ${res.status}`);
  return body as T;
}

/** GET /api/hosts: every machine, online or last seen. */
export async function listHosts(): Promise<Host[]> {
  return (await request<{ hosts: Host[] }>("/api/hosts")).hosts;
}

/** GET /api/hosts/:host/ls: the subfolders of `path`, answered by the machine. */
export async function listFolders(host: string, path: string): Promise<FolderListing> {
  return request<FolderListing>(`/api/hosts/${encodeURIComponent(host)}/ls?path=${encodeURIComponent(path)}`);
}

/** POST /api/hosts/:host/spawn: 202 at once; the outcome comes as host_spawn. */
export async function spawnSeat(host: string, body: SpawnRequest): Promise<{ spawn_id: string }> {
  return request<{ spawn_id: string }>(`/api/hosts/${encodeURIComponent(host)}/spawn`, {
    method: "POST",
    body: JSON.stringify(body),
  });
}
