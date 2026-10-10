import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import type { SDKMessage } from "../lib/types";
import QuestionCard from "./QuestionCard";
import styles from "./MessageBubble.module.css";

/**
 * Assistant text is MARKDOWN and was being shown raw — literal `**` and
 * backticks in the panel where the terminal and Claude web both render it.
 *
 * react-markdown rather than a hand-rolled formatter: it does not evaluate raw
 * HTML unless explicitly told to, so untrusted model output cannot inject
 * markup. A regex formatter is where that guarantee quietly gets lost.
 */
function Markdown({ children }: { children: string }) {
  return (
    <div className={styles.markdown}>
      <ReactMarkdown remarkPlugins={[remarkGfm]}>{children}</ReactMarkdown>
    </div>
  );
}

interface Props {
  message: SDKMessage;
  /**
   * tool_use ids that already have a tool_result somewhere in the transcript.
   * Only AskUserQuestion uses it, and only to know whether its picker is still
   * live — see QuestionCard. Computed by the page because a single message
   * cannot see the reply that came after it.
   */
  answeredToolIds?: Set<string>;
  /** Absent for a read-only view (an observer, or a disconnected seat). */
  onRespond?: (text: string) => void;
}

/**
 * The questions out of an AskUserQuestion tool_use input, or null if it is not
 * the shape we know.
 *
 * ⚠️ NULL RATHER THAN A GUESS. A malformed or newer input must fall through to
 * the raw JSON fold: showing the operator the payload is useless-but-honest,
 * whereas a half-parsed picker offers buttons that do not correspond to the
 * question being asked.
 */
function askedQuestions(input: unknown) {
  const qs = (input as { questions?: unknown })?.questions;
  if (!Array.isArray(qs) || qs.length === 0) return null;
  if (!qs.every((q) => q && typeof q === "object")) return null;
  return qs as { header?: string; question?: string; multiSelect?: boolean;
                 options?: { label?: string; description?: string }[] }[];
}

/**
 * Message types that carry NO information a reader wants.
 *
 * 🔴 stream_event IS 82% OF THE STREAM. Measured on one short session: 132 of
 * 160 messages. Each is a raw Anthropic streaming delta whose content is
 * already assembled into the `assistant` message that follows, so rendering
 * them produced ~25 lines of "[stream_event]" around a single readable reply —
 * the conversation was effectively invisible.
 *
 * The others are turn plumbing: bookkeeping the sidecar mirrors so the server
 * can track state, never anything a human reads.
 */
const SILENT_TYPES = new Set([
  "stream_event",
  "stream_request_start",
  "set_in_progress_tool_use_ids",
]);

/** Compact one-line summary of a tool's input, the way the terminal does it. */
function toolSummary(name: string, input: unknown): string {
  const i = (input ?? {}) as Record<string, unknown>;
  const first = (...keys: string[]) => {
    for (const k of keys) {
      const v = i[k];
      if (typeof v === "string" && v) return v;
    }
    return null;
  };
  // Whatever the tool's most identifying argument is — a path, a command, a
  // pattern. Falling back to the bare name is fine; inventing a summary is not.
  const detail = first("file_path", "path", "command", "pattern", "query", "url", "prompt");
  if (!detail) return name;
  const oneLine = detail.replace(/\s+/g, " ").trim();
  return `${name}  ${oneLine.length > 80 ? oneLine.slice(0, 79) + "…" : oneLine}`;
}

function resultPreview(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    const text = content
      .map((b) => (b as { text?: string })?.text ?? "")
      .filter(Boolean)
      .join("\n");
    if (text) return text;
  }
  return JSON.stringify(content ?? "", null, 2);
}

export default function MessageBubble({
  message,
  answeredToolIds,
  onRespond,
}: Props) {
  const type = message.type as string;

  if (SILENT_TYPES.has(type)) return null;

  if (type === "user") {
    const msg = message.message as { role?: string; content?: unknown };
    const content = msg?.content;

    // ⛔ A "user" MESSAGE IS USUALLY NOT THE USER. Tool results come back on the
    //    user turn as tool_result blocks, so labelling every `user` message
    //    "You" attributed the output of Claude's own tool calls to the operator.
    //    Measured: the single `user` message in a real session was a tool_result,
    //    and it rendered as the human speaking JSON.
    // Claude Code's own notes on the user turn are flagged isMeta — e.g.
    // "[Image: original 1080x2410, displayed at 896x2000…]" after it reads an
    // image. Not the operator speaking: they belong with the tool output they
    // annotate. Measured: rendered as a user bubble in the operator's app.
    if ((message as { isMeta?: boolean }).isMeta) {
      const body = resultPreview(content);
      if (!body.trim()) return null;
      return (
        <details className={styles.toolResult}>
          <summary className={styles.toolResultSummary}>
            Tool result
            <span className={styles.toolResultPeek}>{body.split("\n")[0].slice(0, 100)}</span>
          </summary>
          <pre className={styles.toolOutput}>{body}</pre>
        </details>
      );
    }

    if (Array.isArray(content)) {
      const toolResults = content.filter(
        (b) => (b as { type?: string })?.type === "tool_result"
      );

      if (toolResults.length > 0) {
        return (
          <>
            {toolResults.map((b, i) => {
              const r = b as { content?: unknown; is_error?: boolean };
              const body = resultPreview(r.content);
              const firstLine = body.split("\n")[0].slice(0, 100);
              return (
                <details
                  key={i}
                  className={`${styles.toolResult} ${r.is_error ? styles.toolError : ""}`}
                >
                  <summary className={styles.toolResultSummary}>
                    {r.is_error ? "Tool failed" : "Tool result"}
                    <span className={styles.toolResultPeek}>{firstLine}</span>
                  </summary>
                  <pre className={styles.toolOutput}>{body}</pre>
                </details>
              );
            })}
          </>
        );
      }
    }

    // A genuine typed prompt. Content is USUALLY a string, but not always: an
    // interrupt arrives as [{type:"text", text:"[Request interrupted by user]"}],
    // and JSON.stringify rendered that as a wall of quoted JSON in a user pill.
    const text =
      typeof content === "string"
        ? content
        : Array.isArray(content)
          ? content
              .map((b) => (b as { text?: string })?.text ?? "")
              .filter(Boolean)
              .join("\n")
          : JSON.stringify(content);

    // Nothing readable survived — better to show nothing than an empty pill.
    if (!text.trim()) return null;
    return (
      <div className={`${styles.bubble} ${styles.user}`}>
        <div className={styles.content}>{text}</div>
      </div>
    );
  }

  if (type === "assistant") {
    const msg = message.message as { content?: unknown[] };
    const blocks = (msg?.content as unknown[]) || [];

    // An assistant message carrying nothing renderable (an empty shell that
    // arrives before its deltas) should occupy no space at all.
    const rendered = blocks.filter((b) =>
      ["text", "thinking", "tool_use"].includes((b as { type: string })?.type)
    );
    if (rendered.length === 0) return null;

    return (
      <div className={`${styles.bubble} ${styles.assistant}`}>
        {rendered.map((b, i) => {
          const block = b as {
            type: string;
            id?: string;
            text?: string;
            thinking?: string;
            name?: string;
            input?: unknown;
          };

          if (block.type === "text") {
            return <Markdown key={i}>{block.text ?? ""}</Markdown>;
          }

          // Collapsed by default: reasoning is worth having, not worth reading
          // past on every scroll.
          if (block.type === "thinking") {
            return (
              <details key={i} className={styles.thinking}>
                <summary className={styles.thinkingSummary}>Thought</summary>
                <div className={styles.thinkingBody}>{block.thinking}</div>
              </details>
            );
          }

          // AskUserQuestion is not a tool call to read, it is a question to
          // ANSWER — folded away as JSON it was unanswerable from the panel.
          const questions =
            block.name === "AskUserQuestion" ? askedQuestions(block.input) : null;

          if (questions) {
            return (
              <QuestionCard
                key={i}
                questions={questions}
                answered={
                  // No id means we cannot tell whether it was answered, and a
                  // live button on an already-answered question is the one
                  // thing this must never do. Unknown counts as answered.
                  !block.id || !answeredToolIds || answeredToolIds.has(block.id)
                }
                disabled={!onRespond}
                onRespond={onRespond ?? (() => {})}
              />
            );
          }

          return (
            <details key={i} className={styles.toolUse}>
              <summary className={styles.toolName}>
                {toolSummary(block.name ?? "tool", block.input)}
              </summary>
              <pre className={styles.toolInput}>
                {JSON.stringify(block.input, null, 2)}
              </pre>
            </details>
          );
        })}
      </div>
    );
  }

  /*
   * Harness-injected context. NOT one shape — each carries its own inner type,
   * and labelling them all "Context attached" produced a stack of identical
   * unlabelled rows saying nothing. Measured on one session: files, context,
   * date, systemPrompt, systemPrompt+tools, an MCP tool-change list, and a
   * token-budget reminder — seven rows, one label.
   */
  if (type === "attachment") {
    const att =
      ((message as unknown as { attachment?: Record<string, unknown> }).attachment) || {};
    const kind = String(att.type ?? "context");

    // Pure plumbing with nothing to read. Dropped rather than folded: a
    // collapsed row still costs a line, and "the date is 2026-09-14" never
    // repays one.
    if (kind === "date" || kind === "total_tokens_reminder") return null;

    const files = (att.files as { path?: string }[] | undefined) || [];
    // Kind names as they actually appear on the wire — taken from a live
    // session, not from the SDK's type names, which differ.
    const KIND_LABELS: Record<string, string> = {
      session_context: "Environment context",
      context: "Environment context",
      prompt_snapshot: "System prompt",
      systemPrompt: "System prompt",
      deferred_tools_delta: "Tool availability changed",
      mcp_servers: "MCP servers",
      instructions: "Instructions",
      remote_session_change: "Remote control session changed",
    };

    const label =
      files.length > 0
        ? `Context: ${files.map((f) => f.path?.split("/").pop() || "file").join(", ")}`
        : (KIND_LABELS[kind] ?? kind);

    return (
      <details className={styles.attachment}>
        <summary className={styles.attachmentSummary}>{label}</summary>
        <pre className={styles.toolOutput}>{JSON.stringify(att, null, 2)}</pre>
      </details>
    );
  }

  if (type === "result") {
    const subtype = message.subtype as string;
    return (
      <div className={`${styles.bubble} ${styles.result}`}>
        <div className={styles.role}>
          {subtype === "success" ? "Done" : "Error"}
        </div>
        {message.result != null && <Markdown>{String(message.result)}</Markdown>}
      </div>
    );
  }

  // A turn boundary, as a thin rule rather than a word floating mid-column.
  //
  // ⛔ turn_complete ONLY. `idle` is a repeating state flag, not an event — both
  //    fired for the same boundary and drew two rules in a row, so the divider
  //    stopped reading as punctuation and started reading as a gap.
  if (type === "turn_complete") return <hr className={styles.turnBreak} />;
  if (type === "idle") return null;

  // State the claudiverse-seat mod keeps current for the apps' side panels (a
  // seat's agents and background tasks), not lines of the conversation. This
  // panel has no such side panel, so they are not drawn here.
  if (type === "agents" || type === "agent_ended" || type === "background_tasks") return null;

  // A permission prompt: the dialog under the conversation shows it while it
  // waits, so its row in the conversation is not drawn.
  if (type === "control_request") return null;

  // The terminal prints this as an italic "recap:" line. It carries a `value`
  // that is usually null — an empty summary is not worth a row.
  if (type === "post_turn_summary") {
    const value = (message as unknown as { value?: unknown }).value;
    if (value == null || value === "") return null;
    // Labelled, as the terminal does. Unlabelled italic text mid-transcript
    // reads as something Claude said rather than a summary of what it did.
    return (
      <div className={styles.recap}>
        <span className={styles.recapLabel}>recap</span>
        {String(value)}
      </div>
    );
  }

  if (type === "system" || type === "status") {
    return (
      <div className={styles.statusLine}>
        {type}: {JSON.stringify(message)}
      </div>
    );
  }

  // An unrecognised type is still SHOWN — quietly, and named. Silently dropping
  // it would hide a new message type behind an empty screen, which is how the
  // stream_event problem stayed invisible.
  return <div className={styles.statusLine}>[{type}]</div>;
}
