import type { GitHubToken } from "../api/github";

/** "expires in 3 days", "expired 2 days ago", "never expires" (GitHub sent no expiry). */
export function expiryText(expiresAt: string | null, now: Date = new Date()): string {
  if (!expiresAt) return "never expires";
  const days = Math.round((new Date(expiresAt).getTime() - now.getTime()) / 86_400_000);
  if (days < 0) return `expired ${-days} day${days === -1 ? "" : "s"} ago`;
  if (days === 0) return "expires today";
  return `expires in ${days} day${days === 1 ? "" : "s"}`;
}

/** What it may do, as GitHub tells it: a classic token's scopes; a fine-grained token's are not reported. */
export function scopeText(t: Pick<GitHubToken, "kind" | "scopes">): string {
  if (t.kind === "classic") return t.scopes?.length ? t.scopes.join(", ") : "no scopes";
  if (t.kind === "fine_grained") return "fine-grained: GitHub does not report its permissions";
  return "unknown token type";
}
