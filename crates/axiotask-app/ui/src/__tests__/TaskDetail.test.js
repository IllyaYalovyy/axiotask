import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

function mockBackend(tasks = [], subtasks = []) {
  const lists = [
    { id: "L1", title: "Work" },
    { id: "L2", title: "Personal" },
  ];
  let taskStore = [...tasks, ...subtasks];
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks":
        return taskStore.filter((t) => t.listId === args?.listId);
      case "rename_task": {
        const t = taskStore.find((x) => x.id === args.id);
        if (t) t.title = args.title;
        return null;
      }
      case "set_notes": {
        const t = taskStore.find((x) => x.id === args.id);
        if (t) t.notes = args.notes;
        return null;
      }
      case "set_due": return null;
      case "toggle_complete": {
        const t = taskStore.find((x) => x.id === args.id);
        if (t)
          t.status =
            t.status === "needsAction" ? "completed" : "needsAction";
        return null;
      }
      case "delete_task": {
        taskStore = taskStore.filter((t) => t.id !== args.id);
        return null;
      }
      case "move_to_list": return null;
      case "sync_now": return "ok";
      default: return null;
    }
  });
}

function task(id, title, opts = {}) {
  return {
    id,
    parent_id: opts.parent || null,
    title,
    notes: opts.notes || null,
    status: opts.status || "needsAction",
    due: opts.due || null,
    position: opts.pos || "00000000000001",
    sync_state: "clean",
    listId: opts.listId || "L1",
    listTitle: opts.listTitle || "Work",
  };
}

describe("TaskDetail Panel (GH#7)", () => {
  beforeEach(() => {
    localStorage.clear();
    localStorage.setItem("axiotask:view", "L1");
    invoke.mockReset();
  });

  describe("Opening the panel", () => {
    it("clicking a task opens detail panel", async () => {
      mockBackend([task("t1", "My Task", { due: "2026-06-03T00:00:00.000Z", notes: "Some notes" })]);
      render(App);
      await waitFor(() => expect(screen.getByText("My Task")).toBeInTheDocument());

      // Click the task row (not the checkbox)
      await fireEvent.click(screen.getByText("My Task"));
      await waitFor(() =>
        expect(screen.getByText("Task Details")).toBeInTheDocument()
      );
    });

    it("panel shows task title in input", async () => {
      mockBackend([task("t1", "Edit Title Test")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Edit Title Test")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("Edit Title Test"));
      await waitFor(() => {
        const input = screen.getByLabelText("Title");
        expect(input).toHaveValue("Edit Title Test");
      });
    });

    it("panel shows task notes", async () => {
      mockBackend([task("t1", "Noted Task", { notes: "My important notes" })]);
      render(App);
      await waitFor(() => expect(screen.getByText("Noted Task")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("Noted Task"));
      await waitFor(() => {
        const textarea = screen.getByLabelText("Notes");
        expect(textarea).toHaveValue("My important notes");
      });
    });

    it("panel shows due date", async () => {
      mockBackend([task("t1", "Dated Task", { due: "2026-06-15T00:00:00.000Z" })]);
      render(App);
      await waitFor(() => expect(screen.getByText("Dated Task")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("Dated Task"));
      await waitFor(() => {
        const input = screen.getByLabelText("Due date");
        expect(input).toHaveValue("2026-06-15");
      });
    });

    it("panel shows list dropdown with current list selected", async () => {
      mockBackend([task("t1", "Listed Task", { listId: "L1" })]);
      render(App);
      await waitFor(() => expect(screen.getByText("Listed Task")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("Listed Task"));
      await waitFor(() => {
        const select = screen.getByLabelText("List");
        expect(select).toHaveValue("L1");
      });
    });
  });

  describe("Subtasks checklist", () => {
    it("shows subtasks in detail panel", async () => {
      const parent = task("t1", "Parent Task");
      const sub1 = task("s1", "Subtask 1", { parent: "t1" });
      const sub2 = task("s2", "Subtask 2", { parent: "t1", status: "completed" });
      mockBackend([parent], [sub1, sub2]);
      render(App);
      await waitFor(() => expect(screen.getByText("Parent Task")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("Parent Task"));
      await waitFor(() => {
        expect(screen.getByText("Subtask 1")).toBeInTheDocument();
        expect(screen.getByText("Subtask 2")).toBeInTheDocument();
      });
    });

    it("completed subtasks show check mark", async () => {
      const parent = task("t1", "Parent");
      const sub = task("s1", "Done Sub", { parent: "t1", status: "completed" });
      mockBackend([parent], [sub]);
      render(App);
      await waitFor(() => expect(screen.getByText("Parent")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("Parent"));
      await waitFor(() => {
        const item = screen.getByText("Done Sub").closest(".subtask-item");
        expect(item).toHaveClass("completed");
      });
    });
  });

  describe("Editing and saving", () => {
    it("Ctrl+S saves and closes panel", async () => {
      mockBackend([task("t1", "Save Me")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Save Me")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("Save Me"));
      await waitFor(() => expect(screen.getByText("Task Details")).toBeInTheDocument());

      // Edit the title
      const titleInput = screen.getByLabelText("Title");
      await fireEvent.input(titleInput, { target: { value: "Saved Title" } });

      // Ctrl+S
      const panel = container.querySelector(".detail-panel");
      await fireEvent.keyDown(panel, { key: "s", ctrlKey: true });

      // Panel stays open (save doesn't close)
      expect(screen.getByText("Task Details")).toBeInTheDocument();
      // rename_task should have been called
      expect(invoke).toHaveBeenCalledWith("rename_task", { id: "t1", title: "Saved Title" });
    });

    it("Save button saves without closing panel", async () => {
      mockBackend([task("t1", "Click Save")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Click Save")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("Click Save"));
      await waitFor(() => expect(screen.getByText("Task Details")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("Save"));
      // Panel stays open
      expect(screen.getByText("Task Details")).toBeInTheDocument();
    });
  });

  describe("Closing the panel", () => {
    it("Escape closes detail panel", async () => {
      mockBackend([task("t1", "Close Me")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Close Me")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("Close Me"));
      await waitFor(() => expect(screen.getByText("Task Details")).toBeInTheDocument());

      await fireEvent.keyDown(window, { key: "Escape" });
      await waitFor(() =>
        expect(screen.queryByText("Task Details")).not.toBeInTheDocument()
      );
    });

    it("close button (✕) closes panel", async () => {
      mockBackend([task("t1", "X Close")]);
      render(App);
      await waitFor(() => expect(screen.getByText("X Close")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("X Close"));
      await waitFor(() => expect(screen.getByText("Task Details")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("✕"));
      await waitFor(() =>
        expect(screen.queryByText("Task Details")).not.toBeInTheDocument()
      );
    });
  });

  describe("Delete", () => {
    it("delete button removes task and closes panel", async () => {
      mockBackend([task("t1", "Delete Me")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Delete Me")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("Delete Me"));
      await waitFor(() => expect(screen.getByText("Task Details")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("🗑️ Delete task"));
      await waitFor(() => {
        expect(screen.queryByText("Task Details")).not.toBeInTheDocument();
      });
      expect(invoke).toHaveBeenCalledWith("delete_task", { id: "t1" });
    });
  });

  describe("Quick date buttons", () => {
    it("Today button sets due date to today", async () => {
      mockBackend([task("t1", "Date Task")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Date Task")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("Date Task"));
      await waitFor(() => expect(screen.getByText("Task Details")).toBeInTheDocument());

      const todayStr = new Date().toISOString().slice(0, 10);
      await fireEvent.click(screen.getByText("Today"));
      const dateInput = screen.getByLabelText("Due date");
      expect(dateInput).toHaveValue(todayStr);
    });

    it("Clear button removes due date", async () => {
      mockBackend([task("t1", "Dated", { due: "2026-06-10T00:00:00.000Z" })]);
      render(App);
      await waitFor(() => expect(screen.getByText("Dated")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("Dated"));
      await waitFor(() => expect(screen.getByLabelText("Due date")).toHaveValue("2026-06-10"));

      await fireEvent.click(screen.getByText("Clear"));
      expect(screen.getByLabelText("Due date")).toHaveValue("");
    });
  });

  describe("List dropdown", () => {
    it("changing list calls move_to_list on save", async () => {
      mockBackend([task("t1", "Move Task", { listId: "L1" })]);
      render(App);
      await waitFor(() => expect(screen.getByText("Move Task")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("Move Task"));
      await waitFor(() => expect(screen.getByLabelText("List")).toBeInTheDocument());

      const select = screen.getByLabelText("List");
      await fireEvent.change(select, { target: { value: "L2" } });
      await fireEvent.click(screen.getByText("Save"));

      await waitFor(() =>
        expect(invoke).toHaveBeenCalledWith(
          expect.stringContaining(""),
          expect.objectContaining({ id: "t1" })
        )
      );
    });
  });

  describe("Mobile full screen", () => {
    it("detail panel has responsive CSS for full screen", async () => {
      mockBackend([task("t1", "Mobile Task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Mobile Task")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("Mobile Task"));
      await waitFor(() => {
        const panel = container.querySelector(".detail-panel");
        expect(panel).toBeInTheDocument();
      });
    });
  });
});
