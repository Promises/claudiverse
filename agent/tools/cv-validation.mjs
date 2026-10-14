// Which finished tasks get an auto-minted validation. Split out of cv-runner so
// it can be tested without starting a runner.

export const VALIDATION_PREFIX = "VALIDATE #";
// Opt-out marker a minting seat puts in a task BODY when the task produces
// nothing a second seat could re-derive (a no-commit analysis row, a gate run).
export const NO_AUTO_VALIDATE = "NO-AUTO-VALIDATE";

// A validation task, for model/effort selection: the row says so, or its title does.
export const isValidationTask = (t) => Boolean(t.validatesTaskId) || (t.title || "").startsWith(VALIDATION_PREFIX);

// A validator's title names the task it checks: "VALIDATE #1224", anywhere in
// the title, in capitals ("⛔ NOT lorem-w4 … — VALIDATE #1224", "CASE (b)
// VALIDATE #1197 …"). Case-sensitive and with the number: the earlier
// /\bVALIDATE\b|\bRE-CHECK\b|\bCLOSE SHORT\b/i also matched production rows
// that merely used the words — #1750 ("… re-check its tip …") finished without
// a validator (2026-10-07). A validator titled otherwise carries
// validates_task_id, which the server stores for exactly this.
const NAMES_A_VALIDATED_TASK = /\bVALIDATE #\d+/;

// A worker that did nothing says so FIRST in its outcome: "NO-OP …" or
// "DUPLICATE …" (cv_task_done asks for that). There is no work for a second
// seat to re-derive. MEASURED 2026-10-12: #31185, a duplicate dispatch whose
// seat correctly ran none of it ("NO-OP. This was a duplicate dispatch."), got
// validator #31192 all the same. Only a declaration at the start counts: an
// outcome that merely mentions the words keeps its validator.
const DECLARED_NOOP = /^[\s*_>#-]*(NO-OP|DUPLICATE)\b/i;

// Why a finished task gets NO auto-minted validation, or null if it should.
// The title-prefix check alone missed every validator the orchestrator minted
// with its own title and every post-landing gate. MEASURED on lorem-fleet window C
// (2026-09-30/10-01, tasks #1104-#1254): 89 of 151 tasks were validators,
// including validators of validators (#1134, #1137) and VALIDATE #1254 of the
// C0f gate #1253, minted against an explicit "no validator".
// RULING #8808 (O): one level of validation; gates and no-commit rows get none.
//
// `validateLane`: the lane this runner posts validations to, when set
// explicitly (--validate-channel). A task that came FROM that lane is a check,
// not a production: #1776, a gate-discharge row in lorem-analysis titled
// otherwise, got a validator of its own (#1785, 2026-10-07) that only its own
// slot could have run. Never inferred from the runner's own channel, which a
// runner with no --validate-channel also posts to: that would exempt all its
// production.
//
// `outcome`: what the worker's cv_task_done said it did (cv-reap.mjs reads it
// off the task), or null when it could not be read.
export function validationExemption(task, { validateLane = null, outcome = null } = {}) {
  if (task.validatesTaskId) return `it is itself a validation (validates_task_id=${task.validatesTaskId})`;
  if (validateLane && task.lane === validateLane) return `it came from the validation lane #${validateLane}`;
  const title = task.title || "";
  if (title.startsWith(VALIDATION_PREFIX) || NAMES_A_VALIDATED_TASK.test(title))
    return "its title marks it as a validation";
  if (/POST-LANDING GATE/i.test(title)) return "it is a post-landing gate, itself the independent check";
  if ((task.body || "").includes(NO_AUTO_VALIDATE)) return `its body carries ${NO_AUTO_VALIDATE}`;
  if (outcome && DECLARED_NOOP.test(outcome)) return `its outcome declares it a no-op ("${outcome.slice(0, 60)}")`;
  return null;
}
