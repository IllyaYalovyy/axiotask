// #164: a subtask's explicit due date can never be before its parent's. The
// cascade itself is enforced (and unit-tested) in the Rust command layer; this
// suite proves the FRONTEND surfaces it: an undoable toast, the moved dates
// rendered in both the list row and the detail panel, and Undo reverting the
// whole cascade as one unit through `undo_set_due`.
import { render, fireEvent, waitFor, screen } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

const DAY = 86400000;
const baseNow = new Date();
baseNow.setHours(0, 0, 0, 0);
function daysFromNow(n) {
  return new Date(baseNow.getTime() + n * DAY).toISOString();
}

describe("#164: parent/subtask due-date consistency — UI", () => {
  beforeEach(() => {
    localStorage.clear();
    // A LIST view keeps the top-level parent visible regardless of its date.
    localStorage.setItem("axiotask:view", "L1");
    invoke.mockReset();
  });

  it("cascading a parent date up shows an undoable toast, updates the row and the panel, and Undo reverts the whole cascade", async () => {
    const parentOld = daysFromNow(-5); // 5 days overdue
    const childOld = daysFromNow(-8);
    const moved = daysFromNow(1); // tomorrow — formatDue → "tomorrow" (locale-free)
    const movedDate = moved.slice(0, 10);

    // The cascade the backend reports for a parent moved later: one child pulled
    // up, with the undo unit covering both rows' prior dates.
    const setDueResult = {
      cascaded: 1,
      cascaded_parent: false,
      undo: [
        { id: "P", due: parentOld },
        { id: "C", due: childOld },
      ],
    };

    let cascaded = false;
    let undone = false;
    const calls = [];
    invoke.mockImplementation(async (cmd, args) => {
      calls.push([cmd, args]);
      switch (cmd) {
        case "auth_status":
          return true;
        case "list_tasklists":
          return [{ id: "L1", title: "Work" }];
        case "list_tasks": {
          const parentDue = undone ? parentOld : cascaded ? moved : parentOld;
          const childDue = undone ? childOld : cascaded ? moved : childOld;
          return [
            { id: "P", parent_id: null, title: "Parent", notes: null, status: "needsAction", due: parentDue, position: "1", sync_state: "clean", listId: "L1", listTitle: "Work" },
            { id: "C", parent_id: "P", title: "Child", notes: null, status: "needsAction", due: childDue, position: "2", sync_state: "clean", listId: "L1", listTitle: "Work" },
          ];
        }
        case "set_due":
          cascaded = true;
          return setDueResult;
        case "undo_set_due":
          undone = true;
          return null;
        case "sync_now":
          return "ok";
        default:
          return null;
      }
    });

    const { container } = render(App);
    await waitFor(() => expect(screen.getByText("Parent")).toBeInTheDocument());

    // Parent row starts overdue.
    const parentRow = [...container.querySelectorAll(".task-widget")].find((r) => r.textContent.includes("Parent"));
    expect(parentRow.querySelector(".due").textContent).toContain("overdue");

    // Reschedule the parent to tomorrow via the row's →t button.
    const nextBtn = [...parentRow.querySelectorAll(".actions button")].find((b) => b.textContent === "→t");
    await fireEvent.click(nextBtn);

    // 1) The cascade announces itself in an undoable toast.
    await waitFor(() => expect(screen.getByText("1 subtask date moved to match")).toBeInTheDocument());

    // 2) The parent row now shows the moved date in the list.
    await waitFor(() => {
      const row = [...container.querySelectorAll(".task-widget")].find((r) => r.textContent.includes("Parent"));
      expect(row.querySelector(".due").textContent).toContain("tomorrow");
    });

    // 3) The subtask's moved date is visible in the detail panel.
    await fireEvent.click(screen.getByText("Parent"));
    await waitFor(() => {
      const btn = container.querySelector(`.detail-panel [aria-label="Subtask due date: ${movedDate}"]`);
      expect(btn).toBeInTheDocument();
    });

    // 4) Undo reverts the whole cascade as one unit via undo_set_due.
    await fireEvent.click(screen.getByRole("button", { name: "Undo" }));
    await waitFor(() => {
      const undoCall = calls.find(([c]) => c === "undo_set_due");
      expect(undoCall).toBeTruthy();
      expect(undoCall[1]).toEqual({ entries: setDueResult.undo });
    });
  });

  it("no toast when a date edit changes nothing else (cascaded = 0)", async () => {
    invoke.mockImplementation(async (cmd) => {
      switch (cmd) {
        case "auth_status":
          return true;
        case "list_tasklists":
          return [{ id: "L1", title: "Work" }];
        case "list_tasks":
          return [
            { id: "P", parent_id: null, title: "Lonely", notes: null, status: "needsAction", due: daysFromNow(-5), position: "1", sync_state: "clean", listId: "L1", listTitle: "Work" },
          ];
        case "set_due":
          return { cascaded: 0, cascaded_parent: false, undo: [{ id: "P", due: daysFromNow(-5) }] };
        default:
          return null;
      }
    });

    const { container } = render(App);
    await waitFor(() => expect(screen.getByText("Lonely")).toBeInTheDocument());
    const row = [...container.querySelectorAll(".task-widget")].find((r) => r.textContent.includes("Lonely"));
    const btn = [...row.querySelectorAll(".actions button")].find((b) => b.textContent === "→t");
    await fireEvent.click(btn);

    // Give any toast a chance to appear, then assert none did.
    await new Promise((r) => setTimeout(r, 0));
    expect(screen.queryByText(/moved to match/)).not.toBeInTheDocument();
  });
});
