import { render, screen, fireEvent, waitFor, cleanup } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
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

describe("GH#15: List Exclusion from Smart Views", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });
  afterEach(() => cleanup());

  describe("Right-click toggle", () => {
    it("right-click on list shows 'Exclude from smart views' option", async () => {
      localStorage.setItem("axiotask:view", "focus");
      mockBackend([]);
      render(App);
      await waitFor(() => expect(screen.getByRole("button", { name: /Someday/i })).toBeInTheDocument());

      await fireEvent.contextMenu(screen.getByRole("button", { name: /Someday/i }), { clientX: 100, clientY: 100 });
      await waitFor(() => expect(screen.getByText("Exclude from smart views")).toBeInTheDocument());
    });

    it("right-click on excluded list shows 'Include in smart views' option", async () => {
      localStorage.setItem("axiotask:view", "focus");
      localStorage.setItem("axiotask:excludedLists", JSON.stringify(["L3"]));
      mockBackend([]);
      render(App);
      await waitFor(() => expect(screen.getByRole("button", { name: /Someday/i })).toBeInTheDocument());

      await fireEvent.contextMenu(screen.getByRole("button", { name: /Someday/i }), { clientX: 100, clientY: 100 });
      await waitFor(() => expect(screen.getByText("Include in smart views")).toBeInTheDocument());
    });

    it("excluding a list hides its tasks from Focus view", async () => {
      localStorage.setItem("axiotask:view", "focus");
      mockBackend([
        task("t1", "Work task", { due: daysFromNow(0), list: "L1" }),
        task("t2", "Someday task", { due: daysFromNow(0), list: "L3", listTitle: "Someday" }),
      ]);
      render(App);
      await waitFor(() => expect(screen.getByText("Work task")).toBeInTheDocument());
      expect(screen.getByText("Someday task")).toBeInTheDocument();

      // Right-click Someday list → Exclude
      await fireEvent.contextMenu(screen.getByRole("button", { name: /Someday/i }), { clientX: 100, clientY: 100 });
      await waitFor(() => expect(screen.getByText("Exclude from smart views")).toBeInTheDocument());
      await fireEvent.click(screen.getByText("Exclude from smart views"));

      // Someday task should disappear from Focus
      await waitFor(() => expect(screen.queryByText("Someday task")).not.toBeInTheDocument());
      expect(screen.getByText("Work task")).toBeInTheDocument();
    });

    it("including a list restores its tasks in smart views", async () => {
      localStorage.setItem("axiotask:view", "focus");
      localStorage.setItem("axiotask:excludedLists", JSON.stringify(["L3"]));
      mockBackend([
        task("t1", "Work task", { due: daysFromNow(0), list: "L1" }),
        task("t2", "Someday task", { due: daysFromNow(0), list: "L3", listTitle: "Someday" }),
      ]);
      render(App);
      await waitFor(() => expect(screen.getByText("Work task")).toBeInTheDocument());
      expect(screen.queryByText("Someday task")).not.toBeInTheDocument();

      // Right-click Someday list → Include
      await fireEvent.contextMenu(screen.getByRole("button", { name: /Someday/i }), { clientX: 100, clientY: 100 });
      await waitFor(() => expect(screen.getByText("Include in smart views")).toBeInTheDocument());
      await fireEvent.click(screen.getByText("Include in smart views"));

      // Someday task should reappear
      await waitFor(() => expect(screen.getByText("Someday task")).toBeInTheDocument());
    });
  });

  describe("Dimmed/italic in sidebar", () => {
    it("excluded list has 'excluded' class in sidebar", async () => {
      localStorage.setItem("axiotask:view", "focus");
      localStorage.setItem("axiotask:excludedLists", JSON.stringify(["L3"]));
      mockBackend([]);
      render(App);
      await waitFor(() => {
        const btn = screen.getByRole("button", { name: /Someday/i });
        expect(btn.classList.contains("excluded")).toBe(true);
      });
    });

    it("non-excluded list does not have 'excluded' class", async () => {
      localStorage.setItem("axiotask:view", "focus");
      localStorage.setItem("axiotask:excludedLists", JSON.stringify(["L3"]));
      mockBackend([]);
      render(App);
      await waitFor(() => {
        const btn = screen.getByRole("button", { name: /Work/i });
        expect(btn.classList.contains("excluded")).toBe(false);
      });
    });

    it("toggling exclusion updates the class", async () => {
      localStorage.setItem("axiotask:view", "focus");
      mockBackend([]);
      render(App);
      await waitFor(() => expect(screen.getByRole("button", { name: /Someday/i })).toBeInTheDocument());

      const btn = screen.getByRole("button", { name: /Someday/i });
      expect(btn.classList.contains("excluded")).toBe(false);

      // Exclude it
      await fireEvent.contextMenu(btn, { clientX: 100, clientY: 100 });
      await waitFor(() => expect(screen.getByText("Exclude from smart views")).toBeInTheDocument());
      await fireEvent.click(screen.getByText("Exclude from smart views"));

      await waitFor(() => expect(btn.classList.contains("excluded")).toBe(true));
    });
  });

  describe("Persistence in localStorage", () => {
    it("exclusion is saved to localStorage", async () => {
      localStorage.setItem("axiotask:view", "focus");
      mockBackend([]);
      render(App);
      await waitFor(() => expect(screen.getByRole("button", { name: /Someday/i })).toBeInTheDocument());

      // Exclude Someday
      await fireEvent.contextMenu(screen.getByRole("button", { name: /Someday/i }), { clientX: 100, clientY: 100 });
      await waitFor(() => expect(screen.getByText("Exclude from smart views")).toBeInTheDocument());
      await fireEvent.click(screen.getByText("Exclude from smart views"));

      await waitFor(() => {
        const stored = JSON.parse(localStorage.getItem("axiotask:excludedLists"));
        expect(stored).toContain("L3");
      });
    });

    it("inclusion removes from localStorage", async () => {
      localStorage.setItem("axiotask:view", "focus");
      localStorage.setItem("axiotask:excludedLists", JSON.stringify(["L3"]));
      mockBackend([]);
      render(App);
      await waitFor(() => expect(screen.getByRole("button", { name: /Someday/i })).toBeInTheDocument());

      // Include Someday
      await fireEvent.contextMenu(screen.getByRole("button", { name: /Someday/i }), { clientX: 100, clientY: 100 });
      await waitFor(() => expect(screen.getByText("Include in smart views")).toBeInTheDocument());
      await fireEvent.click(screen.getByText("Include in smart views"));

      await waitFor(() => {
        const stored = JSON.parse(localStorage.getItem("axiotask:excludedLists"));
        expect(stored).not.toContain("L3");
      });
    });
  });

  describe("Tasks hidden from smart views but visible in list", () => {
    it("excluded list tasks visible when list selected directly", async () => {
      localStorage.setItem("axiotask:view", "L3");
      localStorage.setItem("axiotask:excludedLists", JSON.stringify(["L3"]));
      mockBackend([
        task("t1", "Someday item", { due: daysFromNow(0), list: "L3", listTitle: "Someday" }),
      ]);
      render(App);
      await waitFor(() => expect(screen.getByText("Someday item")).toBeInTheDocument());
    });

    it("excluded list tasks hidden from all smart views", async () => {
      localStorage.setItem("axiotask:excludedLists", JSON.stringify(["L3"]));
      mockBackend([
        task("t1", "Excluded overdue", { due: daysFromNow(-2), list: "L3", listTitle: "Someday" }),
        task("t2", "Excluded no date", { due: null, list: "L3", listTitle: "Someday" }),
        task("t3", "Excluded upcoming", { due: daysFromNow(5), list: "L3", listTitle: "Someday" }),
      ]);

      // Check Focus
      localStorage.setItem("axiotask:view", "focus");
      const { unmount } = render(App);
      await waitFor(() => expect(screen.getByRole("button", { name: /★ Focus/i })).toBeInTheDocument());
      expect(screen.queryByText("Excluded overdue")).not.toBeInTheDocument();
      unmount();
    });
  });
});
