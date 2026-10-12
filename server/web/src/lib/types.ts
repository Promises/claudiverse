export interface User {
  id: number;
  email: string;
}

export interface Session {
  id: number;
  /** Addressable name — what cv_send and ?title= resolve. Kebab, unique per live seat. */
  title: string;
  /**
   * The name Claude Code's own session picker shows, sentence case.
   * DISPLAY ONLY: it is derived from the conversation, changes as the session
   * evolves, and two sessions can share one — never address a seat by it.
   * Null until the session has been auto-titled.
   */
  display_title: string | null;
  type: "sidecar" | "spawned";
  mode: "json" | "pty";
  status: "running" | "stopped" | "crashed";
  /** What the seat runs: from its replies, or its profile's model before the
   *  first one. null when nothing has said yet; never a guessed default. */
  model: string | null;
  working_directory: string | null;
  inserted_at: string;
  /**
   * When the session last produced a message. The list is ordered by this.
   * OPTIONAL: a server predating this field omits it, and the UI falls back to
   * inserted_at rather than rendering a blank.
   */
  last_activity_at?: string;
  /**
   * Live state from the session's Room — the difference between a seat WORKING
   * and one sitting at a prompt. `status` only distinguishes running/stopped.
   */
  activity?: "busy" | "idle" | "disconnected" | "unknown";
  /** The fleet the seat belongs to, and the machine it runs on; null when it has none. */
  fleet?: string | null;
  host?: string | null;
}

export type ForumStatus = "incoming" | "active" | "done";

export interface ForumChannel {
  slug: string;
  title: string;
  description: string | null;
  inserted_at: string;
}

/** Full post shape returned by post_json (thread reads + mutation responses). */
export interface ForumPost {
  id: number;
  channel: string;
  author: string;
  body: string;
  title: string | null;
  status: ForumStatus;
  owner: string | null;
  pinned: boolean;
  pinned_at: string | null;
  archived: boolean;
  archived_at: string | null;
  parent_id: number | null;
  thread_root_id: number | null;
  permalink: string;
  inserted_at: string;
  updated_at: string;
}

/** Lean board row returned by compact_json (top-level, no body). */
export interface ForumCompactPost {
  id: number;
  channel: string;
  title: string | null;
  status: ForumStatus;
  owner: string | null;
  author: string;
  pinned: boolean;
  archived: boolean;
  reply_count: number;
  permalink: string;
  updated_at: string;
}

export interface ForumSearchResult {
  id: number;
  channel: string;
  author: string;
  snippet: string;
  permalink: string;
  inserted_at: string;
}

export interface SDKMessage {
  type: string;
  [key: string]: unknown;
}

export interface PermissionRequest {
  request_id: string;
  tool_name: string;
  input: Record<string, unknown>;
  display_name?: string;
  description?: string;
  title?: string;
}
