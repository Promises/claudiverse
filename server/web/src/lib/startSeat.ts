import type { Host, SpawnRequest } from "../api/hosts";

/** A seat's name: what tmux and the server accept. */
export const TITLE = /^[A-Za-z0-9._-]{1,64}$/;

/** Auto first: the default, as the apps' New seat and the server's spawn. */
export const MODES = [
  { id: "auto", label: "Auto" },
  { id: "default", label: "Ask before acting" },
  { id: "acceptEdits", label: "Accept edits" },
  { id: "plan", label: "Plan only" },
];

/** Aliases Claude Code resolves; "" leaves the machine's Claude Code to choose. */
export const MODELS = [
  { id: "", label: "The machine's default" },
  { id: "opus", label: "Opus" },
  { id: "sonnet", label: "Sonnet" },
  { id: "haiku", label: "Haiku" },
];

/** A name from a folder, as the host agent makes one: unsafe runs become "-". */
export function defaultTitle(path: string): string {
  const base = path.replace(/\/+$/, "").split("/").pop() ?? "";
  const t = base.replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 64);
  return TITLE.test(t) ? t : "seat";
}

/** Each root, then its subfolders: where a seat may work on this machine. */
export function folderChoices(roots: string[], subfolders: Record<string, string[]>): string[] {
  return roots.flatMap((root) => [root, ...(subfolders[root] ?? []).map((d) => `${root.replace(/\/+$/, "")}/${d}`)]);
}

/** The modes this machine allows, in MODES order; all four from an older agent. */
export function modesFor(host: Host | undefined): typeof MODES {
  const allowed = host?.modes ?? [];
  return allowed.length ? MODES.filter((m) => allowed.includes(m.id)) : MODES;
}

export interface StartSeatForm {
  path: string;
  title: string;
  mode: string;
  model: string;
  pooled: boolean;
}

/**
 * The spawn request. A model and pooling go only to an agent that offers
 * them (the server refuses them otherwise); a pool-only machine is always
 * pooled, so nothing is asked of it.
 */
export function spawnRequest(form: StartSeatForm, host: Host): SpawnRequest {
  const offers = host.spawn?.options ?? [];
  const req: SpawnRequest = { path: form.path, title: form.title, mode: form.mode };
  if (form.model && offers.includes("model")) req.model = form.model;
  if (offers.includes("pooled") && !host.spawn?.pool_only) req.pooled = form.pooled;
  return req;
}

/** What is wrong with the form, in the words the form shows; null when it can start. */
export function formProblem(form: StartSeatForm): string | null {
  if (!form.path) return "Choose a folder.";
  if (!TITLE.test(form.title)) return "A name is 1 to 64 letters, digits, dots, dashes or underscores.";
  return null;
}
