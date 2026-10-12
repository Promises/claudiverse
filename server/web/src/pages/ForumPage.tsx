import { useState, useEffect, useCallback } from "react";
import { Link } from "react-router-dom";
import { useAuth } from "../contexts/AuthContext";
import * as forum from "../api/forum";
import type {
  ForumChannel,
  ForumCompactPost,
  ForumPost,
  ForumStatus,
} from "../lib/types";
import BrandLogo from "../components/BrandLogo";
import { useDocumentTitle } from "../hooks/useDocumentTitle";
import styles from "./ForumPage.module.css";

const STATUSES: ForumStatus[] = ["incoming", "active", "done"];

export default function ForumPage() {
  const { user, logout } = useAuth();
  useDocumentTitle("Forum");

  // Identity used as `self` (author) when creating posts/replies. The fleet
  // shares one account, so the API needs an explicit author title rather than
  // inferring from the token — default to the logged-in email, but allow an
  // override (persisted) so a human can post under a chosen handle.
  const [self, setSelf] = useState<string>(
    () => localStorage.getItem("forum_self") || user?.email || ""
  );
  useEffect(() => {
    if (self) localStorage.setItem("forum_self", self);
  }, [self]);

  const [channels, setChannels] = useState<ForumChannel[]>([]);
  const [slug, setSlug] = useState<string | null>(null);

  const [posts, setPosts] = useState<ForumCompactPost[]>([]);
  const [boardLoading, setBoardLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Filters
  const [statusFilter, setStatusFilter] = useState<ForumStatus | "">("");
  const [ownerFilter, setOwnerFilter] = useState("");
  const [includeArchived, setIncludeArchived] = useState(false);

  // Thread expansion
  const [expandedId, setExpandedId] = useState<number | null>(null);
  const [threadPosts, setThreadPosts] = useState<ForumPost[]>([]);
  const [threadLoading, setThreadLoading] = useState(false);

  // New-post composer
  const [showComposer, setShowComposer] = useState(false);

  const loadChannels = useCallback(async () => {
    try {
      const res = await forum.listChannels();
      setChannels(res.channels);
      setSlug((cur) => cur ?? res.channels[0]?.slug ?? null);
    } catch {
      setError("Failed to load channels");
    }
  }, []);

  useEffect(() => {
    loadChannels();
  }, [loadChannels]);

  const loadBoard = useCallback(async () => {
    if (!slug) return;
    setBoardLoading(true);
    setError(null);
    try {
      const res = await forum.listCompactPosts(slug, {
        status: statusFilter || undefined,
        owner: ownerFilter.trim() || undefined,
        includeArchived,
      });
      setPosts(res.posts);
    } catch {
      setError("Failed to load board");
    } finally {
      setBoardLoading(false);
    }
  }, [slug, statusFilter, ownerFilter, includeArchived]);

  useEffect(() => {
    loadBoard();
  }, [loadBoard]);

  const loadThread = useCallback(
    async (rootId: number) => {
      if (!slug) return;
      setThreadLoading(true);
      try {
        // Full read of the channel, then filter to this thread (root + replies).
        const res = await forum.listFullPosts(slug, { includeArchived: true });
        const thread = res.posts.filter(
          (p) => p.id === rootId || p.thread_root_id === rootId
        );
        thread.sort(
          (a, b) =>
            new Date(a.inserted_at).getTime() - new Date(b.inserted_at).getTime()
        );
        setThreadPosts(thread);
      } catch {
        setError("Failed to load thread");
      } finally {
        setThreadLoading(false);
      }
    },
    [slug]
  );

  function toggleThread(id: number) {
    if (expandedId === id) {
      setExpandedId(null);
      setThreadPosts([]);
    } else {
      setExpandedId(id);
      loadThread(id);
    }
  }

  // Run a mutation, then refresh whatever's on screen.
  const runMutation = useCallback(
    async (fn: () => Promise<unknown>) => {
      setError(null);
      try {
        await fn();
        await loadBoard();
        if (expandedId != null) await loadThread(expandedId);
      } catch {
        setError("Action failed");
      }
    },
    [loadBoard, loadThread, expandedId]
  );

  const root = threadPosts.find((p) => p.id === expandedId) || null;

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <div className={styles.headerLeft}>
          <Link to="/" className={styles.backBtn}>
            &larr; Dashboard
          </Link>
          <h1 className={styles.logo}>
            <BrandLogo />
            Forum
          </h1>
        </div>
        <div className={styles.headerRight}>
          <label className={styles.selfField} title="Author identity for new posts">
            <span>Posting as</span>
            <input
              className={styles.selfInput}
              value={self}
              onChange={(e) => setSelf(e.target.value)}
              placeholder="your-handle"
            />
          </label>
          <span className={styles.email}>{user?.email}</span>
          <button onClick={logout} className={styles.logoutBtn}>
            Sign out
          </button>
        </div>
      </header>

      <div className={styles.body}>
        <aside className={styles.sidebar}>
          <h2 className={styles.sidebarTitle}>Channels</h2>
          <ul className={styles.channelList}>
            {channels.map((c) => (
              <li key={c.slug}>
                <button
                  className={`${styles.channelBtn} ${
                    c.slug === slug ? styles.channelActive : ""
                  }`}
                  onClick={() => {
                    setSlug(c.slug);
                    setExpandedId(null);
                    setThreadPosts([]);
                  }}
                >
                  <span className={styles.channelName}>{c.title || c.slug}</span>
                  {c.description && (
                    <span className={styles.channelDesc}>{c.description}</span>
                  )}
                </button>
              </li>
            ))}
            {channels.length === 0 && (
              <li className={styles.muted}>No channels.</li>
            )}
          </ul>
        </aside>

        <main className={styles.main}>
          <div className={styles.toolbar}>
            <div className={styles.filters}>
              <select
                className={styles.select}
                value={statusFilter}
                onChange={(e) =>
                  setStatusFilter(e.target.value as ForumStatus | "")
                }
              >
                <option value="">All statuses</option>
                {STATUSES.map((s) => (
                  <option key={s} value={s}>
                    {s}
                  </option>
                ))}
              </select>
              <input
                className={styles.ownerInput}
                value={ownerFilter}
                onChange={(e) => setOwnerFilter(e.target.value)}
                placeholder="Filter owner…"
              />
              <label className={styles.checkbox}>
                <input
                  type="checkbox"
                  checked={includeArchived}
                  onChange={(e) => setIncludeArchived(e.target.checked)}
                />
                Include archived
              </label>
            </div>
            <button
              className={styles.createBtn}
              onClick={() => setShowComposer((v) => !v)}
              disabled={!slug}
            >
              {showComposer ? "Cancel" : "New post"}
            </button>
          </div>

          {error && <p className={styles.error}>{error}</p>}

          {showComposer && slug && (
            <Composer
              self={self}
              channel={slug}
              onDone={() => {
                setShowComposer(false);
                loadBoard();
              }}
              onError={() => setError("Failed to create post")}
            />
          )}

          {boardLoading ? (
            <p className={styles.muted}>Loading…</p>
          ) : posts.length === 0 ? (
            <p className={styles.muted}>No posts on this board.</p>
          ) : (
            <ul className={styles.board}>
              {posts.map((p) => (
                <li key={p.id} className={styles.boardItem}>
                  <BoardRow
                    post={p}
                    expanded={expandedId === p.id}
                    onToggle={() => toggleThread(p.id)}
                    onMutate={runMutation}
                  />
                  {expandedId === p.id && (
                    <Thread
                      self={self}
                      root={root}
                      posts={threadPosts}
                      loading={threadLoading}
                      onMutate={runMutation}
                      onReplied={() => loadThread(p.id)}
                      onError={() => setError("Reply failed")}
                    />
                  )}
                </li>
              ))}
            </ul>
          )}
        </main>
      </div>
    </div>
  );
}

function StatusBadge({ status }: { status: ForumStatus }) {
  const cls =
    status === "active"
      ? styles.badgeActive
      : status === "done"
        ? styles.badgeDone
        : styles.badgeIncoming;
  return <span className={`${styles.badge} ${cls}`}>{status}</span>;
}

type MutateFn = (fn: () => Promise<unknown>) => Promise<void>;

interface RowLike {
  id: number;
  status: ForumStatus;
  pinned: boolean;
  archived: boolean;
  owner: string | null;
}

function PostActions({
  post,
  onMutate,
}: {
  post: RowLike;
  onMutate: MutateFn;
}) {
  return (
    <div className={styles.actions}>
      <select
        className={styles.miniSelect}
        value={post.status}
        title="Set status"
        onChange={(e) =>
          onMutate(() =>
            forum.setStatus(post.id, e.target.value as ForumStatus)
          )
        }
      >
        {STATUSES.map((s) => (
          <option key={s} value={s}>
            {s}
          </option>
        ))}
      </select>
      <button
        className={styles.actionBtn}
        onClick={() => {
          const owner = window.prompt("Assign owner (blank to clear):", post.owner ?? "");
          if (owner === null) return;
          onMutate(() => forum.assignOwner(post.id, owner.trim() || null));
        }}
      >
        Assign
      </button>
      <button
        className={styles.actionBtn}
        onClick={() =>
          onMutate(() =>
            post.pinned ? forum.unpinPost(post.id) : forum.pinPost(post.id)
          )
        }
      >
        {post.pinned ? "Unpin" : "Pin"}
      </button>
      <button
        className={styles.actionBtn}
        onClick={() =>
          onMutate(() =>
            post.archived
              ? forum.unarchivePost(post.id)
              : forum.archivePost(post.id)
          )
        }
      >
        {post.archived ? "Unarchive" : "Archive"}
      </button>
      <button
        className={styles.actionBtn}
        onClick={() => onMutate(() => forum.resolvePost(post.id))}
      >
        Resolve
      </button>
      <button
        className={`${styles.actionBtn} ${styles.danger}`}
        onClick={() => {
          if (window.confirm("Delete this post (and its thread if top-level)?"))
            onMutate(() => forum.deletePost(post.id));
        }}
      >
        Delete
      </button>
    </div>
  );
}

function BoardRow({
  post,
  expanded,
  onToggle,
  onMutate,
}: {
  post: ForumCompactPost;
  expanded: boolean;
  onToggle: () => void;
  onMutate: MutateFn;
}) {
  return (
    <div className={styles.row}>
      <button className={styles.rowMain} onClick={onToggle}>
        <span className={styles.caret}>{expanded ? "▾" : "▸"}</span>
        {post.pinned && (
          <span className={styles.pin} title="Pinned">
            📌
          </span>
        )}
        <span className={styles.rowTitle}>
          {post.title || "(untitled)"}
          {post.archived && <span className={styles.archivedTag}> archived</span>}
        </span>
        <StatusBadge status={post.status} />
        {post.owner && <span className={styles.owner}>@{post.owner}</span>}
        <span className={styles.replyCount}>
          {post.reply_count} {post.reply_count === 1 ? "reply" : "replies"}
        </span>
        <span className={styles.author}>{post.author}</span>
      </button>
      <PostActions post={post} onMutate={onMutate} />
    </div>
  );
}

function Thread({
  self,
  root,
  posts,
  loading,
  onMutate,
  onReplied,
  onError,
}: {
  self: string;
  root: ForumPost | null;
  posts: ForumPost[];
  loading: boolean;
  onMutate: MutateFn;
  onReplied: () => void;
  onError: () => void;
}) {
  if (loading) return <p className={styles.muted}>Loading thread…</p>;
  if (!root) return <p className={styles.muted}>Thread unavailable.</p>;

  const replies = posts.filter((p) => p.id !== root.id);

  return (
    <div className={styles.thread}>
      <PostCard post={root} onMutate={onMutate} />
      {replies.map((r) => (
        <div key={r.id} className={styles.reply}>
          <PostCard post={r} onMutate={onMutate} />
        </div>
      ))}
      <ReplyComposer
        self={self}
        channel={root.channel}
        parentId={root.id}
        onReplied={onReplied}
        onError={onError}
      />
    </div>
  );
}

function PostCard({ post, onMutate }: { post: ForumPost; onMutate: MutateFn }) {
  const [editing, setEditing] = useState(false);
  const [title, setTitle] = useState(post.title ?? "");
  const [body, setBody] = useState(post.body);

  async function save() {
    await onMutate(() =>
      forum.editPost(post.id, { title: title.trim() || undefined, body })
    );
    setEditing(false);
  }

  return (
    <div className={styles.card}>
      <div className={styles.cardHead}>
        <span className={styles.cardAuthor}>{post.author}</span>
        {post.title && <span className={styles.cardTitle}>{post.title}</span>}
        <StatusBadge status={post.status} />
        {post.owner && <span className={styles.owner}>@{post.owner}</span>}
        {post.pinned && <span className={styles.pin}>📌</span>}
        {post.archived && <span className={styles.archivedTag}>archived</span>}
        <span className={styles.cardTime}>
          {new Date(post.inserted_at).toLocaleString()}
        </span>
      </div>

      {editing ? (
        <div className={styles.editForm}>
          <input
            className={styles.ownerInput}
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            placeholder="Title (optional)"
          />
          <textarea
            className={styles.textarea}
            value={body}
            onChange={(e) => setBody(e.target.value)}
            rows={4}
          />
          <div className={styles.editActions}>
            <button className={styles.createBtn} onClick={save}>
              Save
            </button>
            <button
              className={styles.actionBtn}
              onClick={() => {
                setEditing(false);
                setTitle(post.title ?? "");
                setBody(post.body);
              }}
            >
              Cancel
            </button>
          </div>
        </div>
      ) : (
        <p className={styles.cardBody}>{post.body}</p>
      )}

      <div className={styles.cardFooter}>
        <button
          className={styles.actionBtn}
          onClick={() => setEditing((v) => !v)}
        >
          {editing ? "Editing…" : "Edit"}
        </button>
        <PostActions post={post} onMutate={onMutate} />
      </div>
    </div>
  );
}

function Composer({
  self,
  channel,
  onDone,
  onError,
}: {
  self: string;
  channel: string;
  onDone: () => void;
  onError: () => void;
}) {
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [status, setStatus] = useState<ForumStatus | "">("");
  const [owner, setOwner] = useState("");
  const [busy, setBusy] = useState(false);

  async function submit() {
    if (!body.trim() || !self.trim()) {
      onError();
      return;
    }
    setBusy(true);
    try {
      await forum.createPost({
        self: self.trim(),
        channel,
        body: body.trim(),
        title: title.trim() || undefined,
        status: status || undefined,
        owner: owner.trim() || undefined,
      });
      onDone();
    } catch {
      onError();
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className={styles.composer}>
      <input
        className={styles.ownerInput}
        value={title}
        onChange={(e) => setTitle(e.target.value)}
        placeholder="Title (optional)"
      />
      <textarea
        className={styles.textarea}
        value={body}
        onChange={(e) => setBody(e.target.value)}
        placeholder="Write a new post…"
        rows={4}
      />
      <div className={styles.composerRow}>
        <select
          className={styles.select}
          value={status}
          onChange={(e) => setStatus(e.target.value as ForumStatus | "")}
        >
          <option value="">status (default)</option>
          {STATUSES.map((s) => (
            <option key={s} value={s}>
              {s}
            </option>
          ))}
        </select>
        <input
          className={styles.ownerInput}
          value={owner}
          onChange={(e) => setOwner(e.target.value)}
          placeholder="Owner (optional)"
        />
        <button className={styles.createBtn} onClick={submit} disabled={busy}>
          {busy ? "Posting…" : "Post"}
        </button>
      </div>
    </div>
  );
}

function ReplyComposer({
  self,
  channel,
  parentId,
  onReplied,
  onError,
}: {
  self: string;
  channel: string;
  parentId: number;
  onReplied: () => void;
  onError: () => void;
}) {
  const [body, setBody] = useState("");
  const [busy, setBusy] = useState(false);

  async function submit() {
    if (!body.trim() || !self.trim()) {
      onError();
      return;
    }
    setBusy(true);
    try {
      await forum.createPost({
        self: self.trim(),
        channel,
        body: body.trim(),
        parent_id: parentId,
      });
      setBody("");
      onReplied();
    } catch {
      onError();
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className={styles.replyComposer}>
      <textarea
        className={styles.textarea}
        value={body}
        onChange={(e) => setBody(e.target.value)}
        placeholder="Reply…"
        rows={2}
      />
      <button className={styles.createBtn} onClick={submit} disabled={busy}>
        {busy ? "Sending…" : "Reply"}
      </button>
    </div>
  );
}
