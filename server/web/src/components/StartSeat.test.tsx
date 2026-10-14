import { afterEach, describe, expect, test, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import type { Host } from "../api/hosts";
import StartSeat from "./StartSeat";
import Machines from "./Machines";

// The sign-in's scope: "app" unless a test makes it an older one.
const auth = vi.hoisted(() => ({ scope: "app" as string | null, logout: vi.fn() }));
vi.mock("../contexts/AuthContext", () => ({ useAuth: () => auth }));
vi.mock("../api/hosts", () => ({
  listFolders: vi.fn(async (_host: string, path: string) => ({ path, parent: "", dirs: ["app", "site"], truncated: false })),
  spawnSeat: vi.fn(async () => ({ spawn_id: "sp-1" })),
}));
const api = await import("../api/hosts");
// The server's model list: offline unless a test gives one (the built-in list then).
vi.mock("../api/models", () => ({ getModels: vi.fn(async () => { throw new Error("offline"); }) }));
const modelsApi = await import("../api/models");

const machine = (name: string, extra: Partial<Host> = {}): Host => ({
  name, online: true, seats: 0, roots: ["/home/me/projects"], version: "0.13.0", modes: [],
  spawn: { options: ["model", "pooled"], pool_only: false, pooled: false }, last_seen_at: null, ...extra,
});
const hosts = [
  machine("box"),
  machine("old", { version: "0.12.0", spawn: null }),
  machine("gone", { online: false, roots: [], spawn: null, last_seen_at: "2026-10-12T08:00:00Z" }),
];

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
  auth.scope = "app";
});

describe("Start a seat", () => {
  test("offers the online machines, and a folder from each root with its subfolders", async () => {
    render(<StartSeat hosts={hosts} onClose={() => {}} onStarted={() => {}} />);
    const machines = [...(screen.getByLabelText("Machine") as HTMLSelectElement).options].map((o) => o.value);
    expect(machines).toEqual(["box", "old"]);
    await waitFor(() => expect(screen.getByRole("option", { name: "/home/me/projects/site" })).toBeTruthy());
    expect((screen.getByLabelText("Name") as HTMLInputElement).value).toBe("projects");
  });

  test("starts the chosen folder in auto on the pool by default, with the model chosen", async () => {
    const onStarted = vi.fn();
    render(<StartSeat hosts={hosts} onClose={() => {}} onStarted={onStarted} />);
    await screen.findByRole("option", { name: "/home/me/projects/app" });
    fireEvent.change(screen.getByLabelText("Folder"), { target: { value: "/home/me/projects/app" } });
    fireEvent.change(screen.getByLabelText("Model"), { target: { value: "haiku" } });
    expect((screen.getByLabelText("Use the server's account pool") as HTMLInputElement).checked).toBe(true);
    fireEvent.click(screen.getByRole("button", { name: "Start the seat" }));

    await waitFor(() => expect(onStarted).toHaveBeenCalledWith({ spawnId: "sp-1", host: "box", title: "app" }));
    expect(api.spawnSeat).toHaveBeenCalledWith("box",
      { path: "/home/me/projects/app", title: "app", mode: "auto", model: "haiku", pooled: true });
  });

  test("the models are the server's list: a model it adds is offered by its exact id", async () => {
    vi.mocked(modelsApi.getModels).mockResolvedValueOnce({
      models: [{ id: "claude-lorem-6", label: "Lorem 6", family: "lorem", one_m: true, accepts_1m_suffix: false, since: null, older: false }],
      aliases: [{ id: "opus", label: "Opus (latest)" }],
    });
    render(<StartSeat hosts={hosts} onClose={() => {}} onStarted={() => {}} />);
    await screen.findByRole("option", { name: "Lorem 6 (1M)" });
    const ids = [...(screen.getByLabelText("Model") as HTMLSelectElement).options].map((o) => o.value);
    expect(ids).toEqual(["", "claude-lorem-6", "opus"]);
  });

  test("a model the machine's Claude Code does not know yet is not offered (Haiku 5.5 came in 2.1.293)", () => {
    const at = (version: string) => {
      cleanup();
      render(<StartSeat hosts={[machine("box", { spawn: { options: ["model"], pool_only: false, pooled: false, version } })]}
        onClose={() => {}} onStarted={() => {}} />);
      return [...(screen.getByLabelText("Model") as HTMLSelectElement).options].map((o) => o.value);
    };
    expect(at("2.1.292")).not.toContain("claude-haiku-5-5");
    expect(at("2.1.296")).toContain("claude-haiku-5-5");
  });

  test("a sign-in that cannot start seats is told to sign in again, not shown the server's refusal", async () => {
    auth.scope = "api";
    render(<StartSeat hosts={hosts} onClose={() => {}} onStarted={() => {}} />);
    expect(screen.getByText(/needs a fresh sign-in/)).toBeTruthy();
    expect((screen.getByRole("button", { name: "Start the seat" }) as HTMLButtonElement).disabled).toBe(true);

    auth.scope = "app";
    cleanup();
    vi.mocked(api.spawnSeat).mockRejectedValueOnce(new Error("spawning seats is app-only"));
    render(<StartSeat hosts={hosts} onClose={() => {}} onStarted={() => {}} />);
    await screen.findByRole("option", { name: "/home/me/projects/app" });
    fireEvent.click(screen.getByRole("button", { name: "Start the seat" }));
    expect(await screen.findByText(/needs a fresh sign-in/)).toBeTruthy();
    expect(screen.queryByText("spawning seats is app-only")).toBeNull();
  });

  test("an older machine's agent: no model or pool to choose, and the form says how to get them", async () => {
    render(<StartSeat hosts={hosts} initialHost="old" onClose={() => {}} onStarted={() => {}} />);
    expect((screen.getByLabelText("Model") as HTMLSelectElement).disabled).toBe(true);
    expect((screen.getByLabelText("Use the server's account pool") as HTMLInputElement).disabled).toBe(true);
    expect(screen.getByText(/Run the installer again on old/)).toBeTruthy();
    await screen.findByRole("option", { name: "/home/me/projects/app" });
    fireEvent.click(screen.getByRole("button", { name: "Start the seat" }));
    await waitFor(() => expect(api.spawnSeat).toHaveBeenCalledWith("old", { path: "/home/me/projects", title: "projects", mode: "auto" }));
  });

  test("a refusal is shown in the server's words", async () => {
    vi.mocked(api.spawnSeat).mockRejectedValueOnce(new Error("one spawn per 10 s per host"));
    render(<StartSeat hosts={hosts} onClose={() => {}} onStarted={() => {}} />);
    await screen.findByRole("option", { name: "/home/me/projects/app" });
    fireEvent.click(screen.getByRole("button", { name: "Start the seat" }));
    expect((await screen.findByRole("alert")).textContent).toBe("one spawn per 10 s per host");
  });

  test("a bad name is caught before asking the machine", async () => {
    render(<StartSeat hosts={hosts} onClose={() => {}} onStarted={() => {}} />);
    fireEvent.change(screen.getByLabelText("Name"), { target: { value: "my seat" } });
    expect(screen.getByText(/letters, digits/)).toBeTruthy();
    expect((screen.getByRole("button", { name: "Start the seat" }) as HTMLButtonElement).disabled).toBe(true);
  });

  test("with no machine online it says so, rather than showing an empty form", () => {
    render(<StartSeat hosts={[hosts[2]]} onClose={() => {}} onStarted={() => {}} />);
    expect(screen.getByText(/No machine is online/)).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Start the seat" })).toBeNull();
  });
});

describe("Machines", () => {
  test("an online machine can start a seat; an offline one says when it was last seen", () => {
    const onStart = vi.fn();
    vi.setSystemTime(new Date("2026-10-12T11:00:00Z"));
    render(<Machines hosts={hosts} onStart={onStart} />);
    expect(screen.getByText("last seen 3h ago")).toBeTruthy();
    expect(screen.getAllByRole("button", { name: "Start a seat" })).toHaveLength(2);
    fireEvent.click(screen.getAllByRole("button", { name: "Start a seat" })[0]);
    expect(onStart).toHaveBeenCalledWith("box");
    vi.useRealTimers();
  });
});
