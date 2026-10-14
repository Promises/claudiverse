import type { ModelList } from "../lib/models";

const API_BASE = import.meta.env.VITE_API_URL || "http://localhost:4000";

/** GET /api/models: the models a seat can run, as the server lists them. */
export async function getModels(): Promise<ModelList> {
  const token = localStorage.getItem("token");
  const res = await fetch(`${API_BASE}/api/models`, { headers: token ? { Authorization: `Bearer ${token}` } : {} });
  if (!res.ok) throw new Error(`API error ${res.status}`);
  const body = await res.json();
  if (!Array.isArray(body?.models) || !Array.isArray(body?.aliases)) throw new Error("not a model list");
  return { models: body.models, aliases: body.aliases };
}
