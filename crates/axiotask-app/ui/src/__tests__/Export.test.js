import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

/**
 * Export / backup feature.
 *
 * Ctrl+E triggers a complete JSON backup via the `export_backup` command and
 * surfaces a confirmation toast with the written path and counts.
 */

function mockBackend({ exportResult, exportError = false } = {}) {
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
      case "export_backup":
        if (exportError) throw new Error("disk full");
        return (
          exportResult || {
            path: "/home/user/.local/share/axiotask/backups/axiotask-backup-20260608-014500.json",
            lists: 1,
            tasks: 1,
            bytes: 512,
          }
        );
      default:
        return null;
    }
  });
}

describe("Export / backup", () => {
  beforeEach(() => {
    localStorage.clear();
    invoke.mockReset();
  });

  it("invokes export_backup on Ctrl+E", async () => {
    mockBackend();
    render(App);
    await waitFor(() => expect(screen.getByText("Inbox")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: "e", ctrlKey: true });

    await waitFor(() => {
      expect(invoke).toHaveBeenCalledWith("export_backup", expect.anything());
    });
  });

  it("shows a confirmation toast with counts and path after export", async () => {
    mockBackend();
    render(App);
    await waitFor(() => expect(screen.getByText("Inbox")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: "e", ctrlKey: true });

    await waitFor(() => {
      expect(
        screen.getByText(/Backed up 1 task in 1 list/),
      ).toBeInTheDocument();
    });
    expect(
      screen.getByText(/axiotask-backup-20260608-014500\.json/),
    ).toBeInTheDocument();
  });

  it("does not export on plain 'e' (which edits the focused task)", async () => {
    mockBackend();
    render(App);
    await waitFor(() => expect(screen.getByText("Inbox")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: "e" });

    expect(invoke).not.toHaveBeenCalledWith("export_backup", expect.anything());
  });

  it("supports the Cmd+E shortcut on macOS", async () => {
    mockBackend();
    render(App);
    await waitFor(() => expect(screen.getByText("Inbox")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: "e", metaKey: true });

    await waitFor(() => {
      expect(invoke).toHaveBeenCalledWith("export_backup", expect.anything());
    });
  });

  it("surfaces an error toast when the export command fails", async () => {
    mockBackend({ exportError: true });
    render(App);
    await waitFor(() => expect(screen.getByText("Inbox")).toBeInTheDocument());

    await fireEvent.keyDown(window, { key: "e", ctrlKey: true });

    await waitFor(() => {
      expect(screen.getByText(/Failed: export_backup/)).toBeInTheDocument();
    });
  });
});
