import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

function mockBackend(initialTasks = []) {
  const lists = [{ id: "L1", title: "Work" }];
  let taskStore = [...initialTasks];
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return taskStore.filter(t => t.listId === args?.listId);
      case "clear_completed": {
        const before = taskStore.length;
        taskStore = taskStore.filter(t => !(t.listId === args.listId && t.status === "completed"));
        return before - taskStore.length;
      }
      case "sync_now": return "ok";
      default: return null;
    }
  });
  return { taskStore };
}

function task(id, title, opts = {}) {
  return {
    id, parent_id: null, title, notes: null,
    status: opts.status || "needsAction", due: opts.due || null,
    position: opts.pos || "00001", sync_state: "clean", listId: "L1", listTitle: "Work",
  };
}

describe("GH#31: Clear completed tasks", () => {
  beforeEach(() => {
    localStorage.clear();
    localStorage.setItem("axiotask:view", "L1");
    invoke.mockReset();
    vi.useFakeTimers({ shouldAdvanceTime: true });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  describe("Button visibility", () => {
    it("Clear completed button is hidden when showCompleted is off", async () => {
      mockBackend([
        task("t1", "Open task"),
        task("t2", "Done task", { status: "completed" }),
      ]);
      render(App);
      await waitFor(() => expect(screen.getByText("Open task")).toBeInTheDocument());
      expect(screen.queryByRole("button", { name: /clear completed/i })).not.toBeInTheDocument();
    });

    it("Clear completed button appears when showCompleted is on and viewing a list", async () => {
      mockBackend([
        task("t1", "Open task"),
        task("t2", "Done task", { status: "completed" }),
      ]);
      render(App);
      await waitFor(() => expect(screen.getByText("Open task")).toBeInTheDocument());
      // Toggle show completed
      const toggle = screen.getByLabelText(/show completed/i);
      await fireEvent.click(toggle);
      await waitFor(() => expect(screen.getByText("Done task")).toBeInTheDocument());
      expect(screen.getByRole("button", { name: /clear completed/i })).toBeInTheDocument();
    });

    it("Clear completed button is hidden on smart views", async () => {
      mockBackend([
        task("t1", "Open task", { due: new Date().toISOString() }),
        task("t2", "Done task", { status: "completed", due: new Date().toISOString() }),
      ]);
      localStorage.setItem("axiotask:view", "focus");
      render(App);
      await waitFor(() => expect(screen.getByText("Open task")).toBeInTheDocument());
      const toggle = screen.getByLabelText(/show completed/i);
      await fireEvent.click(toggle);
      await waitFor(() => expect(screen.getByText("Done task")).toBeInTheDocument());
      expect(screen.queryByRole("button", { name: /clear completed/i })).not.toBeInTheDocument();
    });
  });

  describe("Confirmation dialog", () => {
    it("shows confirmation dialog when clicking Clear completed", async () => {
      mockBackend([
        task("t1", "Open task"),
        task("t2", "Done task", { status: "completed" }),
        task("t3", "Also done", { status: "completed" }),
      ]);
      render(App);
      await waitFor(() => expect(screen.getByText("Open task")).toBeInTheDocument());
      const toggle = screen.getByLabelText(/show completed/i);
      await fireEvent.click(toggle);
      await waitFor(() => expect(screen.getByText("Done task")).toBeInTheDocument());

      const clearBtn = screen.getByRole("button", { name: /clear completed/i });
      await fireEvent.click(clearBtn);

      // Confirmation dialog should appear with count
      await waitFor(() => {
        expect(screen.getByText(/delete 2 completed/i)).toBeInTheDocument();
      });
    });

    it("canceling confirmation does not delete tasks", async () => {
      mockBackend([
        task("t1", "Open task"),
        task("t2", "Done task", { status: "completed" }),
      ]);
      render(App);
      await waitFor(() => expect(screen.getByText("Open task")).toBeInTheDocument());
      const toggle = screen.getByLabelText(/show completed/i);
      await fireEvent.click(toggle);
      await waitFor(() => expect(screen.getByText("Done task")).toBeInTheDocument());

      const clearBtn = screen.getByRole("button", { name: /clear completed/i });
      await fireEvent.click(clearBtn);
      await waitFor(() => expect(screen.getByText(/delete 1 completed/i)).toBeInTheDocument());

      // Click Cancel
      const cancelBtn = screen.getByRole("button", { name: /cancel/i });
      await fireEvent.click(cancelBtn);

      // Dialog should close, task still there
      await waitFor(() => expect(screen.queryByText(/delete 1 completed/i)).not.toBeInTheDocument());
      expect(screen.getByText("Done task")).toBeInTheDocument();
      expect(invoke).not.toHaveBeenCalledWith("clear_completed", expect.anything());
    });

    it("confirming deletes completed tasks", async () => {
      mockBackend([
        task("t1", "Open task"),
        task("t2", "Done task", { status: "completed" }),
        task("t3", "Also done", { status: "completed" }),
      ]);
      render(App);
      await waitFor(() => expect(screen.getByText("Open task")).toBeInTheDocument());
      const toggle = screen.getByLabelText(/show completed/i);
      await fireEvent.click(toggle);
      await waitFor(() => expect(screen.getByText("Done task")).toBeInTheDocument());

      const clearBtn = screen.getByRole("button", { name: /clear completed/i });
      await fireEvent.click(clearBtn);
      await waitFor(() => expect(screen.getByText(/delete 2 completed/i)).toBeInTheDocument());

      // Confirm
      const confirmBtn = screen.getByRole("button", { name: /^delete$/i });
      await fireEvent.click(confirmBtn);

      // Tasks should be removed
      await waitFor(() => {
        expect(invoke).toHaveBeenCalledWith("clear_completed", { listId: "L1" });
      });
      await waitFor(() => {
        expect(screen.queryByText("Done task")).not.toBeInTheDocument();
        expect(screen.queryByText("Also done")).not.toBeInTheDocument();
      });
      expect(screen.getByText("Open task")).toBeInTheDocument();
    });

    it("Escape closes confirmation dialog", async () => {
      mockBackend([
        task("t1", "Open task"),
        task("t2", "Done task", { status: "completed" }),
      ]);
      render(App);
      await waitFor(() => expect(screen.getByText("Open task")).toBeInTheDocument());
      const toggle = screen.getByLabelText(/show completed/i);
      await fireEvent.click(toggle);
      await waitFor(() => expect(screen.getByText("Done task")).toBeInTheDocument());

      const clearBtn = screen.getByRole("button", { name: /clear completed/i });
      await fireEvent.click(clearBtn);
      await waitFor(() => expect(screen.getByText(/delete 1 completed/i)).toBeInTheDocument());

      // Press Escape
      await fireEvent.keyDown(window, { key: "Escape" });

      await waitFor(() => expect(screen.queryByText(/delete 1 completed/i)).not.toBeInTheDocument());
      expect(invoke).not.toHaveBeenCalledWith("clear_completed", expect.anything());
    });
  });
});
