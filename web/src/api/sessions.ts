import type { Session } from "../lib/types";

const API_BASE = import.meta.env.VITE_API_URL || "http://localhost:4000";

function authHeaders(): Record<string, string> {
  const token = localStorage.getItem("token");
  return {
    "Content-Type": "application/json",
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
  };
}

async function request<T>(path: string, options: RequestInit = {}): Promise<T> {
  const res = await fetch(`${API_BASE}${path}`, {
    ...options,
    headers: { ...authHeaders(), ...((options.headers as Record<string, string>) || {}) },
  });

  if (!res.ok) {
    throw new Error(`API error ${res.status}`);
  }

  return res.json();
}

export async function listSessions() {
  return request<{ sessions: Session[] }>("/api/sessions");
}

export async function getSession(id: number) {
  return request<{ session: Session; live: { status: string; sidecar_connected: boolean } | null }>(
    `/api/sessions/${id}`
  );
}

export async function deleteSession(id: number) {
  return request<{ ok: boolean }>(`/api/sessions/${id}`, { method: "DELETE" });
}
