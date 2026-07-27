import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

/**
 * Export / backup feature.
 *
 * The "Export backup" button in Properties → Sync triggers a complete JSON
 * backup via the `export_backup` command and surfaces a confirmation toast with
 * the written path and counts.
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

function mockBackend({ exportResult, exportError = false } = {}) {
  const lists = [{ id: "L1", title: "Inbox" }];
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return false;
      case "list_tasklists": return lists;
      case "list_tasks": return [];
      case "get_settings": return settings();
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
      default: return null;
    }
  });
}

async function clickExport() {
  render(App);
  await waitFor(() => expect(screen.getByText("Inbox")).toBeInTheDocument());
  await fireEvent.click(screen.getByRole("button", { name: /properties/i }));
  const dialog = await screen.findByRole("dialog", { name: /properties/i });
  await fireEvent.click(screen.getByRole("button", { name: /export backup/i }));
  return dialog;
}

describe("Export / backup", () => {
  beforeEach(() => {
    localStorage.clear();
    invoke.mockReset();
  });

  it("invokes export_backup from the Properties button", async () => {
    mockBackend();
    await clickExport();
    await waitFor(() =>
      expect(invoke).toHaveBeenCalledWith("export_backup", expect.anything()),
    );
  });

  it("shows a confirmation toast with counts and path after export", async () => {
    mockBackend();
    await clickExport();
    await waitFor(() =>
      expect(screen.getByText(/Backed up 1 task in 1 list/)).toBeInTheDocument(),
    );
    expect(
      screen.getByText(/axiotask-backup-20260608-014500\.json/),
    ).toBeInTheDocument();
  });

  it("surfaces a calm redacted error toast when the export command fails (#135)", async () => {
    // The raw "disk full" carries no authored marker, so the allowlist guard
    // redacts it to a calm family sentence rather than leaking it.
    mockBackend({ exportError: true });
    await clickExport();
    await waitFor(() =>
      expect(screen.getByText(/export your backup/i)).toBeInTheDocument(),
    );
    expect(screen.getByRole("alert").textContent).not.toContain("disk full");
    expect(screen.getByRole("alert").textContent.toLowerCase()).toContain("log");
  });
});
