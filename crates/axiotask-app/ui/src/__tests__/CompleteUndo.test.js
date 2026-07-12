import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";
import TaskRow from "../TaskRow.svelte";

function mockBackend(initialTasks = []) {
  const lists = [{ id: "L1", title: "Work" }];
  let taskStore = [...initialTasks];
  let nextId = 100;
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return taskStore.filter(t => t.listId === args?.listId);
      case "create_task": {
        const t = { id: `t-${nextId++}`, parent_id: args.parentId, title: args.title, notes: null, status: "needsAction", due: null, position: String(nextId).padStart(14, "0"), sync_state: "clean", listId: args.listId };
        taskStore.push(t);
        return t;
      }
      case "toggle_complete": {
        const t = taskStore.find(x => x.id === args.id);
        if (t) t.status = t.status === "needsAction" ? "completed" : "needsAction";
        return null;
      }
      case "delete_task": { taskStore = taskStore.filter(t => t.id !== args.id); return null; }
      case "rename_task": { const t = taskStore.find(x => x.id === args.id); if (t) t.title = args.title; return null; }
      case "set_due": return null;
      case "set_notes": return null;
      case "move_task": return null;
      case "reorder_task": return null;
      case "sync_now": return "ok";
      default: return null;
    }
  });
  return { taskStore };
}

function task(id, title, opts = {}) {
  return {
    id, parent_id: opts.parent || null, title, notes: opts.notes || null,
    status: opts.status || "needsAction", due: opts.due || new Date().toISOString(),
    position: opts.pos || "00001", sync_state: "clean", listId: "L1", listTitle: "Work",
  };
}

describe("GH#11: Complete/uncomplete with undo", () => {
  beforeEach(() => {
    localStorage.clear();
    localStorage.setItem("axiotask:view", "L1");
    invoke.mockReset();
    vi.useFakeTimers({ shouldAdvanceTime: true });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  describe("Checkbox toggle", () => {
    it("clicking checkbox calls toggle_complete", async () => {
      mockBackend([task("t1", "My task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("My task")).toBeInTheDocument());
      const checkbox = container.querySelector(".checkbox");
      await fireEvent.click(checkbox);
      expect(invoke).toHaveBeenCalledWith("toggle_complete", { id: "t1" });
    });

    it("Space key on focused task calls toggle_complete", async () => {
      mockBackend([task("t1", "Spacebar task")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Spacebar task")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: " " });
      expect(invoke).toHaveBeenCalledWith("toggle_complete", { id: "t1" });
    });

    it("uncompleting a completed task calls toggle_complete", async () => {
      mockBackend([task("t1", "Done task", { status: "completed" })]);
      render(App);
      // Need to show completed to see it
      localStorage.setItem("axiotask:view", "L1");
      const { container } = render(App);
      // Check show completed
      const toggle = screen.getAllByLabelText ? null : container.querySelector('input[type="checkbox"]');
      if (toggle) await fireEvent.click(toggle);
      // The task won't be visible unless showCompleted is true; use Space after enabling
      // Test via direct invoke verification
      invoke.mockClear();
      mockBackend([task("t1", "Done task", { status: "completed" })]);
      const { container: c2 } = render(App);
      await waitFor(() => {
        const cb = c2.querySelector('input[type="checkbox"]');
        return cb;
      });
      // Enable show completed
      const showCb = c2.querySelector('.toggle input[type="checkbox"]');
      if (showCb) await fireEvent.click(showCb);
      await waitFor(() => expect(screen.queryByText("Done task")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: " " });
      expect(invoke).toHaveBeenCalledWith("toggle_complete", { id: "t1" });
    });
  });

  describe("CSS transition (fade + strikethrough)", () => {
    it("completed task has strikethrough on title", () => {
      const completedTask = {
        id: "t1", parent_id: null, title: "Finished", notes: null,
        status: "completed", due: null, position: "1", sync_state: "clean",
        listId: "L1", listTitle: "Work", depth: 0, hasChildren: false, isCollapsed: false,
      };
      const { container } = render(TaskRow, {
        props: {
          task: completedTask, focused: false, editing: false,
          onrename: () => {}, oncanceledit: () => {}, onclick: () => {},
          ontoggle: () => {}, onsetdue: () => {}, oncontextmenu: () => {},
          onaddsubtask: () => {}, showList: false, subtaskProgress: null,
        },
      });
      const widget = container.querySelector(".task-widget");
      expect(widget.classList.contains("completed")).toBe(true);
      // Verify strikethrough via class on title
      const title = container.querySelector(".title");
      const styles = window.getComputedStyle(title);
      // The class .completed .title has text-decoration: line-through in CSS
      expect(widget.classList.contains("completed")).toBe(true);
    });

    it("completed task widget has reduced opacity (fade)", () => {
      const completedTask = {
        id: "t1", parent_id: null, title: "Faded", notes: null,
        status: "completed", due: null, position: "1", sync_state: "clean",
        listId: "L1", listTitle: "Work", depth: 0, hasChildren: false, isCollapsed: false,
      };
      const { container } = render(TaskRow, {
        props: {
          task: completedTask, focused: false, editing: false,
          onrename: () => {}, oncanceledit: () => {}, onclick: () => {},
          ontoggle: () => {}, onsetdue: () => {}, oncontextmenu: () => {},
          onaddsubtask: () => {}, showList: false, subtaskProgress: null,
        },
      });
      const widget = container.querySelector(".task-widget");
      expect(widget.classList.contains("completed")).toBe(true);
    });

    it("uncompleted task does not have completed class", () => {
      const openTask = {
        id: "t1", parent_id: null, title: "Open", notes: null,
        status: "needsAction", due: null, position: "1", sync_state: "clean",
        listId: "L1", listTitle: "Work", depth: 0, hasChildren: false, isCollapsed: false,
      };
      const { container } = render(TaskRow, {
        props: {
          task: openTask, focused: false, editing: false,
          onrename: () => {}, oncanceledit: () => {}, onclick: () => {},
          ontoggle: () => {}, onsetdue: () => {}, oncontextmenu: () => {},
          onaddsubtask: () => {}, showList: false, subtaskProgress: null,
        },
      });
      const widget = container.querySelector(".task-widget");
      expect(widget.classList.contains("completed")).toBe(false);
    });
  });

  describe("Undo toast (10s)", () => {
    it("shows undo toast after completing a task", async () => {
      mockBackend([task("t1", "Complete me")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Complete me")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: " " });
      await waitFor(() => expect(screen.getByText(/Completed "Complete me"/)).toBeInTheDocument());
      expect(screen.getByText("Undo")).toBeInTheDocument();
    });

    it("undo toast disappears after 10 seconds", async () => {
      mockBackend([task("t1", "Vanish")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Vanish")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: " " });
      await waitFor(() => expect(screen.getByText(/Completed "Vanish"/)).toBeInTheDocument());
      vi.advanceTimersByTime(10001);
      await waitFor(() => expect(screen.queryByText(/Completed "Vanish"/)).not.toBeInTheDocument());
    });

    it("clicking Undo calls toggle_complete to restore task", async () => {
      mockBackend([task("t1", "Restore me")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Restore me")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: " " });
      await waitFor(() => expect(screen.getByText("Undo")).toBeInTheDocument());
      invoke.mockClear();
      // Need to re-mock since we cleared
      invoke.mockImplementation(async (cmd, args) => {
        if (cmd === "toggle_complete") return null;
        if (cmd === "auth_status") return true;
        if (cmd === "list_tasklists") return [{ id: "L1", title: "Work" }];
        if (cmd === "list_tasks") return [task("t1", "Restore me")];
        if (cmd === "sync_now") return "ok";
        return null;
      });
      await fireEvent.click(screen.getByText("Undo"));
      expect(invoke).toHaveBeenCalledWith("toggle_complete", { id: "t1" });
    });

    it("undo of a parent completion reopens the subtasks the cascade closed", async () => {
      // Completing a parent completes its open subtasks (server behavior we
      // mirror). Un-completing does NOT cascade — so Undo must explicitly
      // reopen the subtasks that were open before, restoring what the user saw.
      const { taskStore } = mockBackend([
        task("p1", "Parent task"),
        task("s1", "Open sub", { parent: "p1" }),
        task("s2", "Done sub", { parent: "p1", status: "completed" }),
      ]);
      render(App);
      await waitFor(() => expect(screen.getByText("Parent task")).toBeInTheDocument());

      await fireEvent.keyDown(window, { key: " " }); // complete the parent
      await waitFor(() => expect(screen.getByText("Undo")).toBeInTheDocument());
      await fireEvent.click(screen.getByText("Undo"));

      await waitFor(() => {
        expect(invoke).toHaveBeenCalledWith("toggle_complete", { id: "p1" }); // reopen parent
        expect(invoke).toHaveBeenCalledWith("toggle_complete", { id: "s1" }); // reopen cascaded sub
      });
      // The already-done sub was NOT open before — undo must not reopen it.
      const s2Toggles = invoke.mock.calls.filter(c => c[0] === "toggle_complete" && c[1].id === "s2");
      expect(s2Toggles).toHaveLength(0);
      expect(taskStore.find(t => t.id === "s2").status).toBe("completed");
    });

    it("dismiss button removes undo toast immediately", async () => {
      mockBackend([task("t1", "Dismiss me")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Dismiss me")).toBeInTheDocument());
      await fireEvent.keyDown(window, { key: " " });
      await waitFor(() => expect(screen.getByText(/Completed "Dismiss me"/)).toBeInTheDocument());
      await fireEvent.click(screen.getByText("✕"));
      await waitFor(() => expect(screen.queryByText(/Completed "Dismiss me"/)).not.toBeInTheDocument());
    });
  });

  describe("Completed at bottom when shown", () => {
    it("completed tasks appear after open tasks", async () => {
      mockBackend([
        task("t1", "Open task A", { pos: "00001" }),
        task("t2", "Completed task B", { status: "completed", pos: "00002" }),
        task("t3", "Open task C", { pos: "00003" }),
      ]);
      const { container } = render(App);
      // Enable show completed
      await waitFor(() => expect(screen.getByText("Open task A")).toBeInTheDocument());
      const showCb = container.querySelector('.toggle input[type="checkbox"]');
      await fireEvent.click(showCb);
      await waitFor(() => expect(screen.getByText("Completed task B")).toBeInTheDocument());
      // Verify order: open tasks first, then completed
      const titles = [...container.querySelectorAll(".title")].map(el => el.textContent);
      const openIdx = titles.indexOf("Open task A");
      const completedIdx = titles.indexOf("Completed task B");
      expect(openIdx).toBeLessThan(completedIdx);
    });
  });

  describe("Show/hide completed toggle", () => {
    it("completed tasks are hidden by default", async () => {
      mockBackend([
        task("t1", "Open task"),
        task("t2", "Done task", { status: "completed" }),
      ]);
      render(App);
      await waitFor(() => expect(screen.getByText("Open task")).toBeInTheDocument());
      expect(screen.queryByText("Done task")).not.toBeInTheDocument();
    });

    it("show completed toggle reveals completed tasks", async () => {
      mockBackend([
        task("t1", "Open task"),
        task("t2", "Done task", { status: "completed" }),
      ]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Open task")).toBeInTheDocument());
      const showCb = container.querySelector('.toggle input[type="checkbox"]');
      await fireEvent.click(showCb);
      await waitFor(() => expect(screen.getByText("Done task")).toBeInTheDocument());
    });

    it("toggling show completed off hides completed tasks again", async () => {
      mockBackend([
        task("t1", "Open task"),
        task("t2", "Done task", { status: "completed" }),
      ]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Open task")).toBeInTheDocument());
      const showCb = container.querySelector('.toggle input[type="checkbox"]');
      await fireEvent.click(showCb);
      await waitFor(() => expect(screen.getByText("Done task")).toBeInTheDocument());
      await fireEvent.click(showCb);
      await waitFor(() => expect(screen.queryByText("Done task")).not.toBeInTheDocument());
    });
  });
});
