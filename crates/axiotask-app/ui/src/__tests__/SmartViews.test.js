import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

const DAY = 86400000;
const now = new Date(); now.setHours(0,0,0,0);
function daysFromNow(n) { return new Date(now.getTime() + n * DAY).toISOString(); }

const lists = [
  { id: "L1", title: "Work" },
  { id: "L2", title: "Personal" },
  { id: "L3", title: "Someday" },
];

function task(id, title, opts = {}) {
  return {
    id, parent_id: opts.parent || null, title, notes: opts.notes || null,
    status: opts.status || "needsAction", due: opts.due ?? null,
    position: opts.pos || "1", sync_state: "clean",
    listId: opts.list || "L1", listTitle: opts.listTitle || "Work",
  };
}

function mockBackend(tasks = [], excludedLists = []) {
  // Set excluded lists in localStorage
  if (excludedLists.length) localStorage.setItem("axiotask:excludedLists", JSON.stringify(excludedLists));

  let taskStore = [...tasks];
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return taskStore.filter(t => t.listId === args?.listId);
      case "create_task": {
        const t = { id: `new-1`, parent_id: args.parentId, title: args.title, notes: null, status: "needsAction", due: null, position: "99", sync_state: "clean", listId: args.listId, listTitle: lists.find(l => l.id === args.listId)?.title };
        taskStore.push(t);
        return t;
      }
      case "toggle_complete": { const t = taskStore.find(x => x.id === args.id); if (t) t.status = "completed"; return null; }
      case "delete_task": { taskStore = taskStore.filter(t => t.id !== args.id); return null; }
      case "set_due": return null;
      case "sync_now": return "ok";
      default: return null;
    }
  });
}

describe("Smart Views: Focus", () => {
  beforeEach(() => { localStorage.clear(); localStorage.setItem("axiotask:view", "focus"); invoke.mockReset(); });

  it("shows overdue tasks", async () => {
    mockBackend([task("t1", "Overdue", { due: daysFromNow(-2) })]);
    render(App);
    await waitFor(() => expect(screen.getByText("Overdue")).toBeInTheDocument());
  });

  it("shows tasks due today", async () => {
    mockBackend([task("t1", "Today task", { due: daysFromNow(0) })]);
    render(App);
    await waitFor(() => expect(screen.getByText("Today task")).toBeInTheDocument());
  });

  it("shows tasks due this week", async () => {
    mockBackend([task("t1", "This week", { due: daysFromNow(3) })]);
    render(App);
    await waitFor(() => expect(screen.getByText("This week")).toBeInTheDocument());
  });

  it("does NOT show tasks due beyond this week", async () => {
    mockBackend([task("t1", "Far away", { due: daysFromNow(10) })]);
    render(App);
    await waitFor(() => expect(screen.getByRole("button", { name: /focus/i })).toBeInTheDocument());
    expect(screen.queryByText("Far away")).not.toBeInTheDocument();
  });

  it("excludes tasks from excluded lists", async () => {
    mockBackend(
      [task("t1", "Work task", { due: daysFromNow(0), list: "L1" }), task("t2", "Someday task", { due: daysFromNow(0), list: "L3", listTitle: "Someday" })],
      ["L3"]
    );
    render(App);
    await waitFor(() => expect(screen.getByText("Work task")).toBeInTheDocument());
    expect(screen.queryByText("Someday task")).not.toBeInTheDocument();
  });

  it("a subtask due soon pulls its parent in as one card, count matches (#3)", async () => {
    mockBackend([
      task("p1", "Parent no due", { due: null }),
      task("s1", "Subtask due tomorrow", { parent: "p1", due: daysFromNow(1) }),
      task("other", "Unrelated no due", { due: null }),
    ]);
    render(App);
    await waitFor(() => expect(screen.getByText("Parent no due")).toBeInTheDocument());
    // The parent card is pulled in by its subtask's date, but the subtask is
    // never a row here (#82) — it lives in the detail panel. The unrelated
    // undated task isn't in Focus.
    expect(screen.queryByText("Subtask due tomorrow")).not.toBeInTheDocument();
    expect(screen.queryByText("Unrelated no due")).not.toBeInTheDocument();
    // The Focus badge counts the one parent card.
    expect(screen.getByRole("button", { name: /focus/i })).toHaveTextContent("1");
  });
});

describe("Smart Views: Upcoming", () => {
  beforeEach(() => { localStorage.clear(); localStorage.setItem("axiotask:view", "upcoming"); invoke.mockReset(); });

  it("shows tasks due in next 14 days", async () => {
    mockBackend([
      task("t1", "Tomorrow", { due: daysFromNow(1) }),
      task("t2", "Next week", { due: daysFromNow(7) }),
    ]);
    render(App);
    await waitFor(() => {
      expect(screen.getByText("Tomorrow")).toBeInTheDocument();
      expect(screen.getByText("Next week")).toBeInTheDocument();
    });
  });

  it("does NOT show tasks due beyond 14 days", async () => {
    mockBackend([task("t1", "Far future", { due: daysFromNow(20) })]);
    render(App);
    await waitFor(() => expect(screen.getByRole("button", { name: /upcoming/i })).toBeInTheDocument());
    expect(screen.queryByText("Far future")).not.toBeInTheDocument();
  });
});

describe("Smart Views: Missed", () => {
  beforeEach(() => { localStorage.clear(); localStorage.setItem("axiotask:view", "missed"); invoke.mockReset(); });

  it("shows only overdue tasks", async () => {
    mockBackend([
      task("t1", "Overdue", { due: daysFromNow(-3) }),
      task("t2", "Today", { due: daysFromNow(0) }),
      task("t3", "Future", { due: daysFromNow(5) }),
    ]);
    render(App);
    await waitFor(() => expect(screen.getByText("Overdue")).toBeInTheDocument());
    expect(screen.queryByText("Today")).not.toBeInTheDocument();
    expect(screen.queryByText("Future")).not.toBeInTheDocument();
  });

  it("shows empty state when nothing overdue", async () => {
    mockBackend([task("t1", "On time", { due: daysFromNow(1) })]);
    render(App);
    await waitFor(() => expect(screen.getByText(/Nothing overdue/)).toBeInTheDocument());
  });
});

describe("Smart Views: Unscheduled", () => {
  beforeEach(() => { localStorage.clear(); localStorage.setItem("axiotask:view", "unscheduled"); invoke.mockReset(); });

  it("shows only tasks with no due date", async () => {
    mockBackend([
      task("t1", "No date", { due: null }),
      task("t2", "Has date", { due: daysFromNow(1) }),
    ]);
    render(App);
    await waitFor(() => expect(screen.getByText("No date")).toBeInTheDocument());
    expect(screen.queryByText("Has date")).not.toBeInTheDocument();
  });

  it("shows empty state when everything is scheduled", async () => {
    mockBackend([task("t1", "Scheduled", { due: daysFromNow(1) })]);
    render(App);
    await waitFor(() => expect(screen.getByText(/Everything is scheduled/)).toBeInTheDocument());
  });
});
