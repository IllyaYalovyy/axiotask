import { render, screen, fireEvent, waitFor, within } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

const lists = [
  { id: "L1", title: "Work" },
  { id: "L2", title: "Home" },
];

function task(id, title, status = "needsAction") {
  return { id, parent_id: null, title, notes: null, status, due: null, position: id, sync_state: "clean", listId: "L1", listTitle: "Work" };
}

function mockBackend(tasks) {
  let store = [...tasks];
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return store.filter((t) => t.listId === args?.listId);
      case "toggle_complete": {
        const t = store.find((x) => x.id === args.id);
        if (t) t.status = t.status === "completed" ? "needsAction" : "completed";
        return null;
      }
      case "delete_task": {
        store = store.filter((t) => t.id !== args.id);
        return { id: args.id, list_id: "L1", title: "x", had_etag: false };
      }
      case "set_due": return null;
      case "move_to_list": return null;
      case "sync_now": return "ok";
      default: return null;
    }
  });
}

async function setup() {
  localStorage.setItem("axiotask:view", "L1");
  mockBackend([task("t1", "Alpha"), task("t2", "Beta"), task("t3", "Gamma")]);
  render(App);
  await waitFor(() => expect(screen.getByText("Alpha")).toBeInTheDocument());
}

// Select the first N tasks by focusing each and pressing 'x'.
async function selectFirst(n) {
  for (let i = 0; i < n; i++) {
    // focus moves down with j; start at index 0
    if (i > 0) await fireEvent.keyDown(window, { key: "j" });
    await fireEvent.keyDown(window, { key: "x" });
  }
}

function bulkBar() {
  return document.querySelector(".bulk-bar");
}

describe("Bulk operations", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });

  it("pressing x selects a task and shows the bulk bar with a count", async () => {
    await setup();
    await fireEvent.keyDown(window, { key: "x" });
    await waitFor(() => expect(bulkBar()).toBeTruthy());
    expect(bulkBar().textContent).toMatch(/1 selected/);
  });

  it("Ctrl/Cmd-click on a row selects it", async () => {
    await setup();
    await fireEvent.click(screen.getByText("Beta"), { ctrlKey: true });
    await waitFor(() => expect(bulkBar()?.textContent).toMatch(/1 selected/));
  });

  it("Esc clears the selection", async () => {
    await setup();
    await fireEvent.keyDown(window, { key: "x" });
    await waitFor(() => expect(bulkBar()).toBeTruthy());
    await fireEvent.keyDown(window, { key: "Escape" });
    await waitFor(() => expect(bulkBar()).toBeFalsy());
  });

  it("bulk Complete marks all selected tasks complete", async () => {
    await setup();
    await selectFirst(2); // Alpha, Beta
    await fireEvent.click(screen.getByRole("button", { name: /complete/i }));
    await waitFor(() => {
      const calls = invoke.mock.calls.filter((c) => c[0] === "toggle_complete");
      expect(calls.map((c) => c[1].id).sort()).toEqual(["t1", "t2"]);
    });
    // Selection cleared afterwards.
    await waitFor(() => expect(bulkBar()).toBeFalsy());
  });

  it("bulk Delete deletes all selected tasks", async () => {
    await setup();
    await selectFirst(2);
    await fireEvent.click(screen.getByRole("button", { name: /delete/i }));
    await waitFor(() => {
      const calls = invoke.mock.calls.filter((c) => c[0] === "delete_task");
      expect(calls.map((c) => c[1].id).sort()).toEqual(["t1", "t2"]);
    });
  });

  it("the 't' key reschedules the whole selection to tomorrow", async () => {
    await setup();
    await selectFirst(3);
    await fireEvent.keyDown(window, { key: "t" });
    await waitFor(() => {
      const calls = invoke.mock.calls.filter((c) => c[0] === "set_due");
      expect(calls.length).toBe(3);
      expect(calls.every((c) => c[1].mv === "Tomorrow")).toBe(true);
    });
  });

  it("bulk Move sends all selected to the chosen list", async () => {
    await setup();
    await selectFirst(2);
    await fireEvent.click(screen.getByRole("button", { name: /move/i }));
    // Move-to-list picker lists the other list — click it inside the dialog.
    const picker = await screen.findByRole("dialog", { name: /move to list/i });
    await fireEvent.click(within(picker).getByText("Home"));
    await waitFor(() => {
      const calls = invoke.mock.calls.filter((c) => c[0] === "move_to_list");
      expect(calls.map((c) => c[1].id).sort()).toEqual(["t1", "t2"]);
      expect(calls.every((c) => c[1].targetListId === "L2")).toBe(true);
    });
  });
});
