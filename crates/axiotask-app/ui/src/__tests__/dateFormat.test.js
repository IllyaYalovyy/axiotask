// Task 126: a due date rendered in the list must show its year when it is NOT
// the current calendar year, and stay compact (month/day only) when it is.
// formatDue is the single shared formatter behind the list rows, smart views,
// the detail panel and the quick-add preview, so this locks the behavior at the
// source. Assertions are locale-robust: we check for the presence/absence of the
// year number rather than an exact format string.
import { describe, it, expect, vi, afterEach } from "vitest";
import { formatDue } from "../dateFormat.js";

// A date-only due in Google's midnight-UTC form (what the backend returns).
function dueISO(y, m, d) {
  return `${y}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}T00:00:00.000Z`;
}

afterEach(() => vi.useRealTimers());

describe("formatDue — year shown only outside the current year", () => {
  it("omits the year for a far-out date in the current year", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(2026, 7, 3)); // Aug 3, 2026 (local midnight)
    const out = formatDue(dueISO(2026, 12, 25)); // Dec 25, same year, 7+ days out
    expect(out).not.toMatch(/2026/); // stays compact — no year
    expect(out).toMatch(/25/); // still a real date, not a relative label
  });

  it("shows the year for a far-out date in a different (future) year", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(2026, 7, 3)); // Aug 3, 2026
    const out = formatDue(dueISO(2027, 3, 10)); // Mar 10 next year
    expect(out).toMatch(/2027/);
  });

  // Non-happy path: a near-term date that crosses the year boundary keeps its
  // relative label — the year is added only to absolute (7+ days out) dates,
  // never leaked into "today"/"tomorrow"/"in Nd".
  it("keeps the relative label across a year boundary (no year leak)", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(2026, 11, 31)); // Dec 31, 2026
    expect(formatDue(dueISO(2027, 1, 1))).toBe("tomorrow");
  });
});
