import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

/**
 * Import / restore feature.
 *
 * Ctrl+I restores the most recent JSON backup via the `import_backup` command
 * and surfaces a confirmation toast with the counts and the file restored from.
 * Mirrors the export (Ctrl+E) flow.
 */

function mockBackend({ importResult, importError = false } = {}) {
  const lists = [{ id: "L1", title: "Inbox" }];
  const tasks = {
    L1: [
      {
        id: "T1",
        parent_id: null,
        title: "Buy milk",
        notes: null,
        status: "needsAction",
        due: null,
        position: "00000000000001",
        sync_state: "clean",
      },
    ],
  };

  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status":
        return false;
      case "list_tasklists":
        return lists;
      case "list_tasks":
        return tasks[args?.listId] || [];
      case "import_backup":
        if (importError) throw new Error("file not found");
        return (
          importResult || {
            path: "/home/user/.local/share/axiotask/backups/axiotask-backup-20260608-014500.json",
            lists: 2,
            tasks: 7,
          }
        );
      default:
        return null;
    }
  });
}

describe("Import / restore", () => {
  beforeEach(() => {
    localStorage.clear();
    invoke.mockReset();
  });

  it("invokes import_backup on Ctrl+I", async () => {
    mockBackend();
    render(App);
    await waitFor(() => expect(screen.getByText("Inbox")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: "i", ctrlKey: true });

    await waitFor(() => {
      expect(invoke).toHaveBeenCalledWith("import_backup", expect.anything());
    });
  });

  it("shows a confirmation toast with counts and path after restore", async () => {
    mockBackend();
    render(App);
    await waitFor(() => expect(screen.getByText("Inbox")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: "i", ctrlKey: true });

    await waitFor(() => {
      expect(
        screen.getByText(/Restored 7 tasks in 2 lists/),
      ).toBeInTheDocument();
    });
    expect(
      screen.getByText(/axiotask-backup-20260608-014500\.json/),
    ).toBeInTheDocument();
  });

  it("does not import on plain 'i'", async () => {
    mockBackend();
    render(App);
    await waitFor(() => expect(screen.getByText("Inbox")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: "i" });

    expect(invoke).not.toHaveBeenCalledWith("import_backup", expect.anything());
  });

  it("supports the Cmd+I shortcut on macOS", async () => {
    mockBackend();
    render(App);
    await waitFor(() => expect(screen.getByText("Inbox")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: "i", metaKey: true });

    await waitFor(() => {
      expect(invoke).toHaveBeenCalledWith("import_backup", expect.anything());
    });
  });

  it("surfaces an error toast when the import command fails", async () => {
    mockBackend({ importError: true });
    render(App);
    await waitFor(() => expect(screen.getByText("Inbox")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: "i", ctrlKey: true });

    await waitFor(() => {
      expect(screen.getByText(/Failed: import_backup/)).toBeInTheDocument();
    });
  });

  it("reloads tasks after a successful restore", async () => {
    mockBackend();
    render(App);
    await waitFor(() => expect(screen.getByText("Inbox")).toBeInTheDocument());

    invoke.mockClear();
    await fireEvent.keyDown(window, { key: "i", ctrlKey: true });

    // After restoring, the view refreshes so the imported tasks appear.
    await waitFor(() => {
      expect(invoke).toHaveBeenCalledWith("list_tasklists", expect.anything());
    });
  });
});
