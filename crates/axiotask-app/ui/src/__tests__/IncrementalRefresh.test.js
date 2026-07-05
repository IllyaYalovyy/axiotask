import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

// #40: a single-list mutation must refetch only the affected list, not every
// list (the old loadAll() was O(n·lists) per action). This test would fail
// against the full-reload behavior.

function mkTask(id, listId, title) {
  return { id, parent_id: null, title, notes: null, status: "needsAction", due: null, position: "00001", sync_state: "clean", listId, listTitle: listId };
}

function mockBackend() {
  const lists = [{ id: "L1", title: "L1" }, { id: "L2", title: "L2" }, { id: "L3", title: "L3" }];
  let store = [mkTask("a", "L1", "Alpha"), mkTask("b", "L2", "Bravo"), mkTask("c", "L3", "Charlie")];
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return false;
      case "list_tasklists": return lists;
      case "list_tasks": return store.filter((t) => t.listId === args?.listId);
      case "delete_task": {
        const t = store.find((x) => x.id === args.id);
        store = store.filter((x) => x.id !== args.id);
        return t ? { id: t.id, list_id: t.listId, title: t.title, had_etag: false } : null;
      }
      default: return null;
    }
  });
}

describe("#40: incremental refresh", () => {
  beforeEach(() => {
    localStorage.clear();
    localStorage.setItem("axiotask:view", "L1"); // list view so a task is focused
    invoke.mockReset();
  });

  it("a single-list mutation refetches only that list, not all lists", async () => {
    mockBackend();
    render(App);
    await waitFor(() => expect(screen.getByText("Alpha")).toBeInTheDocument());

    const countFor = (id) =>
      invoke.mock.calls.filter((c) => c[0] === "list_tasks" && c[1]?.listId === id).length;
    const before = { L1: countFor("L1"), L2: countFor("L2"), L3: countFor("L3") };

    await fireEvent.keyDown(window, { key: "d" }); // delete the focused L1 task

    await waitFor(() => expect(countFor("L1")).toBe(before.L1 + 1));
    // The other lists must NOT be refetched.
    expect(countFor("L2")).toBe(before.L2);
    expect(countFor("L3")).toBe(before.L3);
  });
});
