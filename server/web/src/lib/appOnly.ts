/**
 * The scopes a web sign-in may hold. App-only actions (adding a GitHub token,
 * enrolling an account, starting a seat) need "app" or "super"; a sign-in from
 * before the panel asked for "app" (2026-10-07) holds "api", and the server
 * refuses those actions with "… is app-only".
 */
export function hasAppPowers(scope: string | null | undefined): boolean {
  return scope === "app" || scope === "super";
}

/** Whether a server error is its app-only refusal ("GitHub tokens are app-only", "spawning seats is app-only"). */
export function isAppOnlyError(message: string | null | undefined): boolean {
  return typeof message === "string" && /\bapp-only\b/.test(message);
}
