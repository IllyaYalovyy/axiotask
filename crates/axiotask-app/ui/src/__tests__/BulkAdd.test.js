import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

const sampleLists = [{ id: "L1", title: "Work" }];

function mockBackend() {
  let nextId = 100;
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return sampleLists;
      case "list_tasks": return [];
      case "create_task":
        return { id: `new-${nextId++}`, parent_id: null, title: args.title, notes: null, status: "needsAction", due: null, position: "0", sync_state: "clean", listId: args.listId, listTitle: "Work" };
      case "set_notes": return null;
      case "sync_now": return "ok";
      default: return null;
    }
  });
}

function paste(text) {
  const event = new Event("paste", { bubbles: true, cancelable: true });
  event.clipboardData = { getData: () => text };
  event.preventDefault = vi.fn();
  window.dispatchEvent(event);
}

async function openBulk(text) {
  localStorage.setItem("axiotask:view", "L1");
  mockBackend();
  render(App);
  await waitFor(() => expect(screen.getByText("+ New task")).toBeInTheDocument());
  paste(text);
  await waitFor(() =>
    expect(screen.getByRole("dialog", { name: /add multiple tasks/i })).toBeInTheDocument(),
  );
}

function createCalls() {
  return invoke.mock.calls.filter((c) => c[0] === "create_task");
}
function notesCalls() {
  return invoke.mock.calls.filter((c) => c[0] === "set_notes");
}

describe("Bulk add dialog", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });

  it("defaults to one-task-per-line and shows a live count", async () => {
    await openBulk("Alpha\nBeta\nGamma");
    expect(screen.getByText(/Creates 3 tasks/)).toBeInTheDocument();
  });

  it("one-task-per-line creates a task for each non-empty line", async () => {
    await openBulk("Alpha\n\n  \nBeta\nGamma\n");
    await fireEvent.click(screen.getByRole("button", { name: /^add$/i }));
    await waitFor(() => {
      const calls = createCalls();
      expect(calls.map((c) => c[1].title)).toEqual(["Alpha", "Beta", "Gamma"]);
    });
    expect(notesCalls().length).toBe(0);
  });

  it("first-line-title mode creates one task with the rest as notes", async () => {
    await openBulk("Plan the trip\nBook flights\nReserve hotel");
    await fireEvent.click(
      screen.getByRole("radio", { name: /first line is the title/i }),
    );
    // Count drops to a single task.
    expect(screen.getByText(/Creates 1 task/)).toBeInTheDocument();
    await fireEvent.click(screen.getByRole("button", { name: /^add$/i }));

    await waitFor(() => expect(createCalls().length).toBe(1));
    expect(createCalls()[0][1].title).toBe("Plan the trip");
    await waitFor(() => {
      expect(notesCalls()[0][1].notes).toBe("Book flights\nReserve hotel");
    });
  });

  it("shows a confirmation toast after creating", async () => {
    await openBulk("Alpha\nBeta");
    await fireEvent.click(screen.getByRole("button", { name: /^add$/i }));
    await waitFor(() =>
      expect(screen.getByText(/Added 2 tasks/)).toBeInTheDocument(),
    );
  });

  it("Cancel closes the dialog without creating anything", async () => {
    await openBulk("Alpha\nBeta");
    await fireEvent.click(screen.getByRole("button", { name: /cancel/i }));
    await waitFor(() =>
      expect(screen.queryByRole("dialog", { name: /add multiple tasks/i })).not.toBeInTheDocument(),
    );
    expect(createCalls().length).toBe(0);
  });
});
