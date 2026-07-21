// Shared due-date formatting used by the list rows (TaskRow) and the detail
// panel (TaskDetail) so friendly, relative dates render identically everywhere.

// Due values are date-only (Google sends midnight UTC, e.g.
// "2026-06-15T00:00:00.000Z"). Parsing the whole string with `new Date` and
// formatting in local time shifts to the previous day in negative-UTC zones.
// Parse the YYYY-MM-DD portion into local components instead.
export function parseLocalDate(due) {
  const [y, m, d] = due.slice(0, 10).split("-").map(Number);
  return new Date(y, m - 1, d);
}

export function formatDue(due) {
  if (!due) return "";
  const d = parseLocalDate(due);
  const now = new Date(); now.setHours(0, 0, 0, 0);
  const diff = Math.round((d - now) / 86400000);
  if (diff < -1) return `${-diff}d overdue`;
  if (diff === -1) return "yesterday";
  if (diff === 0) return "today";
  if (diff === 1) return "tomorrow";
  if (diff < 7) return `in ${diff}d`;
  return d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

export function dueClass(due) {
  if (!due) return "";
  const d = parseLocalDate(due);
  const now = new Date(); now.setHours(0, 0, 0, 0);
  if (d < now) return "overdue";
  if (d.getTime() === now.getTime()) return "due-today";
  return "";
}
