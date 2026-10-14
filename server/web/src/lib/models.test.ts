import { describe, expect, test } from "vitest";
import { BUILT_IN, knownTo, modelChoice, modelLabel } from "./models";

describe("modelChoice", () => {
  test("Opus 5.5 is Opus 5.5, not Opus 5: exact, never a prefix", () => {
    // claude-opus-5 is a prefix of claude-opus-5-5; picking "Opus 5" for a 5.5
    // seat would send /model claude-opus-5 and downgrade it.
    expect(modelChoice("claude-opus-5-5")).toBe("claude-opus-5-5");
    expect(modelChoice("claude-opus-5")).toBe("claude-opus-5");
    expect(modelChoice("claude-sonnet-5-5")).toBe("claude-sonnet-5-5");
    expect(modelChoice("claude-fable-5-1")).toBe("claude-fable-5-1");
  });

  test("a row's [1m] spelling and an older model's dated id resolve too", () => {
    expect(modelChoice("claude-opus-5-5[1m]")).toBe("claude-opus-5-5");
    expect(modelChoice("CLAUDE-OPUS-5[1M]")).toBe("claude-opus-5");
    expect(modelChoice("claude-haiku-4-5-20251001")).toBe("claude-haiku-4-5");
    expect(modelChoice("haiku")).toBe("haiku");
  });

  test("a model not on the list is not snapped to a neighbour", () => {
    expect(modelChoice("claude-opus-5-6")).toBe("");
    expect(modelChoice("claude-opus-5-5-preview")).toBe("");
    expect(modelChoice(null)).toBe("");
  });
});

test("the 5.5 models are offered, by the ids Claude Code takes, 1M shown where the bare id is", () => {
  const ids = BUILT_IN.models.map((m) => m.id);
  for (const id of ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]) expect(ids).toContain(id);
  expect(ids.filter((id) => id.includes("[") || id.includes("."))).toEqual([]);
  expect(BUILT_IN.models.filter((m) => !m.older).map(modelLabel)).toContain("Haiku 5.5 (1M)");
  expect(modelLabel(BUILT_IN.models.find((m) => m.id === "claude-haiku-4-5")!)).toBe("Haiku 4.5");
});

// Read through Vite rather than imported: the web's own build (its Docker
// context is server/web/ alone) never sees the server's folder. Two layouts, one
// match: here the server is ../../../server/api; in the public repo
// the web is server/web and the server server/api (../../../api).
const SERVER_LIST = import.meta.glob(["../../../server/api/priv/models.json", "../../../api/priv/models.json"],
  { eager: true, import: "default" });

test("the built-in list is the server's (server/api/priv/models.json): they cannot drift", () => {
  const lists = Object.values(SERVER_LIST) as { models: unknown; aliases: unknown }[];
  expect(lists).toHaveLength(1);
  expect(BUILT_IN).toEqual({ models: lists[0].models, aliases: lists[0].aliases });
});

test("knownTo: a model with a since is offered only from that Claude Code version", () => {
  const haiku55 = BUILT_IN.models.find((m) => m.id === "claude-haiku-5-5")!;
  expect(knownTo(haiku55, "2.1.292")).toBe(false);
  expect(knownTo(haiku55, "2.1.293")).toBe(true);
  expect(knownTo(haiku55, "2.1.296 (Claude Code)")).toBe(true);
  expect(knownTo(haiku55, "2.2.0")).toBe(true);
  expect(knownTo(haiku55, null)).toBe(true);
  expect(knownTo(BUILT_IN.models[0], "2.1.200")).toBe(true);
});
