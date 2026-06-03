import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, waitFor, fireEvent } from "@testing-library/svelte";
import App from "../App.svelte";
import { invoke } from "@tauri-apps/api/core";

function task(id, title, opts = {}) {
  return {
    id, parent_id: opts.parent || null, title, notes: null,
    status: "needsAction", due: opts.due || new Date().toISOString(),
    position: opts.pos || "00001", sync_state: "clean", listId: "L1", listTitle: "Work",
  };
}

function mockBackend(tasks, failCmd = null, failMsg = "Network error") {
  invoke.mockImplementation(async (cmd, args) => {
    if (cmd === failCmd) throw new Error(failMsg);
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return [{ id: "L1", title: "Work" }];
      case "list_tasks": return tasks.filter(t => t.listId === args?.listId);
      case "toggle_complete": return null;
      case "delete_task": return null;
      case "rename_task": return null;
      case "set_due": return null;
      case "sync_now": return "ok";
      case "create_task": return { id: "new-1", parent_id: null, title: args?.title || "", status: "needsAction", due: null, position: "99999", listId: args?.listId };
      default: return null;
    }
  });
}

describe("GH#23: Error feedback toast", () => {
  beforeEach(() => {
    localStorage.clear();
    localStorage.setItem("axiotask:view", "L1");
    invoke.mockReset();
    vi.useFakeTimers({ shouldAdvanceTime: true });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("shows red error toast when a command fails", async () => {
    mockBackend([task("t1", "My Task")], "toggle_complete", "Network error");
    render(App);
    await waitFor(() => expect(screen.getByText("My Task")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: " " });
    await waitFor(() => expect(screen.getByRole("alert")).toBeInTheDocument());

    const toast = screen.getByRole("alert");
    expect(toast).toHaveClass("toast-error");
  });

  it("displays command name and error in the toast", async () => {
    mockBackend([task("t1", "My Task")], "toggle_complete", "Server timeout");
    render(App);
    await waitFor(() => expect(screen.getByText("My Task")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: " " });
    await waitFor(() => expect(screen.getByRole("alert")).toBeInTheDocument());

    const toast = screen.getByRole("alert");
    expect(toast.textContent).toContain("toggle_complete");
    expect(toast.textContent).toContain("Server timeout");
  });

  it("auto-dismisses error toast after 5 seconds", async () => {
    mockBackend([task("t1", "My Task")], "toggle_complete", "Oops");
    render(App);
    await waitFor(() => expect(screen.getByText("My Task")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: " " });
    await waitFor(() => expect(screen.getByRole("alert")).toBeInTheDocument());

    vi.advanceTimersByTime(5000);
    await waitFor(() => expect(screen.queryByRole("alert")).not.toBeInTheDocument());
  });

  it("shows dismiss button that removes error toast on click", async () => {
    mockBackend([task("t1", "My Task")], "toggle_complete", "Fail");
    render(App);
    await waitFor(() => expect(screen.getByText("My Task")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: " " });
    await waitFor(() => expect(screen.getByRole("alert")).toBeInTheDocument());

    const dismissBtn = screen.getByRole("alert").querySelector(".dismiss-btn");
    expect(dismissBtn).toBeInTheDocument();
    await fireEvent.click(dismissBtn);
    await waitFor(() => expect(screen.queryByRole("alert")).not.toBeInTheDocument());
  });

  it("shows error toast for delete_task failure", async () => {
    mockBackend([task("t1", "Delete me")], "delete_task", "Permission denied");
    render(App);
    await waitFor(() => expect(screen.getByText("Delete me")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: "d" });
    await waitFor(() => expect(screen.getByRole("alert")).toBeInTheDocument());

    const toast = screen.getByRole("alert");
    expect(toast.textContent).toContain("delete_task");
    expect(toast.textContent).toContain("Permission denied");
  });
});
