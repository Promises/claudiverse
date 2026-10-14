const API_BASE = import.meta.env.VITE_API_URL || "http://localhost:4000";

/** A stored GitHub token as the server shows it: what GitHub said about it, never the token. */
export interface GitHubToken {
  id: number;
  label: string;
  kind: "fine_grained" | "classic" | "other";
  login: string | null;
  /** A classic token's scopes; null for a fine-grained one (GitHub does not report its permissions). */
  scopes: string[] | null;
  /** When it expires: GitHub's, else the one entered (`expires_on`); null: never, as far as anyone said. */
  expires_at: string | null;
  expiry_source: "github" | "manual" | null;
  /** The expiry entered here (YYYY-MM-DD), used when GitHub reports none. */
  expires_on: string | null;
  /** Expires within 7 days, or has expired. */
  expiring: boolean;
  repos_count: number | null;
  /** The watched repositories this token reads (the least-privileged token that reaches each). */
  serving: string[];
  status: "ok" | "unauthorized" | "error";
  last_error: string | null;
  checked_at: string | null;
}

async function request<T>(path: string, options: RequestInit = {}): Promise<T> {
  const token = localStorage.getItem("token");
  const res = await fetch(`${API_BASE}${path}`, {
    ...options,
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
  });
  if (res.status === 204) return undefined as T;
  const body = await res.json().catch(() => ({}));
  // The server's own words: they say what to change.
  if (!res.ok) throw new Error(body.error ?? `API error ${res.status}`);
  return body as T;
}

export async function listTokens(): Promise<{ tokens: GitHubToken[]; vault_configured: boolean }> {
  return request("/api/github/tokens");
}

/** Checked against GitHub first, then stored encrypted. */
export async function addToken(label: string, token: string): Promise<GitHubToken> {
  return (await request<{ token: GitHubToken }>("/api/github/tokens", { method: "POST", body: JSON.stringify({ label, token }) })).token;
}

export async function checkToken(id: number): Promise<GitHubToken> {
  return (await request<{ token: GitHubToken }>(`/api/github/tokens/${id}/check`, { method: "POST" })).token;
}

export async function removeToken(id: number): Promise<void> {
  await request(`/api/github/tokens/${id}`, { method: "DELETE" });
}

/** The expiry used when GitHub reports none (YYYY-MM-DD), or null to clear it. */
export async function setExpiresOn(id: number, expiresOn: string | null): Promise<GitHubToken> {
  return (await request<{ token: GitHubToken }>(`/api/github/tokens/${id}`, { method: "PATCH", body: JSON.stringify({ expires_on: expiresOn }) })).token;
}

/** A GitHub title the user's seats watch, and how it is read. */
export interface GitHubSubscription {
  title: string;
  seats: string[];
  /** owner/name, or null for gh:@me and @github. */
  repo: string | null;
  /** The token that reads the repository; null if none reaches it (it is then never read). */
  token: { id: number; label: string; kind: GitHubToken["kind"] } | null;
  reached: boolean;
  /** Why a repository is not read: no token reaches it, or a token's repository list is not loaded yet. */
  unreached: "no_token" | "repos_not_loaded" | null;
  last_read_at: string | null;
}

export async function listSubscriptions(): Promise<GitHubSubscription[]> {
  return (await request<{ subscriptions: GitHubSubscription[] }>("/api/github/subscriptions")).subscriptions;
}
