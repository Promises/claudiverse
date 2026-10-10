import { useState } from "react";
import styles from "./QuestionCard.module.css";

/**
 * AskUserQuestion, rendered as the picker it is rather than as raw JSON.
 *
 * ⭐ NO NEW PLUMBING, SAME AS THE MODEL SWITCHER. Answering is just a message
 * on the path that already exists: the harness resolves the pending tool with
 * whatever free text arrives, wrapping it as `The user responded: <text>`.
 * Verified on the wire 2026-09-16 — tool_use toolu_015MyPLKz5DSrqEHAxdA3JGc in
 * session 196148 was answered by a plain cv_send message, and the matching
 * tool_result carries that text. The answer does NOT have to equal an option
 * label; that one was prose with a follow-up instruction block appended.
 *
 * So this control is a convenience over typing, not a new capability, and it
 * must not pretend otherwise: the composer below stays the way to say anything
 * the options do not cover.
 */

interface Option {
  label?: string;
  description?: string;
}

interface Question {
  header?: string;
  question?: string;
  options?: Option[];
  multiSelect?: boolean;
}

interface Props {
  questions: Question[];
  /**
   * ⛔ THE GUARD THAT MATTERS. A transcript is mostly HISTORY, and every
   * AskUserQuestion ever asked is still rendered in it. Live buttons on an
   * answered question would fire a stray message into a session that has long
   * since moved on — the worst failure this component could have, because it
   * looks like the operator typed it.
   */
  answered: boolean;
  disabled: boolean;
  onRespond: (text: string) => void;
}

/**
 * One line per question, `header: label`, or just the label when there is only
 * one question and nothing to disambiguate. Multi-select joins with ", ".
 *
 * Plain prose on purpose — this goes to a model that reads it, not to a parser.
 */
function compose(questions: Question[], picked: Record<number, string[]>): string {
  const parts = questions
    .map((q, i) => {
      const chosen = picked[i];
      if (!chosen?.length) return null;
      const answer = chosen.join(", ");
      return questions.length > 1 && q.header ? `${q.header}: ${answer}` : answer;
    })
    .filter(Boolean);

  return parts.join("\n");
}

export default function QuestionCard({
  questions,
  answered,
  disabled,
  onRespond,
}: Props) {
  const [picked, setPicked] = useState<Record<number, string[]>>({});
  const [sent, setSent] = useState(false);

  const toggle = (qi: number, label: string, multi: boolean) => {
    setPicked((prev) => {
      const current = prev[qi] ?? [];
      if (!multi) return { ...prev, [qi]: [label] };
      return {
        ...prev,
        [qi]: current.includes(label)
          ? current.filter((l) => l !== label)
          : [...current, label],
      };
    });
  };

  const text = compose(questions, picked);
  // Every question needs an answer before this is a complete response — sending
  // a partial one resolves the tool and loses the rest.
  const complete = questions.every((_, i) => (picked[i] ?? []).length > 0);

  return (
    <div className={styles.card}>
      {questions.map((q, qi) => (
        <div key={qi} className={styles.question}>
          {q.header && <div className={styles.header}>{q.header}</div>}
          {q.question && <p className={styles.prompt}>{q.question}</p>}

          <ul className={styles.options}>
            {(q.options ?? []).map((opt, oi) => {
              const label = opt.label ?? `Option ${oi + 1}`;
              const isPicked = (picked[qi] ?? []).includes(label);
              return (
                <li key={oi}>
                  <button
                    type="button"
                    className={`${styles.option} ${isPicked ? styles.picked : ""}`}
                    // An answered question keeps its options VISIBLE — they are
                    // what was on offer, and hiding them makes the transcript
                    // lie about the decision — but never clickable.
                    disabled={answered || sent || disabled}
                    onClick={() => toggle(qi, label, q.multiSelect === true)}
                  >
                    <span className={styles.optionLabel}>{label}</span>
                    {opt.description && (
                      <span className={styles.optionDescription}>{opt.description}</span>
                    )}
                  </button>
                </li>
              );
            })}
          </ul>
        </div>
      ))}

      {answered ? (
        <div className={styles.note}>Answered</div>
      ) : sent ? (
        <div className={styles.note}>Sent — waiting for the seat to pick it up</div>
      ) : (
        <div className={styles.actions}>
          <button
            type="button"
            className={styles.send}
            disabled={!complete || disabled}
            onClick={() => {
              onRespond(text);
              setSent(true);
            }}
          >
            Send answer
          </button>
          <span className={styles.hint}>
            or type anything in the box below — the options are a shortcut, not a
            restriction
          </span>
        </div>
      )}
    </div>
  );
}
