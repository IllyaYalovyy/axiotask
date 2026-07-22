import { render, screen, fireEvent, waitFor, within } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";
import pkg from "../../package.json";

const lists = [{ id: "L1", title: "Work" }];

function mockBackend(tasks = []) {
  let taskStore = [...tasks];
  let nextId = 200;
  // Stateful like the real backend: signing out flips auth_status. The UI
  // re-checks auth_status after auth_logout instead of assuming the outcome.
  let signedIn = true;
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return signedIn;
      case "auth_logout": signedIn = false; return null;
      case "list_tasklists": return lists;
      case "list_tasks": return taskStore.filter(t => t.listId === args?.listId);
      case "create_task": {
        const t = { id: `sub-${nextId++}`, parent_id: args.parentId, title: args.title, notes: null, status: "needsAction", due: null, position: "1", sync_state: "dirty", listId: args.listId, listTitle: "Work" };
        taskStore.push(t);
        return t;
      }
      case "rename_task": { const t = taskStore.find(x => x.id === args.id); if (t) t.title = args.title; return null; }
      case "set_notes": { const t = taskStore.find(x => x.id === args.id); if (t) t.notes = args.notes; return null; }
      case "set_due": {
        const t = taskStore.find(x => x.id === args.id);
        if (t) {
          if (args.mv === "Clear") t.due = null;
          else if (args.mv?.startsWith("raw:")) t.due = `${args.mv.slice(4)}T00:00:00.000Z`;
        }
        return null;
      }
      case "toggle_complete": { const t = taskStore.find(x => x.id === args.id); if (t) t.status = t.status === "needsAction" ? "completed" : "needsAction"; return null; }
      case "delete_task": { taskStore = taskStore.filter(t => t.id !== args.id); return null; }
      case "move_to_list": return null;
      case "sync_now": return "ok";
      case "fresh_sync": { taskStore = []; return "fresh sync: pulled=0"; }
      case "get_settings": return {
        version: pkg.version,
        instance: null,
        push_enabled: false,
        auto_sync_on_start: true,
        authenticated: signedIn,
        scopes: ["https://www.googleapis.com/auth/tasks"],
        db_path: "/tmp/axiotask.sqlite",
        config_path: "/tmp/config.toml",
        needs_reauth: false,
        pending_pushes: 0,
        sync: {
          last_synced: null,
          last_pulled: 0,
          last_pushed: 0,
          last_conflicts: 0,
          last_deleted: 0,
          total_syncs: 0,
          last_error: null,
        },
      };
      default: return null;
    }
  });
}

function task(id, title, opts = {}) {
  return { id, parent_id: opts.parent || null, title, notes: opts.notes || null, status: "needsAction", due: opts.due || null, position: opts.pos || "1", sync_state: "clean", listId: "L1", listTitle: "Work" };
}

describe("Detail Panel Workflows", () => {
  beforeEach(() => { localStorage.clear(); localStorage.setItem("axiotask:view", "L1"); invoke.mockReset(); });

  describe("UT-14: Create subtask from detail panel", () => {
    it("typing a subtask title and pressing Enter creates it named under the parent", async () => {
      mockBackend([task("t1", "Parent task")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Parent task")).toBeInTheDocument());

      // Open detail panel
      await fireEvent.click(screen.getByText("Parent task"));
      await waitFor(() => expect(screen.getByText("Task Details")).toBeInTheDocument());

      // Type a name into the inline field and press Enter.
      const input = screen.getByLabelText("New subtask");
      await fireEvent.input(input, { target: { value: "Buy milk" } });
      await fireEvent.keyDown(input, { key: "Enter" });

      // The subtask is created already named — no blank task, no debris.
      await waitFor(() => {
        expect(invoke).toHaveBeenCalledWith("create_task", expect.objectContaining({ parentId: "t1", title: "Buy milk" }));
      });
      // The panel stays on the parent (we did NOT navigate into a Subtask panel)…
      expect(screen.getByText("Task Details")).toBeInTheDocument();
      expect(screen.queryByText("Subtask", { exact: true })).not.toBeInTheDocument();
      expect(screen.getByLabelText("Title")).toHaveValue("Parent task");
      // …the new subtask shows up in the parent's checklist…
      await waitFor(() => expect(screen.getByText("Buy milk")).toBeInTheDocument());
      // …and the field is cleared and refocused for the next one.
      await waitFor(() => expect(screen.getByLabelText("New subtask")).toHaveValue(""));
      await waitFor(() => expect(screen.getByLabelText("New subtask")).toHaveFocus());
    });

    it("the + button adds the typed subtask", async () => {
      mockBackend([task("t1", "Parent task")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Parent task")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("Parent task"));
      await waitFor(() => expect(screen.getByText("Task Details")).toBeInTheDocument());

      const input = screen.getByLabelText("New subtask");
      await fireEvent.input(input, { target: { value: "Walk dog" } });
      await fireEvent.click(screen.getByRole("button", { name: "Add subtask" }));

      await waitFor(() => {
        expect(invoke).toHaveBeenCalledWith("create_task", expect.objectContaining({ parentId: "t1", title: "Walk dog" }));
      });
      await waitFor(() => expect(screen.getByText("Walk dog")).toBeInTheDocument());
    });

    it("an empty or whitespace-only field creates nothing (no Untitled debris)", async () => {
      mockBackend([task("t1", "Parent task")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Parent task")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("Parent task"));
      await waitFor(() => expect(screen.getByText("Task Details")).toBeInTheDocument());

      const input = screen.getByLabelText("New subtask");
      // Empty Enter.
      await fireEvent.keyDown(input, { key: "Enter" });
      // Whitespace + Enter.
      await fireEvent.input(input, { target: { value: "   " } });
      await fireEvent.keyDown(input, { key: "Enter" });
      // The + button is disabled with no real text, so it cannot create either.
      expect(screen.getByRole("button", { name: "Add subtask" })).toBeDisabled();

      await new Promise((resolve) => setTimeout(resolve, 30));
      const created = invoke.mock.calls.filter((c) => c[0] === "create_task");
      expect(created).toHaveLength(0);
      expect(screen.queryByText("Untitled")).not.toBeInTheDocument();
    });

    it("the list row exposes no add-subtask affordance (#91)", async () => {
      // Subtasks are added ONLY from the detail panel now; the list-row '+'
      // quick action and its blank-create flow are gone.
      mockBackend([task("t1", "Parent task")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Parent task")).toBeInTheDocument());

      // No '+' quick action anywhere in the row's action strip.
      expect(screen.queryByTitle("Add subtask")).not.toBeInTheDocument();
      const plus = [...container.querySelectorAll(".task-widget .actions button")].find(
        (b) => b.textContent.trim() === "+",
      );
      expect(plus).toBeUndefined();
      // And nothing was created by merely rendering the list.
      const created = invoke.mock.calls.filter((c) => c[0] === "create_task");
      expect(created).toHaveLength(0);
    });

    it("never auto-discards an untitled subtask that has children of its own", async () => {
      // Deleting it would silently take the whole subtree (server cascades),
      // and this path has no undo token.
      mockBackend([
        task("t1", "Parent task"),
        task("mid", "", { parent: "t1" }),
        task("leaf", "Grandchild work", { parent: "mid" }),
      ]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Parent task")).toBeInTheDocument());

      // Open the untitled middle subtask in the panel, then close it untouched.
      await fireEvent.click(screen.getByText("Parent task"));
      await waitFor(() => expect(screen.getByText("Task Details")).toBeInTheDocument());
      await fireEvent.click(container.querySelector(".detail-panel .subtask-title"));
      await waitFor(() => expect(screen.getByText("Subtask")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("✕"));

      await new Promise((resolve) => setTimeout(resolve, 50));
      expect(invoke).not.toHaveBeenCalledWith("delete_task", expect.anything());
      // Reopen the parent — the untitled middle subtask (which has a child of
      // its own) survived and is still listed in the parent's checklist.
      await fireEvent.click(screen.getByText("Parent task"));
      await waitFor(() => expect(screen.getByText("Subtasks")).toBeInTheDocument());
      expect(container.querySelector(".detail-panel .subtask-title")).toBeInTheDocument();
    });
  });

  describe("UT-36: Auto-save on close", () => {
    it("closing panel with Escape saves edited title", async () => {
      mockBackend([task("t1", "Original title")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Original title")).toBeInTheDocument());

      // Open detail panel
      await fireEvent.click(screen.getByText("Original title"));
      await waitFor(() => expect(screen.getByText("Task Details")).toBeInTheDocument());

      // Edit title
      const titleInput = screen.getByLabelText("Title");
      await fireEvent.input(titleInput, { target: { value: "New title" } });

      // Press Escape to close
      const panel = container.querySelector(".detail-panel");
      await fireEvent.keyDown(panel, { key: "Escape" });

      // Should have called rename_task
      await waitFor(() => {
        expect(invoke).toHaveBeenCalledWith("rename_task", { id: "t1", title: "New title" });
      });
    });

    it("auto-saves edited title on blur without pressing Save", async () => {
      mockBackend([task("t1", "Original title")]);
      render(App);
      await waitFor(() => expect(screen.getByText("Original title")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("Original title"));
      await waitFor(() => expect(screen.getByText("Task Details")).toBeInTheDocument());

      const titleInput = screen.getByLabelText("Title");
      await fireEvent.input(titleInput, { target: { value: "Blur saved title" } });
      await fireEvent.blur(titleInput);

      await waitFor(() => {
        expect(invoke).toHaveBeenCalledWith("rename_task", { id: "t1", title: "Blur saved title" });
      });
    });
  });

  describe("The open panel tracks the task it is showing", () => {
    it("renaming a task inline updates the title in the open panel", async () => {
      mockBackend([task("t1", "Old name")]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Old name")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("Old name"));
      await waitFor(() => expect(screen.getByLabelText("Title")).toHaveValue("Old name"));

      // Rename inline (double-click the title → edit input → Enter).
      await fireEvent.dblClick(container.querySelector(".title"));
      await waitFor(() => expect(container.querySelector(".edit-input")).toBeTruthy());
      const inline = container.querySelector(".edit-input");
      await fireEvent.input(inline, { target: { value: "New name" } });
      await fireEvent.keyDown(inline, { key: "Enter" });

      await waitFor(() => expect(screen.getByLabelText("Title")).toHaveValue("New name"));
    });

    it("a refresh of the shown task does not clobber what the user is typing", async () => {
      mockBackend([task("t1", "Original", { pos: "1" }), task("t2", "Other", { pos: "2" })]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("Original")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("Original"));
      await waitFor(() => expect(screen.getByLabelText("Title")).toHaveValue("Original"));

      const titleInput = screen.getByLabelText("Title");
      await fireEvent.input(titleInput, { target: { value: "Half-typed" } });

      // Completing the *other* task reloads the store while the panel is open.
      const otherRow = [...container.querySelectorAll(".task-widget")]
        .find(el => el.textContent.includes("Other"));
      await fireEvent.click(otherRow.querySelector(".checkbox"));
      await waitFor(() => expect(invoke).toHaveBeenCalledWith("toggle_complete", { id: "t2" }));

      expect(screen.getByLabelText("Title")).toHaveValue("Half-typed");
    });

    it("panel ‹ › navigation moves the focused row in the list", async () => {
      mockBackend([task("t1", "First", { pos: "1" }), task("t2", "Second", { pos: "2" })]);
      const { container } = render(App);
      await waitFor(() => expect(screen.getByText("First")).toBeInTheDocument());

      await fireEvent.click(screen.getByText("First"));
      await waitFor(() => expect(screen.getByLabelText("Title")).toHaveValue("First"));
      expect(container.querySelector(".task-widget.focused .title")).toHaveTextContent("First");

      await fireEvent.click(screen.getByTitle("Next (→)"));

      await waitFor(() => expect(screen.getByLabelText("Title")).toHaveValue("Second"));
      expect(container.querySelector(".task-widget.focused .title")).toHaveTextContent("Second");
    });
  });

  describe("UT-38: Reschedule to today (o key)", () => {
    it("pressing o on focused task calls set_due with Today", async () => {
      mockBackend([task("t1", "My task")]);
      render(App);
      await waitFor(() => expect(screen.getByText("My task")).toBeInTheDocument());

      await fireEvent.keyDown(window, { key: "o" });

      await waitFor(() => {
        expect(invoke).toHaveBeenCalledWith("set_due", { id: "t1", mv: "Today" });
      });
    });
  });
});

describe("UT-04: Sign out", () => {
  beforeEach(() => { localStorage.clear(); localStorage.setItem("axiotask:view", "L1"); invoke.mockReset(); });

  it("clicking Sign out calls auth_logout and shows Sign in button", async () => {
    mockBackend([task("t1", "Test")]);
    render(App);
    await waitFor(() => expect(screen.getByRole("button", { name: /sync now/i })).toBeInTheDocument());

    // Click sign out
    await fireEvent.click(screen.getByText("Sign out"));

    await waitFor(() => {
      expect(invoke).toHaveBeenCalledWith("auth_logout", {});
    });
    // Should show sign-in button again
    await waitFor(() => expect(screen.getByText(/Sign in with Google/)).toBeInTheDocument());
  });
});

describe("UT-03: Fresh sync", () => {
  beforeEach(() => { localStorage.clear(); localStorage.setItem("axiotask:view", "L1"); invoke.mockReset(); });

  it("clicking Fresh sync calls fresh_sync after confirmation", async () => {
    mockBackend([task("t1", "Local task")]);
    const confirmSpy = vi.spyOn(window, "confirm");
    render(App);
    await waitFor(() => expect(screen.getByText("Local task")).toBeInTheDocument());

    await fireEvent.click(screen.getByRole("button", { name: /properties/i }));
    const dialog = await screen.findByRole("dialog", { name: /properties/i });

    await fireEvent.click(within(dialog).getByRole("button", { name: /fresh sync/i }));
    expect(confirmSpy).not.toHaveBeenCalled();
    const alert = await screen.findByRole("alertdialog", { name: /fresh sync/i });
    expect(alert).toBeInTheDocument();
    await fireEvent.click(within(alert).getByRole("button", { name: /^fresh sync$/i }));

    await waitFor(() => {
      const freshCalls = invoke.mock.calls.filter(c => c[0] === "fresh_sync");
      expect(freshCalls.length).toBe(1);
    });
    expect(dialog).toBeInTheDocument();
    confirmSpy.mockRestore();
  });

  it("does not call fresh_sync if user cancels confirmation", async () => {
    mockBackend([task("t1", "Local task")]);
    const confirmSpy = vi.spyOn(window, "confirm");
    render(App);
    await waitFor(() => expect(screen.getByText("Local task")).toBeInTheDocument());
    await fireEvent.click(screen.getByRole("button", { name: /properties/i }));
    await screen.findByRole("dialog", { name: /properties/i });

    await fireEvent.click(screen.getByRole("button", { name: /fresh sync/i }));
    await fireEvent.click(await screen.findByRole("button", { name: /cancel/i }));

    expect(confirmSpy).not.toHaveBeenCalled();
    const freshCalls = invoke.mock.calls.filter(c => c[0] === "fresh_sync");
    expect(freshCalls).toHaveLength(0);
    confirmSpy.mockRestore();
  });
});
