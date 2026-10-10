// Which of cv-mcp's tool groups a seat may use, by the role the server (or a
// static CLAUDIVERSE_ROLE) gives it and whether it may page the operator.
//   report  the worker-side reporting tools (workers and delegates)
//   notify  cv_request_human: whoever MAY page, whatever its role, so a basic
//           seat granted "notify" from the apps gets it (Sessions.Access).
//           Runner workers never have it (the server refuses them anyway).
//   full    the orchestrator tool set (everything but a worker)
//   (other) the shared tools: always
export function allowedGroup(group, role, canNotify) {
  if (group === "report") return role === "worker" || role === "delegate";
  if (group === "notify") return canNotify === true;
  if (group === "full") return role !== "worker";
  return true;
}
