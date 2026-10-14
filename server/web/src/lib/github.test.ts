import { describe, expect, test } from "vitest";
import { expiryText, scopeText } from "./github";

describe("expiryText", () => {
  const now = new Date("2026-10-14T12:00:00Z");
  test("days to go, or since, or none sent", () => {
    expect(expiryText("2026-10-17T12:00:00Z", now)).toBe("expires in 3 days");
    expect(expiryText("2026-10-15T12:00:00Z", now)).toBe("expires in 1 day");
    expect(expiryText("2026-10-14T13:00:00Z", now)).toBe("expires today");
    expect(expiryText("2026-10-12T12:00:00Z", now)).toBe("expired 2 days ago");
    expect(expiryText(null, now)).toBe("never expires");
  });
});

test("scopeText: a classic token's scopes; a fine-grained token's are not reported by GitHub", () => {
  expect(scopeText({ kind: "classic", scopes: ["repo", "read:org"] })).toBe("repo, read:org");
  expect(scopeText({ kind: "fine_grained", scopes: null })).toMatch(/does not report/);
});
