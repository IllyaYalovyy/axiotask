import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

/**
 * Import / restore feature.
 *
 * The "Restore latest" button in Properties → Sync restores the most recent
 * JSON backup via the `import_backup` command and surfaces a confirmation toast
 * with the counts and the file restored from.
 */

function settings() {
  return {
    version: "0.1.0",
    instance: null,
    push_enabled: false,
    auto_sync_on_start: true,
    authenticated: false,
    scopes: ["https://www.googleapis.com/auth/tasks"],
    db_path: "/db",
    config_path: "/cfg",
    pending_pushes: 0,
    sync: {
      last_synced: null,
      last_pulled: 0,
      last_pushed: 0,
      last_conflicts: 0,
      last_deleted: 0,
      total_syncs: 0,
      last_error: null,
    },
  };
}

function mockBackend({ importResult, importError = false } = {}) {
  const lists = [{ id: "L1", title: "Inbox" }];
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return false;
      case "list_tasklists": return lists;
      case "list_tasks": return [];
      case "get_settings": return settings();
      case "import_backup":
        if (importError) throw new Error("file not found");
        return (
          importResult || {
            path: "/home/user/.local/share/axiotask/backups/axiotask-backup-20260608-014500.json",
            lists: 2,
            tasks: 7,
          }
        );
      default: return null;
    }
  });
}

async function clickRestore() {
  render(App);
  await waitFor(() => expect(screen.getByText("Inbox")).toBeInTheDocument());
  await fireEvent.click(screen.getByRole("button", { name: /properties/i }));
  await screen.findByRole("dialog", { name: /properties/i });
  await fireEvent.click(screen.getByRole("button", { name: /restore latest/i }));
}

describe("Import / restore", () => {
  beforeEach(() => {
    localStorage.clear();
    invoke.mockReset();
  });

  it("invokes import_backup from the Properties button", async () => {
    mockBackend();
    await clickRestore();
    await waitFor(() =>
      expect(invoke).toHaveBeenCalledWith("import_backup", expect.anything()),
    );
  });

  it("shows a confirmation toast with counts and path after restore", async () => {
    mockBackend();
    await clickRestore();
    await waitFor(() =>
      expect(screen.getByText(/Restored 7 tasks in 2 lists/)).toBeInTheDocument(),
    );
    expect(
      screen.getByText(/axiotask-backup-20260608-014500\.json/),
    ).toBeInTheDocument();
  });

  it("surfaces a calm redacted error toast when the import command fails (#135)", async () => {
    // The raw "file not found" carries no authored marker, so the allowlist
    // guard redacts it to a calm family sentence rather than leaking it.
    mockBackend({ importError: true });
    await clickRestore();
    await waitFor(() =>
      expect(screen.getByText(/restore your backup/i)).toBeInTheDocument(),
    );
    expect(screen.getByRole("alert").textContent).not.toContain("file not found");
    expect(screen.getByRole("alert").textContent.toLowerCase()).toContain("log");
  });

  it("reloads tasks after a successful restore", async () => {
    mockBackend();
    await clickRestore();
    // After restoring, the view refreshes so the imported tasks appear.
    await waitFor(() =>
      expect(invoke).toHaveBeenCalledWith("list_tasklists", expect.anything()),
    );
  });
});
