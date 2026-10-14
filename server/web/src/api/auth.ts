const API_BASE = import.meta.env.VITE_API_URL || "http://localhost:4000";

export async function request<T>(
  path: string,
  options: RequestInit = {}
): Promise<T> {
  const token = localStorage.getItem("token");
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    ...((options.headers as Record<string, string>) || {}),
  };

  if (token) {
    headers["Authorization"] = `Bearer ${token}`;
  }

  const res = await fetch(`${API_BASE}${path}`, {
    ...options,
    headers,
  });

  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new ApiError(res.status, body);
  }

  return res.json();
}

export class ApiError extends Error {
  status: number;
  body: Record<string, unknown>;

  constructor(status: number, body: Record<string, unknown>) {
    super(`API error ${status}`);
    this.status = status;
    this.body = body;
  }
}

// A server with no account yet needs its first one, made with the one-time
// setup code it logs at boot.
export async function setupStatus() {
  return request<{ setup_needed: boolean }>("/api/setup");
}

// Creates the first account and signs it in, with the same "app" token login
// gives the panel. The server refuses it once any account exists.
export async function setup(email: string, password: string, code: string) {
  return request<{ token: string; user: { id: number; email: string } }>(
    "/api/setup",
    { method: "POST", body: JSON.stringify({ email, password, code, scope: "app", client: "web" }) }
  );
}

// The panel is one of the operator's apps: an "app" token, which may allow a
// seat's permission prompt (an "api" token, a seat's or a runner's, may not).
export async function login(email: string, password: string) {
  return request<{ token: string; user: { id: number; email: string } }>(
    "/api/auth/login",
    { method: "POST", body: JSON.stringify({ email, password, scope: "app", client: "web" }) }
  );
}

export async function logout() {
  return request<{ ok: boolean }>("/api/auth/logout", { method: "DELETE" });
}

/** The signed-in user and the scope of the panel's token ("app", "super", or an older "api"). */
export async function getMe() {
  return request<{ user: { id: number; email: string }; scope: string | null }>("/api/me");
}
