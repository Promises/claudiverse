/**
 * Coarse on purpose. A dashboard is scanned, not read: "4m" answers "did this
 * move recently", and second-level precision only adds digits to compare.
 * A time without a zone is the server's UTC.
 */
export function relativeTime(iso: string, now: number = Date.now()): string {
  const then = new Date(/[zZ]|[+-]\d\d:\d\d$/.test(iso) ? iso : iso + "Z").getTime();
  if (Number.isNaN(then)) return "";
  const secs = Math.max(0, Math.round((now - then) / 1000));
  if (secs < 45) return "just now";
  const mins = Math.round(secs / 60);
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.round(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  return `${Math.round(hrs / 24)}d ago`;
}
