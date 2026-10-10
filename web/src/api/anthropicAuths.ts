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
    // Surface the server's own reason. A bare "API error 400" on the enrolment
    // screen is the difference between "your paste was truncated" and an
    // afternoon of guessing.
    let detail = "";
    try {
      const body = await res.json();
      detail = body.detail || body.error || "";
    } catch {
      /* non-JSON error body */
    }
    throw new Error(detail ? `${detail} (HTTP ${res.status})` : `API error ${res.status}`);
  }

  return res.json() as Promise<T>;
}

export type AuthStatus = "available" | "cooling_down" | "needs_reauth";

/**
 * One limit window from Anthropic's oauth/usage response.
 *
 * MEASURED shape (2026-09-11, live account):
 *   {group:"session", kind:"session", percent:34,
 *    resets_at:"2026-09-12T16:40:00Z", severity:"normal",
 *    is_active:true, scope:null}
 *   {group:"weekly", kind:"weekly_scoped", percent:0,
 *    scope:{model:{display_name:"Fable"}}, ...}
 */
export interface UsageLimit {
  group?: string;
  kind?: string;
  percent?: number;
  resets_at?: string;
  severity?: string;
  is_active?: boolean;
  scope?: { model?: { display_name?: string | null } | null; surface?: string | null } | null;
}

/**
 * Usage snapshot.
 *
 * Render from `limits` — it is a uniform array pairing each percent with ITS
 * OWN reset time, and new limit kinds arrive as new entries rather than new
 * top-level keys.
 *
 * ⚠️ The response also carries ~9 always-null keys with names like
 * `amber_ladder`, `cinder_cove`, `juniper_tide`. They look deliberately
 * decoy-shaped. Do not read them.
 *
 * Every field stays optional: a missing value renders as "unknown", never as
 * 0%. A poll can fail, and an account that silently reads 0% used is the one a
 * router would send work to first.
 */
export interface UsageSnapshot {
  limits?: UsageLimit[];
  five_hour?: { utilization?: number; resets_at?: string };
  seven_day?: { utilization?: number; resets_at?: string };
  extra_usage?: { is_enabled?: boolean; spend_limit_reached?: boolean };
  [key: string]: unknown;
}

export interface AnthropicAuth {
  id: number;
  label: string;
  account_email: string | null;
  status: AuthStatus;
  cooldown_until: string | null;
  cooldown_reason: string | null;
  priority: number;
  token_valid: boolean;
  expires_at: string | null;
  last_refreshed_at: string | null;
  last_leased_at: string | null;
  usage: UsageSnapshot | null;
  usage_checked_at: string | null;
}

export interface AuthListResponse {
  vault_configured: boolean;
  auths: AnthropicAuth[];
}

export interface AuthorizationStart {
  url: string;
  verifier: string;
  state: string;
}

export function listAuths(): Promise<AuthListResponse> {
  return request<AuthListResponse>("/api/anthropic_auths");
}

export function startAuthorization(): Promise<AuthorizationStart> {
  return request<AuthorizationStart>("/api/anthropic_auths/authorize", { method: "POST" });
}

export function completeAuthorization(params: {
  label: string;
  code: string;
  verifier: string;
  state: string;
  priority?: number;
}): Promise<AnthropicAuth> {
  return request<AnthropicAuth>("/api/anthropic_auths/complete", {
    method: "POST",
    body: JSON.stringify(params),
  });
}

export function refreshUsage(id: number): Promise<AnthropicAuth> {
  return request<AnthropicAuth>(`/api/anthropic_auths/${id}/usage`, { method: "POST" });
}

export function deleteAuth(id: number): Promise<{ deleted: string }> {
  return request<{ deleted: string }>(`/api/anthropic_auths/${id}`, { method: "DELETE" });
}
