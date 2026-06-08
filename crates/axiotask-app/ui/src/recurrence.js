// Client-side recurrence helpers for the UI.
//
// Mirrors crates/axiotask-core/src/recurrence.rs so the RRULE string and the
// `[[recur:...]]` notes trailer round-trip identically between Rust and the
// frontend. The Google Tasks API has no recurrence field, so the rule is
// carried inside the (synced) notes field.

export const FREQUENCIES = ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"];

// RFC 5545 weekday tokens in display order (Mon-first).
export const WEEKDAYS = [
  { token: "MO", short: "Mon" },
  { token: "TU", short: "Tue" },
  { token: "WE", short: "Wed" },
  { token: "TH", short: "Thu" },
  { token: "FR", short: "Fri" },
  { token: "SA", short: "Sat" },
  { token: "SU", short: "Sun" },
];

const WEEKDAY_SHORT = Object.fromEntries(WEEKDAYS.map((w) => [w.token, w.short]));

const TRAILER_OPEN = "[[recur:";
const TRAILER_CLOSE = "]]";

const FREQ_NOUN = {
  DAILY: "day",
  WEEKLY: "week",
  MONTHLY: "month",
  YEARLY: "year",
};

const FREQ_ADVERB = {
  DAILY: "Daily",
  WEEKLY: "Weekly",
  MONTHLY: "Monthly",
  YEARLY: "Yearly",
};

/**
 * Create a default rule object for a given frequency.
 * @param {string} freq
 */
export function defaultRule(freq = "WEEKLY") {
  return { freq, interval: 1, byday: [], end: { kind: "never" } };
}

/**
 * Serialize a rule object to an RFC 5545 RRULE value.
 * @param {{freq:string, interval:number, byday:string[], end:object}} rule
 * @returns {string}
 */
export function toRrule(rule) {
  const parts = [`FREQ=${rule.freq}`];
  const interval = Math.max(1, Number(rule.interval) || 1);
  if (interval !== 1) parts.push(`INTERVAL=${interval}`);
  if (rule.freq === "WEEKLY" && rule.byday && rule.byday.length > 0) {
    parts.push(`BYDAY=${rule.byday.join(",")}`);
  }
  const end = rule.end || { kind: "never" };
  if (end.kind === "onDate" && end.date) {
    parts.push(`UNTIL=${end.date.replaceAll("-", "")}`);
  } else if (end.kind === "count" && end.count) {
    parts.push(`COUNT=${end.count}`);
  }
  return parts.join(";");
}

/**
 * Parse an RFC 5545 RRULE value into a rule object, or null if there is no
 * usable FREQ. Unknown tokens are ignored.
 * @param {string} s
 */
export function fromRrule(s) {
  if (!s) return null;
  const body = s.trim().replace(/^RRULE:/i, "");
  let freq = null;
  let interval = 1;
  let byday = [];
  let end = { kind: "never" };

  for (const token of body.split(";")) {
    const trimmed = token.trim();
    if (!trimmed) continue;
    const eq = trimmed.indexOf("=");
    if (eq < 0) continue;
    const key = trimmed.slice(0, eq).trim().toUpperCase();
    const value = trimmed.slice(eq + 1).trim();
    switch (key) {
      case "FREQ": {
        const up = value.toUpperCase();
        if (FREQUENCIES.includes(up)) freq = up;
        break;
      }
      case "INTERVAL": {
        const n = parseInt(value, 10);
        if (!Number.isNaN(n)) interval = Math.max(1, n);
        break;
      }
      case "BYDAY":
        byday = value
          .split(",")
          .map((d) => d.trim().toUpperCase())
          .filter((d) => WEEKDAY_SHORT[d]);
        break;
      case "UNTIL": {
        const d = parseUntil(value);
        if (d) end = { kind: "onDate", date: d };
        break;
      }
      case "COUNT": {
        const n = parseInt(value, 10);
        if (!Number.isNaN(n)) end = { kind: "count", count: n };
        break;
      }
      default:
        break;
    }
  }

  if (!freq) return null;
  return { freq, interval, byday, end };
}

// Accepts YYYYMMDD or YYYYMMDDTHHMMSSZ, returns YYYY-MM-DD (date input value).
function parseUntil(value) {
  const datePart = value.split("T")[0];
  if (!/^\d{8}$/.test(datePart)) return null;
  return `${datePart.slice(0, 4)}-${datePart.slice(4, 6)}-${datePart.slice(6, 8)}`;
}

/**
 * Human-readable summary, e.g. "Every 2 weeks on Mon, Wed, Fri".
 * @param {object} rule
 */
export function summarize(rule) {
  if (!rule) return "";
  const interval = Math.max(1, Number(rule.interval) || 1);
  let out =
    interval === 1
      ? FREQ_ADVERB[rule.freq]
      : `Every ${interval} ${FREQ_NOUN[rule.freq]}s`;

  if (rule.freq === "WEEKLY" && rule.byday && rule.byday.length > 0) {
    const days = rule.byday.map((d) => WEEKDAY_SHORT[d]).filter(Boolean);
    out += ` on ${days.join(", ")}`;
  }
  const end = rule.end || { kind: "never" };
  if (end.kind === "onDate" && end.date) {
    out += `, until ${end.date}`;
  } else if (end.kind === "count" && end.count) {
    out += `, ${end.count} times`;
  }
  return out;
}

/**
 * Split a stored notes string into visible text and an embedded rule.
 * @param {string} notes
 * @returns {{ visible: string, rule: object|null }}
 */
export function extractFromNotes(notes) {
  const text = notes || "";
  const open = text.lastIndexOf(TRAILER_OPEN);
  if (open >= 0) {
    const after = text.slice(open + TRAILER_OPEN.length);
    const closeRel = after.indexOf(TRAILER_CLOSE);
    if (closeRel >= 0) {
      const ruleStr = after.slice(0, closeRel);
      const restStart = open + TRAILER_OPEN.length + closeRel + TRAILER_CLOSE.length;
      const visible = (text.slice(0, open) + text.slice(restStart)).trim();
      return { visible, rule: fromRrule(ruleStr) };
    }
  }
  return { visible: text, rule: null };
}

/**
 * Embed (or replace) a recurrence trailer in a notes string. Passing a falsy
 * rule strips any existing trailer.
 * @param {string} notes
 * @param {object|null} rule
 * @returns {string}
 */
export function embedInNotes(notes, rule) {
  const { visible } = extractFromNotes(notes);
  if (!rule) return visible;
  const trailer = `${TRAILER_OPEN}${toRrule(rule)}${TRAILER_CLOSE}`;
  return visible ? `${visible}\n${trailer}` : trailer;
}
