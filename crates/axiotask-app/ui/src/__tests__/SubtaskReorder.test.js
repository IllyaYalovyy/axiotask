import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

// A backend that actually reorders siblings on `reorder_task`, so tests can
// assert the USER-VISIBLE order in the panel — not merely that a command fired.
function mockBackend(tasks = [], subtasks = []) {
  const lists = [{ id: "L1", title: "Work" }];
  let taskStore = [...tasks, ...subtasks];
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status":
        return true;
      case "list_tasklists":
        return lists;
      case "list_tasks":
        return taskStore.filter((t) => t.listId === args?.listId);
      case "toggle_complete": {
        const t = taskStore.find((x) => x.id === args.id);
        if (t) t.status = t.status === "needsAction" ? "completed" : "needsAction";
        return null;
      }
      case "reorder_task": {
        // Swap the task with its adjacent sibling (same parent + list) in
        // store order — mirroring reorder_task_inner's single-step swap.
        const cur = taskStore.find((t) => t.id === args.id);
        if (!cur) return null;
        const sibStoreIdx = taskStore
          .map((t, i) => ({ t, i }))
          .filter(({ t }) => (t.parent_id ?? null) === (cur.parent_id ?? null) && t.listId === cur.listId)
          .map(({ i }) => i);
        const pos = sibStoreIdx.findIndex((i) => taskStore[i].id === args.id);
        const swapPos = args.direction === "up" ? pos - 1 : pos + 1;
        if (swapPos < 0 || swapPos >= sibStoreIdx.length) return null;
        const a = sibStoreIdx[pos];
        const b = sibStoreIdx[swapPos];
        [taskStore[a], taskStore[b]] = [taskStore[b], taskStore[a]];
        return null;
      }
      case "sync_now":
        return "ok";
      default:
        return null;
    }
  });
}

function task(id, title, opts = {}) {
  return {
    id,
    parent_id: opts.parent || null,
    title,
    notes: null,
    status: opts.status || "needsAction",
    due: opts.due || null,
    position: opts.pos || "00000000000001",
    sync_state: "clean",
    listId: "L1",
    listTitle: "Work",
  };
}

function subtaskOrder() {
  return [...document.querySelectorAll(".subtask-item .subtask-title")].map((e) => e.textContent);
}

async function openParent() {
  render(App);
  await waitFor(() => expect(screen.getByText("Parent")).toBeInTheDocument());
  await fireEvent.click(screen.getByText("Parent"));
  await waitFor(() => expect(screen.getByText("Task Details")).toBeInTheDocument());
}

function itemFor(title) {
  return screen.getByText(title).closest(".subtask-item");
}

describe("Subtask drag-reorder (#90)", () => {
  beforeEach(() => {
    localStorage.clear();
    localStorage.setItem("axiotask:view", "L1");
    invoke.mockReset();
  });

  it("dragging a subtask above another reorders it in the panel", async () => {
    mockBackend(
      [task("t1", "Parent")],
      [
        task("s1", "Alpha", { parent: "t1", pos: "1" }),
        task("s2", "Beta", { parent: "t1", pos: "2" }),
        task("s3", "Gamma", { parent: "t1", pos: "3" }),
      ],
    );
    await openParent();
    expect(subtaskOrder()).toEqual(["Alpha", "Beta", "Gamma"]);

    // Drag Gamma onto Alpha (move to the top).
    await fireEvent.dragStart(itemFor("Gamma"));
    await fireEvent.dragOver(itemFor("Alpha"));
    await fireEvent.drop(itemFor("Alpha"));

    await waitFor(() => expect(subtaskOrder()).toEqual(["Gamma", "Alpha", "Beta"]));
  });

  it("reorders correctly across a hidden completed subtask (hide-completed on)", async () => {
    mockBackend(
      [task("t1", "Parent")],
      [
        task("s1", "Alpha", { parent: "t1", pos: "1" }),
        task("s2", "Beta", { parent: "t1", pos: "2", status: "completed" }),
        task("s3", "Gamma", { parent: "t1", pos: "3" }),
      ],
    );
    await openParent();

    // Hide completed: Beta disappears, leaving Alpha and Gamma.
    await fireEvent.click(screen.getByLabelText("Hide completed subtasks"));
    await waitFor(() => expect(subtaskOrder()).toEqual(["Alpha", "Gamma"]));

    // Drag Gamma above Alpha. Beta (completed, hidden) sits between them in the
    // full list, so this must cross it — a naive visible-index step would land
    // Gamma in the wrong place.
    await fireEvent.dragStart(itemFor("Gamma"));
    await fireEvent.dragOver(itemFor("Alpha"));
    await fireEvent.drop(itemFor("Alpha"));

    await waitFor(() => expect(subtaskOrder()).toEqual(["Gamma", "Alpha"]));

    // Revealing completed shows Beta retained its place after the reorder.
    await fireEvent.click(screen.getByLabelText("Hide completed subtasks"));
    await waitFor(() => expect(subtaskOrder()).toEqual(["Gamma", "Alpha", "Beta"]));
  });

  it("move-down button (touch path) reorders the subtask", async () => {
    mockBackend(
      [task("t1", "Parent")],
      [
        task("s1", "Alpha", { parent: "t1", pos: "1" }),
        task("s2", "Beta", { parent: "t1", pos: "2" }),
      ],
    );
    await openParent();
    expect(subtaskOrder()).toEqual(["Alpha", "Beta"]);

    await fireEvent.click(screen.getByLabelText("Move Alpha down"));
    await waitFor(() => expect(subtaskOrder()).toEqual(["Beta", "Alpha"]));
  });
});
