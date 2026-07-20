import { render, screen, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

const DAY = 86400000;
const now = new Date(); now.setHours(0,0,0,0);
function daysFromNow(n) { return new Date(now.getTime() + n * DAY).toISOString(); }

const lists = [
  { id: "L1", title: "Work" },
  { id: "L2", title: "Personal" },
];

function task(id, title, opts = {}) {
  return {
    id, parent_id: opts.parent || null, title, notes: opts.notes || null,
    status: opts.status || "needsAction", due: opts.due ?? null,
    position: opts.pos || "1", sync_state: "clean",
    listId: opts.list || "L1", listTitle: opts.listTitle || "Work",
  };
}

function mockBackend(tasks = []) {
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return tasks.filter(t => t.listId === args?.listId);
      case "sync_now": return "ok";
      default: return null;
    }
  });
}

describe("Smart View Counts in Sidebar", () => {
  beforeEach(() => { localStorage.clear(); localStorage.setItem("axiotask:view", "focus"); invoke.mockReset(); });

  it("shows task count badge for Focus view", async () => {
    mockBackend([
      task("t1", "Overdue", { due: daysFromNow(-1) }),
      task("t2", "Today", { due: daysFromNow(0) }),
      task("t3", "This week", { due: daysFromNow(3) }),
    ]);
    render(App);
    // Wait for tasks to load and counts to render
    await waitFor(() => {
      const btn = screen.getByRole("button", { name: /focus/i });
      expect(btn.textContent).toMatch(/3/);
    });
  });

  it("shows task count badge for Missed view", async () => {
    mockBackend([
      task("t1", "Overdue1", { due: daysFromNow(-3) }),
      task("t2", "Overdue2", { due: daysFromNow(-1) }),
      task("t3", "On time", { due: daysFromNow(2) }),
    ]);
    render(App);
    await waitFor(() => {
      const btn = screen.getByRole("button", { name: /missed/i });
      expect(btn.textContent).toMatch(/2/);
    });
  });

  it("shows task count badge for Unscheduled view", async () => {
    mockBackend([
      task("t1", "No date", { due: null }),
      task("t2", "Has date", { due: daysFromNow(1) }),
    ]);
    render(App);
    await waitFor(() => {
      const btn = screen.getByRole("button", { name: /unscheduled/i });
      expect(btn.textContent).toMatch(/1/);
    });
  });

  it("does not count completed tasks in badges", async () => {
    mockBackend([
      task("t1", "Done", { due: daysFromNow(0), status: "completed" }),
      task("t2", "Open", { due: daysFromNow(0) }),
    ]);
    render(App);
    await waitFor(() => {
      const btn = screen.getByRole("button", { name: /focus/i });
      expect(btn.textContent).toMatch(/1/);
    });
  });

  it("excludes tasks from excluded lists in counts", async () => {
    localStorage.setItem("axiotask:excludedLists", JSON.stringify(["L2"]));
    mockBackend([
      task("t1", "Work today", { due: daysFromNow(0), list: "L1" }),
      task("t2", "Personal today", { due: daysFromNow(0), list: "L2", listTitle: "Personal" }),
    ]);
    render(App);
    await waitFor(() => {
      const btn = screen.getByRole("button", { name: /focus/i });
      expect(btn.textContent).toMatch(/1/);
    });
  });
});

describe("Smart Views: Missed sort order", () => {
  beforeEach(() => { localStorage.clear(); localStorage.setItem("axiotask:view", "missed"); invoke.mockReset(); });

  it("sorts overdue tasks oldest-first", async () => {
    mockBackend([
      task("t1", "Yesterday", { due: daysFromNow(-1) }),
      task("t2", "Three days ago", { due: daysFromNow(-3) }),
      task("t3", "A week ago", { due: daysFromNow(-7) }),
    ]);
    render(App);
    await waitFor(() => expect(screen.getByText("A week ago")).toBeInTheDocument());
    // Verify order by checking DOM position of task titles
    const all = screen.getAllByText(/Yesterday|Three days ago|A week ago/);
    expect(all[0].textContent).toContain("A week ago");
    expect(all[1].textContent).toContain("Three days ago");
    expect(all[2].textContent).toContain("Yesterday");
  });
});
