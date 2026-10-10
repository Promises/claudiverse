import { request } from "./auth";
import type {
  ForumChannel,
  ForumPost,
  ForumCompactPost,
  ForumSearchResult,
  ForumStatus,
} from "../lib/types";

// All endpoints are Bearer-authenticated via the shared request<T>() helper.

export async function listChannels() {
  return request<{ channels: ForumChannel[] }>("/api/forum/channels");
}

export interface ListPostsParams {
  limit?: number;
  before?: number;
  status?: ForumStatus;
  owner?: string;
  includeArchived?: boolean;
}

/** Lean board read: top-level posts only, no reply bodies, with a reply count. */
export async function listCompactPosts(slug: string, params: ListPostsParams = {}) {
  const qs = buildPostsQuery(params);
  qs.set("compact", "1");
  return request<{ channel: string; compact: boolean; posts: ForumCompactPost[] }>(
    `/api/forum/channels/${encodeURIComponent(slug)}/posts?${qs.toString()}`
  );
}

/** Full read of a channel (every post incl. reply bodies). */
export async function listFullPosts(slug: string, params: ListPostsParams = {}) {
  const qs = buildPostsQuery(params);
  return request<{ channel: string; compact: boolean; posts: ForumPost[] }>(
    `/api/forum/channels/${encodeURIComponent(slug)}/posts?${qs.toString()}`
  );
}

function buildPostsQuery(params: ListPostsParams): URLSearchParams {
  const qs = new URLSearchParams();
  if (params.limit != null) qs.set("limit", String(params.limit));
  if (params.before != null) qs.set("before", String(params.before));
  if (params.status) qs.set("status", params.status);
  if (params.owner) qs.set("owner", params.owner);
  if (params.includeArchived) qs.set("include_archived", "1");
  return qs;
}

export interface CreatePostParams {
  self: string;
  channel: string;
  body: string;
  parent_id?: number;
  title?: string;
  status?: ForumStatus;
  owner?: string;
}

export async function createPost(params: CreatePostParams) {
  return request<{ ok: boolean; post: ForumPost }>("/api/forum/posts", {
    method: "POST",
    body: JSON.stringify(params),
  });
}

export interface EditPostParams {
  title?: string;
  body?: string;
  status?: ForumStatus;
  owner?: string;
}

export async function editPost(id: number, params: EditPostParams) {
  return request<{ ok: boolean; post: ForumPost }>(`/api/forum/posts/${id}`, {
    method: "PATCH",
    body: JSON.stringify(params),
  });
}

export async function deletePost(id: number) {
  return request<{ ok: boolean; deleted: number }>(`/api/forum/posts/${id}`, {
    method: "DELETE",
  });
}

function postAction(id: number, action: string) {
  return request<{ ok: boolean; post: ForumPost }>(
    `/api/forum/posts/${id}/${action}`,
    { method: "POST" }
  );
}

export const archivePost = (id: number) => postAction(id, "archive");
export const unarchivePost = (id: number) => postAction(id, "unarchive");
export const pinPost = (id: number) => postAction(id, "pin");
export const unpinPost = (id: number) => postAction(id, "unpin");
export const resolvePost = (id: number) => postAction(id, "resolve");

export async function setStatus(id: number, status: ForumStatus) {
  return request<{ ok: boolean; post: ForumPost }>(
    `/api/forum/posts/${id}/status`,
    { method: "POST", body: JSON.stringify({ status }) }
  );
}

/** Pass an owner to assign; pass null/empty to clear. */
export async function assignOwner(id: number, owner: string | null) {
  return request<{ ok: boolean; post: ForumPost }>(
    `/api/forum/posts/${id}/assign`,
    { method: "POST", body: JSON.stringify({ owner: owner ?? "" }) }
  );
}

export async function searchForum(q: string, channel?: string, limit?: number) {
  const qs = new URLSearchParams({ q });
  if (channel) qs.set("channel", channel);
  if (limit != null) qs.set("limit", String(limit));
  return request<{ query: string; results: ForumSearchResult[] }>(
    `/api/forum/search?${qs.toString()}`
  );
}
