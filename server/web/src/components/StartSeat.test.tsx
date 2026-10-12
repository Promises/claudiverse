import { afterEach, describe, expect, test, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import type { Host } from "../api/hosts";
import StartSeat from "./StartSeat";
import Machines from "./Machines";

vi.mock("../api/hosts", () => ({
  listFolders: vi.fn(async (_host: string, path: string) => ({ path, parent: "", dirs: ["app", "site"], truncated: false })),
  spawnSeat: vi.fn(async () => ({ spawn_id: "sp-1" })),
}));
const api = await import("../api/hosts");

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
