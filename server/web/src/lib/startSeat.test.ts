import { describe, expect, test } from "vitest";
import type { Host } from "../api/hosts";
import { defaultTitle, folderChoices, formProblem, modesFor, spawnRequest, type StartSeatForm } from "./startSeat";
import { relativeTime } from "./relativeTime";

const host = (spawn: Host["spawn"], modes: string[] = []): Host => ({
  name: "box", online: true, seats: 0, roots: ["/home/me/projects"], version: "0.13.0", modes, spawn, last_seen_at: null,
});
const form: StartSeatForm = { path: "/home/me/projects/app", title: "app", mode: "auto", model: "haiku", pooled: true };

describe("spawnRequest", () => {
  test("asks for a model and pooling where the machine's agent offers them", () => {
    expect(spawnRequest(form, host({ options: ["model", "pooled"], pool_only: false, pooled: false })))
      .toEqual({ path: "/home/me/projects/app", title: "app", mode: "auto", model: "haiku", pooled: true });
  });

  test("asks neither of an older agent: the server would refuse them", () => {
    expect(spawnRequest(form, host(null))).toEqual({ path: "/home/me/projects/app", title: "app", mode: "auto" });
  });

  test("asks nothing about pooling of a pool-only machine; its seats always use the pool", () => {
    expect(spawnRequest(form, host({ options: ["model", "pooled"], pool_only: true, pooled: true }))).not.toHaveProperty("pooled");
  });

  test("leaves the model to the machine when none is chosen", () => {
    expect(spawnRequest({ ...form, model: "" }, host({ options: ["model", "pooled"], pool_only: false, pooled: false })))
      .not.toHaveProperty("model");
  });
});

describe("the form's other rules", () => {
  test("a default name is the folder's, made safe as the host agent makes it", () => {
    expect(defaultTitle("/home/me/projects/my app (2)")).toBe("my-app-2");
    expect(defaultTitle("/home/me/projects/")).toBe("projects");
    expect(defaultTitle("/")).toBe("seat");
  });

  test("folders are each root, then its subfolders", () => {
    expect(folderChoices(["/a", "/b/"], { "/a": ["x", "y"], "/b/": ["z"] })).toEqual(["/a", "/a/x", "/a/y", "/b/", "/b/z"]);
  });

  test("modes are the machine's, in the form's order; all four from an older agent", () => {
    expect(modesFor(host(null, ["plan", "auto"])).map((m) => m.id)).toEqual(["auto", "plan"]);
    expect(modesFor(host(null)).map((m) => m.id)).toEqual(["auto", "default", "acceptEdits", "plan"]);
  });

  test("a form without a folder or with a bad name says what to fix", () => {
    expect(formProblem(form)).toBeNull();
    expect(formProblem({ ...form, path: "" })).toBe("Choose a folder.");
    expect(formProblem({ ...form, title: "my seat" })).toMatch(/letters, digits/);
  });

  test("a time with or without its zone is read as the server's UTC", () => {
    const now = Date.parse("2026-10-12T12:00:00Z");
    expect(relativeTime("2026-10-12T09:00:00Z", now)).toBe("3h ago");
    expect(relativeTime("2026-10-12T09:00:00", now)).toBe("3h ago");
    expect(relativeTime("2026-10-12T11:59:50Z", now)).toBe("just now");
  });
});
