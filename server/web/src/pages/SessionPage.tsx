import { useState, useEffect, useRef, useMemo } from "react";
import { useParams, useNavigate, Link } from "react-router-dom";
import { useAuth } from "../contexts/AuthContext";
import { useSession } from "../hooks/useSession";
import { useDocumentTitle } from "../hooks/useDocumentTitle";
import { getSession } from "../api/sessions";
import type { Session } from "../lib/types";
import { modelChoice, modelLabel } from "../lib/models";
import { useModels } from "../hooks/useModels";
import MessageBubble from "../components/MessageBubble";
import PermissionDialog from "../components/PermissionDialog";
import styles from "./SessionPage.module.css";

export default function SessionPage() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const { token } = useAuth();
  const [session, setSession] = useState<Session | null>(null);
  const [input, setInput] = useState("");
  const messagesEndRef = useRef<HTMLDivElement>(null);

  const sessionId = Number(id);
  useDocumentTitle(session?.title);

  useEffect(() => {
    if (!id) return;
    getSession(sessionId)
      .then((res) => setSession(res.session))
      .catch(() => navigate("/"));
  }, [id, sessionId, navigate]);

  const {
    messages,
    permissionRequests,
    connected,
    sendMessage,
    respondToPermission,
    interrupt,
  } = useSession({
    sessionId,
    token: token!,
  });

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  // The model of the seat's latest reply is the one it runs now. The session
  // row is read once, when the page opens, and may predate the seat's first
  // turn (a Haiku seat showed "Sonnet" until a reload).
  const models = useModels();
  const runningModel = useMemo(() => {
    for (let i = messages.length - 1; i >= 0; i--) {
      const m = messages[i] as { type?: string; message?: { model?: string } };
      if (m.type === "assistant" && m.message?.model) return m.message.model;
    }
    return session?.model ?? null;
  }, [messages, session]);

  /*
   * Which tool calls already have a result.
   *
   * Only AskUserQuestion needs it, and only so its picker knows whether it is
   * still live. A transcript is mostly history: every question ever asked is
   * still rendered, and clickable buttons on a settled one would fire a stray
   * message into a session that moved on hours ago — indistinguishable, from
   * the seat's side, from the operator typing it.
   *
   * Computed here rather than in the bubble because a message cannot see the
   * reply that came after it.
   */
  const answeredToolIds = useMemo(() => {
    const ids = new Set<string>();
    for (const m of messages) {
      const content = (m as { message?: { content?: unknown } })?.message?.content;
      if (!Array.isArray(content)) continue;
      for (const block of content) {
        const b = block as { type?: string; tool_use_id?: string };
        if (b?.type === "tool_result" && b.tool_use_id) ids.add(b.tool_use_id);
      }
    }
    return ids;
  }, [messages]);

  function handleSend(e: React.FormEvent) {
    e.preventDefault();
    if (!input.trim()) return;
    sendMessage(input.trim());
    setInput("");
  }

  if (!session) return null;

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <Link to="/" className={styles.backBtn}>&larr; Back</Link>
        <div className={styles.sessionInfo}>
          <h2 className={styles.title}>{session.title}</h2>
          {/*
            The name Claude Code's own picker shows, matching the dashboard row.
            Only when it differs, so the header never says the same thing twice.
          */}
          {session.display_title && session.display_title !== session.title && (
            <span className={styles.displayTitle}>{session.display_title}</span>
          )}
          <span className={styles.meta}>
            {/*
              Where the seat runs, in words a person uses. It used to show
              session.type ("sidecar"), which is how the server tracks the
              row, not something a newcomer can read. The model is in the
              Model menu below.
            */}
            {[session.host && `on ${session.host}`, session.working_directory].filter(Boolean).join(" · ")}
          </span>
        </div>
        <div className={styles.status}>
          <span
            className={`${styles.dot} ${connected ? styles.dotConnected : styles.dotDisconnected}`}
          />
          {connected ? "Connected" : "Disconnected"}
        </div>
      </header>

      <main className={styles.messages}>
        {messages.length === 0 && (
          <div className={styles.empty}>
            <p>Waiting for messages...</p>
            <p className={styles.hint}>
              Connect Claude with: <code>claude --claudiverse-server ws://localhost:4000</code>
            </p>
          </div>
        )}

        {messages.map((msg, i) => (
          <MessageBubble
            key={i}
            message={msg}
            answeredToolIds={answeredToolIds}
            // Nothing can be answered while the channel is down, and an
            // enabled button that silently drops the push is worse than a
            // disabled one.
            onRespond={connected ? sendMessage : undefined}
          />
        ))}

        {permissionRequests.map((req) => (
          <PermissionDialog
            key={req.request_id}
            request={req}
            onRespond={respondToPermission}
          />
        ))}

        <div ref={messagesEndRef} />
      </main>

      <footer className={styles.footer}>
        <form onSubmit={handleSend} className={styles.inputRow}>
          <input
            type="text"
            value={input}
            onChange={(e) => setInput(e.target.value)}
            placeholder="Send a message to Claude..."
            className={styles.input}
            disabled={!connected}
          />
          <button
            type="button"
            onClick={interrupt}
            className={styles.interruptBtn}
            disabled={!connected}
            title="Interrupt"
          >
            Stop
          </button>
          <button
            type="submit"
            className={styles.sendBtn}
            disabled={!connected || !input.trim()}
          >
            Send
          </button>
        </form>

        {/*
          Model switcher. `/model <name>` is a real slash command, so this is
          just a message on the path that already exists — no new plumbing.

          ⚠️ THE SEAT IS THE SOURCE OF TRUTH, NOT THIS CONTROL. It reflects
          the model of the seat's latest reply (runningModel). So the value
          shown is what is RUNNING, not what was last clicked — if a /model
          typed in the terminal changes it, this follows within a turn rather
          than disagreeing silently.
        */}
        <div className={styles.controls}>
          <label className={styles.controlLabel} htmlFor="model-select">
            Model
          </label>
          <select
            id="model-select"
            className={styles.select}
            value={modelChoice(runningModel, models)}
            disabled={!connected}
            onChange={(e) => {
              const id = e.target.value;
              if (id) sendMessage(`/model ${id}`);
            }}
          >
            {/* An unrecognised model still shows, rather than silently
                snapping the control to something the seat is not running. */}
            {/* An id we cannot map is SHOWN, not hidden — the control must not
                claim a model the seat is not running. */}
            {!modelChoice(runningModel, models) && (
              <option value="">{runningModel || "Unknown until it replies"}</option>
            )}
            <optgroup label="Models">
              {models.models.filter((m) => !m.older).map((m) => (
                <option key={m.id} value={m.id}>
                  {modelLabel(m)}
                </option>
              ))}
            </optgroup>
            <optgroup label="Earlier models">
              {models.models.filter((m) => m.older).map((m) => (
                <option key={m.id} value={m.id}>
                  {modelLabel(m)}
                </option>
              ))}
            </optgroup>
            <optgroup label="Aliases">
              {models.aliases.map((m) => (
                <option key={m.id} value={m.id}>
                  {m.label}
                </option>
              ))}
            </optgroup>
          </select>
        </div>
      </footer>
    </div>
  );
}
