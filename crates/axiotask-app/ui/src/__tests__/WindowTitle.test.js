import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

// The window title reflects the current view. Two representative cases cover the
// two distinct code paths: a smart view (name from the built-in map) and a task
// list (name looked up from the list). The other smart views share the map path,
// so enumerating each one adds no coverage.

const setTitleMock = vi.fn().mockResolvedValue(undefined);
vi.mock("@tauri-apps/api/window", () => ({
  getCurrentWindow: () => ({ setTitle: setTitleMock }),
}));

const sampleLists = [
  { id: "L1", title: "Work" },
  { id: "L2", title: "Personal" },
];

function mockBackend(lists = sampleLists, tasks = []) {
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return tasks.filter(t => t.listId === args?.listId);
      default: return null;
    }
  });
}

describe("Window title reflects current view", () => {
  beforeEach(() => {
    localStorage.clear();
    invoke.mockReset();
    setTitleMock.mockClear();
  });

  it("uses the smart-view name (Focus on load)", async () => {
    mockBackend();
    render(App);
    await waitFor(() => expect(setTitleMock).toHaveBeenCalledWith("Focus — axiotask"));
  });

  it("uses the list name when a task list is selected", async () => {
    mockBackend();
    render(App);
    await waitFor(() => screen.getByRole("button", { name: /Work/i }));
    await fireEvent.click(screen.getByRole("button", { name: /Work/i }));
    await waitFor(() => expect(setTitleMock).toHaveBeenCalledWith("Work — axiotask"));
  });
});
