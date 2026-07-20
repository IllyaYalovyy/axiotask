import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import { emitMockEvent } from "../test-setup.js";
import App from "../App.svelte";

function task(id, title) {
  return {
    id,
    parent_id: null,
    title,
    notes: null,
    status: "needsAction",
    due: new Date().toISOString(),
    position: "00001",
    sync_state: "clean",
    listId: "L1",
    listTitle: "Work",
  };
}

function mockBackend(initialTasks = []) {
  const lists = [{ id: "L1", title: "Work" }];
  let taskStore = [...initialTasks];

  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status":
        return true;
      case "list_tasklists":
        return lists;
      case "list_tasks":
        return taskStore.filter((t) => t.listId === args?.listId);
      case "delete_task": {
        const t = taskStore.find((x) => x.id === args.id);
        taskStore = taskStore.filter((x) => x.id !== args.id);
        return t ? {
          id: t.id,
          list_id: t.listId,
          parent_id: t.parent_id,
          title: t.title,
          notes: t.notes,
          status: t.status,
          due: t.due,
          position: t.position,
          had_etag: true,
        } : null;
      }
      case "sync_now":
        return "ok";
      default:
        return null;
    }
  });
}

describe("GH#70: Toast stack", () => {
  beforeEach(() => {
    localStorage.clear();
    localStorage.setItem("axiotask:view", "L1");
    invoke.mockReset();
    vi.useFakeTimers({ shouldAdvanceTime: true });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("stacks a sync error toast with an undo toast so Undo remains reachable", async () => {
    mockBackend([task("t1", "Stack me")]);
    const { container } = render(App);
    await waitFor(() => expect(screen.getByText("Stack me")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: "d" });
    await waitFor(() => expect(screen.getByText(/Deleted "Stack me"/)).toBeInTheDocument());

    emitMockEvent("sync-updated", {
      last_synced: null,
      last_error: "network error",
      last_conflicts: 0,
      needs_reauth: false,
    });
    await waitFor(() => expect(screen.getByText("Sync failed: network error")).toBeInTheDocument());

    const stack = container.querySelector(".toast-stack");
    expect(stack).toBeInTheDocument();
    expect(stack.querySelectorAll(".toast")).toHaveLength(2);
    expect(stack).toContainElement(screen.getByRole("button", { name: "Undo" }));
  });
});
