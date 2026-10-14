/**
 * The models a seat can be switched to (`/model <id>`) or started with
 * (`--model <id>`). The server serves the list (GET /api/models, from
 * server/api/priv/models.json) so the web and the apps cannot drift;
 * BUILT_IN is the same list, used until it loads or if it cannot (a test
 * holds the two equal).
 *
 * Exact ids, never prefixes: the fleet runs Opus 5 and Opus 5.5 side by side,
 * and "claude-opus-5" is a prefix of "claude-opus-5-5". Only bare ids are
 * sent from here.
 */
export interface Model {
  id: string;
  label: string;
  family: string;
  /** The bare id has a 1M context window (every Claude 5 model). */
  one_m: boolean;
  /** `<id>[1m]` gives it the 1M window (Claude Code's "optIn"). */
  accepts_1m_suffix: boolean;
  /** The first Claude Code version that knows it, or null. */
  since: string | null;
  /** An earlier generation, folded away. */
  older: boolean;
}

export interface Alias {
  id: string;
  label: string;
}

export interface ModelList {
  models: Model[];
  aliases: Alias[];
}

const m = (id: string, label: string, family: string, one_m: boolean, accepts_1m_suffix: boolean, since: string | null, older: boolean): Model =>
  ({ id, label, family, one_m, accepts_1m_suffix, since, older });

export const BUILT_IN: ModelList = {
  models: [
    m("claude-opus-5-5", "Opus 5.5", "opus", true, false, null, false),
    m("claude-opus-5", "Opus 5", "opus", true, false, null, false),
    m("claude-sonnet-5-5", "Sonnet 5.5", "sonnet", true, false, null, false),
    m("claude-sonnet-5", "Sonnet 5", "sonnet", true, false, null, false),
    m("claude-haiku-5-5", "Haiku 5.5", "haiku", true, false, "2.1.293", false),
    m("claude-fable-5-1", "Fable 5.1", "fable", true, false, null, false),
    m("claude-fable-5", "Fable 5", "fable", true, false, null, false),
    m("claude-mythos-5-1", "Mythos 5.1", "mythos", true, false, null, false),
    m("claude-mythos-5", "Mythos 5", "mythos", true, false, null, false),
    m("claude-haiku-4-5", "Haiku 4.5", "haiku", false, false, null, false),
    m("claude-opus-4-8", "Opus 4.8", "opus", true, false, null, true),
    m("claude-opus-4-7", "Opus 4.7", "opus", true, false, null, true),
    m("claude-opus-4-6", "Opus 4.6", "opus", false, true, null, true),
    m("claude-opus-4-5", "Opus 4.5", "opus", false, false, null, true),
    m("claude-opus-4-1", "Opus 4.1", "opus", false, false, null, true),
    m("claude-sonnet-4-6", "Sonnet 4.6", "sonnet", false, true, null, true),
    m("claude-sonnet-4-5", "Sonnet 4.5", "sonnet", false, true, null, true),
    m("claude-sonnet-4-0", "Sonnet 4", "sonnet", false, true, null, true),
  ],
  aliases: [
    { id: "default", label: "Default" },
    { id: "opus", label: "Opus (latest)" },
    { id: "sonnet", label: "Sonnet (latest)" },
    { id: "haiku", label: "Haiku (latest)" },
    { id: "opusplan", label: "Opus plan" },
  ],
};

/** How a model is shown in a picker: its context window when it is 1M as sent. */
export const modelLabel = (model: Model): string => (model.one_m ? `${model.label} (1M)` : model.label);

// A dated snapshot of a model: "claude-haiku-4-5-20251001".
const DATED = /-2\d{7}$/;

/**
 * The choice a seat's reported model is, or "" for one not on the list (shown
 * as reported, never snapped to a neighbour). A seat reports the bare id in
 * its replies ("claude-opus-5-5"), its row may carry "[1m]", and an older
 * model a dated id.
 */
export function modelChoice(reported: string | null | undefined, list: ModelList = BUILT_IN): string {
  if (!reported) return "";
  const r = reported.trim().toLowerCase().replace(/\[1m\]$/, "");
  const hit =
    [...list.models, ...list.aliases].find((c) => c.id === r) ??
    list.models.find((c) => DATED.test(r) && r.replace(DATED, "") === c.id);
  return hit ? hit.id : "";
}

// "2.1.293" < "2.1.296"; a version that is not a.b.c sorts as unknown (null).
const parts = (v: string): number[] | null => (/^\d+\.\d+\.\d+/.test(v) ? v.split(/[.\s(]/).slice(0, 3).map(Number) : null);

/**
 * Whether Claude Code `version` (a machine's spawn.version) knows `model`. An
 * unknown version is given the benefit of the doubt: Claude Code refuses an id
 * it does not know, in its own words.
 */
export function knownTo(model: Model, version: string | null | undefined): boolean {
  if (!model.since || !version) return true;
  const have = parts(version), need = parts(model.since);
  if (!have || !need) return true;
  for (let i = 0; i < 3; i++) if (have[i] !== need[i]) return have[i] > need[i];
  return true;
}
