import { describe, it, expect } from "vitest";
import {
  defaultRule,
  toRrule,
  fromRrule,
  summarize,
  extractFromNotes,
  embedInNotes,
} from "../recurrence.js";

describe("recurrence RRULE serialization", () => {
  it("serializes a simple daily rule", () => {
    expect(toRrule(defaultRule("DAILY"))).toBe("FREQ=DAILY");
  });

  it("includes interval when not 1", () => {
    expect(toRrule({ freq: "DAILY", interval: 3, byday: [], end: { kind: "never" } })).toBe(
      "FREQ=DAILY;INTERVAL=3",
    );
  });

  it("includes weekday list for weekly rules", () => {
    const rule = { freq: "WEEKLY", interval: 2, byday: ["MO", "WE", "FR"], end: { kind: "never" } };
    expect(toRrule(rule)).toBe("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR");
  });

  it("omits byday for non-weekly frequencies", () => {
    const rule = { freq: "MONTHLY", interval: 1, byday: ["MO"], end: { kind: "never" } };
    expect(toRrule(rule)).toBe("FREQ=MONTHLY");
  });

  it("serializes until date", () => {
    const rule = { freq: "WEEKLY", interval: 1, byday: [], end: { kind: "onDate", date: "2026-12-31" } };
    expect(toRrule(rule)).toBe("FREQ=WEEKLY;UNTIL=20261231");
  });

  it("serializes count", () => {
    const rule = { freq: "DAILY", interval: 1, byday: [], end: { kind: "count", count: 5 } };
    expect(toRrule(rule)).toBe("FREQ=DAILY;COUNT=5");
  });

  it("clamps interval below 1", () => {
    expect(toRrule({ freq: "DAILY", interval: 0, byday: [], end: { kind: "never" } })).toBe("FREQ=DAILY");
  });
});

describe("recurrence RRULE parsing", () => {
  it("parses freq and interval", () => {
    expect(fromRrule("FREQ=WEEKLY;INTERVAL=2")).toEqual({
      freq: "WEEKLY",
      interval: 2,
      byday: [],
      end: { kind: "never" },
    });
  });

  it("parses byday", () => {
    expect(fromRrule("FREQ=WEEKLY;BYDAY=MO,WE,FR").byday).toEqual(["MO", "WE", "FR"]);
  });

  it("parses until into a date input value", () => {
    expect(fromRrule("FREQ=DAILY;UNTIL=20261231").end).toEqual({
      kind: "onDate",
      date: "2026-12-31",
    });
  });

  it("parses until in datetime form", () => {
    expect(fromRrule("FREQ=DAILY;UNTIL=20260901T000000Z").end).toEqual({
      kind: "onDate",
      date: "2026-09-01",
    });
  });

  it("parses count", () => {
    expect(fromRrule("FREQ=YEARLY;COUNT=3").end).toEqual({ kind: "count", count: 3 });
  });

  it("accepts RRULE: prefix and is case-insensitive", () => {
    expect(fromRrule("RRULE:freq=daily").freq).toBe("DAILY");
  });

  it("ignores unknown tokens", () => {
    expect(fromRrule("FREQ=DAILY;WKST=MO;FOO=BAR").freq).toBe("DAILY");
  });

  it("returns null without a freq", () => {
    expect(fromRrule("INTERVAL=2")).toBeNull();
    expect(fromRrule("")).toBeNull();
  });

  it("round-trips through serialize/parse", () => {
    const rule = { freq: "WEEKLY", interval: 2, byday: ["MO", "WE"], end: { kind: "count", count: 4 } };
    expect(fromRrule(toRrule(rule))).toEqual(rule);
  });
});

describe("recurrence summarize", () => {
  it("describes a simple rule", () => {
    expect(summarize(defaultRule("DAILY"))).toBe("Daily");
  });

  it("describes an interval rule", () => {
    expect(summarize({ freq: "MONTHLY", interval: 3, byday: [], end: { kind: "never" } })).toBe(
      "Every 3 months",
    );
  });

  it("describes weekly weekdays and count", () => {
    expect(
      summarize({ freq: "WEEKLY", interval: 2, byday: ["MO", "WE", "FR"], end: { kind: "count", count: 5 } }),
    ).toBe("Every 2 weeks on Mon, Wed, Fri, 5 times");
  });

  it("describes an until date", () => {
    expect(
      summarize({ freq: "WEEKLY", interval: 1, byday: [], end: { kind: "onDate", date: "2026-12-31" } }),
    ).toBe("Weekly, until 2026-12-31");
  });
});

describe("recurrence notes trailer", () => {
  it("extracts a rule from notes", () => {
    const { visible, rule } = extractFromNotes("Water plants\n[[recur:FREQ=DAILY]]");
    expect(visible).toBe("Water plants");
    expect(rule.freq).toBe("DAILY");
  });

  it("returns null rule when no trailer present", () => {
    const { visible, rule } = extractFromNotes("Just a note");
    expect(visible).toBe("Just a note");
    expect(rule).toBeNull();
  });

  it("embeds a trailer", () => {
    expect(embedInNotes("Standup", defaultRule("WEEKLY"))).toBe("Standup\n[[recur:FREQ=WEEKLY]]");
  });

  it("replaces an existing trailer", () => {
    expect(embedInNotes("Standup\n[[recur:FREQ=DAILY]]", defaultRule("WEEKLY"))).toBe(
      "Standup\n[[recur:FREQ=WEEKLY]]",
    );
  });

  it("strips a trailer when rule is null", () => {
    expect(embedInNotes("Standup\n[[recur:FREQ=DAILY]]", null)).toBe("Standup");
  });

  it("handles empty visible text", () => {
    expect(embedInNotes("", defaultRule("DAILY"))).toBe("[[recur:FREQ=DAILY]]");
  });

  it("round-trips embed then extract", () => {
    const rule = { freq: "WEEKLY", interval: 2, byday: ["MO", "WE"], end: { kind: "count", count: 4 } };
    const stored = embedInNotes("Gym", rule);
    const out = extractFromNotes(stored);
    expect(out.visible).toBe("Gym");
    expect(out.rule).toEqual(rule);
  });
});
