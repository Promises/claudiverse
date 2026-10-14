import { afterEach, expect, test, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import GitHubPage from "./GitHubPage";
import type { GitHubToken } from "../api/github";

const token = (extra: Partial<GitHubToken> = {}): GitHubToken => ({
  id: 1, label: "personal", kind: "fine_grained", login: "example-user", scopes: null, expires_at: "2099-01-01T00:00:00Z",
  expiry_source: "github", expires_on: null, serving: [],
  expiring: false, repos_count: 150, status: "ok", last_error: null, checked_at: null, ...extra,
});

// The sign-in's scope: "app" unless a test makes it an older one.
const auth = vi.hoisted(() => ({ scope: "app" as string | null, logout: vi.fn() }));
vi.mock("../contexts/AuthContext", () => ({ useAuth: () => auth }));
vi.mock("../api/github", () => ({
  listTokens: vi.fn(async () => ({ tokens: [], vault_configured: true })),
  addToken: vi.fn(async () => token()),
  checkToken: vi.fn(),
  removeToken: vi.fn(),
  setExpiresOn: vi.fn(async () => token()),
  listSubscriptions: vi.fn(async () => []),
}));
const api = await import("../api/github");

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
  auth.scope = "app";
});

const page = () => render(<MemoryRouter><GitHubPage /></MemoryRouter>);

test("the token is typed into a password field, sent once, and cleared after", async () => {
  page();
  const field = (await screen.findByLabelText("Token")) as HTMLInputElement;
  expect(field.type).toBe("password");
  fireEvent.change(screen.getByLabelText("Name"), { target: { value: "personal" } });
  fireEvent.change(field, { target: { value: "github_pat_example" } });
  fireEvent.click(screen.getByRole("button", { name: "Add token" }));
  await waitFor(() => expect(api.addToken).toHaveBeenCalledWith("personal", "github_pat_example"));
  await waitFor(() => expect(field.value).toBe(""));
});

test("a token: its account, repos and expiry; one about to expire is flagged", async () => {
  vi.mocked(api.listTokens).mockResolvedValueOnce({ tokens: [token({ expiring: true, expires_at: new Date(Date.now() + 3 * 86_400_000).toISOString() })], vault_configured: true });
  page();
  expect(await screen.findByText("example-user")).toBeTruthy();
  expect(screen.getByText("150")).toBeTruthy();
  expect(screen.getByText("expires in 3 days")).toBeTruthy();
  expect(screen.getByText("Expiring soon")).toBeTruthy();
});

test("a token GitHub reports no expiry for takes one entered here; one GitHub reports does not", async () => {
  vi.mocked(api.listTokens).mockResolvedValueOnce({
    tokens: [token({ id: 1, label: "forever", expires_at: null, expiry_source: null }), token({ id: 2, label: "dated" })],
    vault_configured: true,
  });
  page();
  const field = (await screen.findByLabelText("Expiry date, if the token has one")) as HTMLInputElement;
  expect(screen.getAllByLabelText("Expiry date, if the token has one")).toHaveLength(1);
  fireEvent.change(field, { target: { value: "2027-03-01" } });
  fireEvent.click(screen.getByRole("button", { name: "Save date" }));
  await waitFor(() => expect(api.setExpiresOn).toHaveBeenCalledWith(1, "2027-03-01"));
});

test("a sign-in that cannot hold GitHub tokens is told to sign in again, and offered no form", async () => {
  auth.scope = "api";
  page();
  expect(await screen.findByText(/needs a fresh sign-in/)).toBeTruthy();
  expect(screen.queryByLabelText("Token")).toBeNull();
  expect(api.listTokens).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Sign out" }));
  expect(auth.logout).toHaveBeenCalled();
});

test("the server's app-only refusal is shown as the same notice, not its raw words", async () => {
  vi.mocked(api.listTokens).mockRejectedValueOnce(new Error("GitHub tokens are app-only"));
  page();
  expect(await screen.findByText(/needs a fresh sign-in/)).toBeTruthy();
  expect(screen.queryByText("GitHub tokens are app-only")).toBeNull();
});

test("each subscription with its seats and the token that reads it; a repository no token reaches says so", async () => {
  vi.mocked(api.listTokens).mockResolvedValueOnce({ tokens: [token({ serving: ["example-org/example-repo"] })], vault_configured: true });
  vi.mocked(api.listSubscriptions).mockResolvedValueOnce([
    { title: "gh:example-org/example-repo:prs", seats: ["seat-a"], repo: "example-org/example-repo", token: { id: 1, label: "personal", kind: "fine_grained" }, reached: true, unreached: null, last_read_at: null },
    { title: "gh:nobody/unreached", seats: ["seat-b"], repo: "nobody/unreached", token: null, reached: false, unreached: "no_token", last_read_at: null },
    { title: "gh:example-org/new-repo", seats: ["seat-b"], repo: "example-org/new-repo", token: null, reached: false, unreached: "repos_not_loaded", last_read_at: null },
  ]);
  page();
  expect(await screen.findByText("gh:example-org/example-repo:prs")).toBeTruthy();
  expect(screen.getByText("example-org/example-repo")).toBeTruthy();
  expect(screen.getByText("No token reaches nobody/unreached: it is not read.")).toBeTruthy();
  // A list not loaded yet is not "no token reaches it".
  expect(screen.getByText(/list of repositories is not loaded yet/)).toBeTruthy();
  expect(screen.queryByText("No token reaches example-org/new-repo: it is not read.")).toBeNull();
  expect(screen.getAllByText("seat-b")).toHaveLength(2);
});
