import { render, screen, fireEvent, waitFor, within } from "@testing-library/svelte";
import { describe, it, expect, beforeEach, vi } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";
import pkg from "../../package.json";

const baseSettings = {
  version: pkg.version,
  instance: null,
  push_enabled: false,
  auto_sync_on_start: true,
  authenticated: true,
  scopes: ["https://www.googleapis.com/auth/tasks"],
  db_path: "/home/u/.local/share/axiotask/axiotask.sqlite",
  config_path: "/home/u/.config/axiotask/config.toml",
  needs_reauth: false,
  pending_pushes: 2,
  sync: {
    last_synced: new Date(Date.now() - 120000).toISOString(),
    last_pulled: 3,
    last_pushed: 1,
    last_conflicts: 0,
    last_deleted: 0,
    total_syncs: 5,
    last_error: null,
    needs_attention: false,
  },
};

// Mutable settings the mock returns; set_* commands mutate and echo it back.
let settings;

function mockBackend(lists = [{ id: "L1", title: "Work" }]) {
  settings = structuredClone(baseSettings);
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return settings.authenticated;
      case "list_tasklists": return lists;
      case "list_tasks": return [];
      case "sync_now": return "ok";
      case "fresh_sync":
        settings.pending_pushes = 0;
        settings.sync.last_pulled = 7;
        settings.sync.last_pushed = 0;
        settings.sync.last_deleted = 3;
        settings.sync.total_syncs += 1;
        settings.sync.last_synced = new Date().toISOString();
        return "fresh sync: pulled=7, deleted=3";
      case "get_settings": return structuredClone(settings);
      case "set_push_enabled":
        settings.push_enabled = args.enabled;
        return structuredClone(settings);
      case "set_auto_sync":
        settings.auto_sync_on_start = args.enabled;
        return structuredClone(settings);
      case "export_backup": return { path: "/tmp/b.json", lists: 1, tasks: 2, bytes: 100 };
      case "import_backup": return { path: "/tmp/b.json", lists: 1, tasks: 2 };
      default: return null;
    }
  });
}

async function openProperties() {
  mockBackend();
  render(App);
  await waitFor(() =>
    expect(screen.getByRole("button", { name: /properties/i })).toBeInTheDocument(),
  );
  await fireEvent.click(screen.getByRole("button", { name: /properties/i }));
  await waitFor(() =>
    expect(screen.getByRole("dialog", { name: /properties/i })).toBeInTheDocument(),
  );
}

describe("Properties dialog", () => {
  beforeEach(() => invoke.mockReset());

  it("has a Properties trigger in the sidebar", async () => {
    mockBackend();
    render(App);
    await waitFor(() =>
      expect(screen.getByRole("button", { name: /properties/i })).toBeInTheDocument(),
    );
  });

  it("opens from the sidebar button", async () => {
    await openProperties();
    expect(screen.getByRole("dialog", { name: /properties/i })).toBeInTheDocument();
  });

  it("opens with the ',' keyboard shortcut", async () => {
    mockBackend();
    render(App);
    await waitFor(() => expect(screen.getByText("Work")).toBeInTheDocument());
    await fireEvent.keyDown(window, { key: "," });
    await waitFor(() =>
      expect(screen.getByRole("dialog", { name: /properties/i })).toBeInTheDocument(),
    );
  });

  it("shows the sync mode toggle and reflects read-only by default", async () => {
    await openProperties();
    const toggle = screen.getByRole("checkbox", { name: /read-write sync/i });
    expect(toggle).not.toBeChecked();
  });

  it("enabling read-write sync requires confirmation before pushing", async () => {
    await openProperties();
    const toggle = screen.getByRole("checkbox", { name: /read-write sync/i });
    await fireEvent.click(toggle);
    // No push yet — a confirmation must appear first.
    expect(invoke.mock.calls.find((c) => c[0] === "set_push_enabled")).toBeFalsy();
    await fireEvent.click(await screen.findByText(/Enable push/i));
    await waitFor(() => {
      const call = invoke.mock.calls.find((c) => c[0] === "set_push_enabled");
      expect(call).toBeTruthy();
      expect(call[1]).toEqual({ enabled: true });
    });
  });

  it("canceling the confirmation leaves sync read-only", async () => {
    await openProperties();
    const toggle = screen.getByRole("checkbox", { name: /read-write sync/i });
    await fireEvent.click(toggle);
    await fireEvent.click(await screen.findByText(/Cancel/i));
    expect(invoke.mock.calls.find((c) => c[0] === "set_push_enabled")).toBeFalsy();
    expect(toggle).not.toBeChecked();
  });

  it("shows sync status stats", async () => {
    await openProperties();
    const dialog = screen.getByRole("dialog", { name: /properties/i });
    // pending changes count and session sync count are surfaced.
    expect(dialog).toHaveTextContent("Pending changes");
    expect(dialog).toHaveTextContent("Syncs this session");
  });

  it("surfaces the last sync error when present", async () => {
    mockBackend();
    settings.sync.last_error = "network unreachable";
    render(App);
    await waitFor(() =>
      expect(screen.getByRole("button", { name: /properties/i })).toBeInTheDocument(),
    );
    await fireEvent.click(screen.getByRole("button", { name: /properties/i }));
    await waitFor(() =>
      expect(screen.getByRole("alert")).toHaveTextContent(/network unreachable/i),
    );
  });

  it("surfaces a stuck (needs-attention) failure distinctly from a one-off blip", async () => {
    // A permanent failure is stuck — retries have backed off. The user must see
    // the real error framed as a persistent "needs attention" state, NOT the
    // transient "last sync failed" wording that reads like a one-off.
    mockBackend();
    settings.sync.last_error = "schema mismatch: column tasks.blorp missing";
    settings.sync.needs_attention = true;
    render(App);
    await waitFor(() =>
      expect(screen.getByRole("button", { name: /properties/i })).toBeInTheDocument(),
    );
    await fireEvent.click(screen.getByRole("button", { name: /properties/i }));
    const alert = await screen.findByRole("alert");
    expect(alert).toHaveTextContent(/needs attention/i);
    expect(alert).toHaveTextContent(/schema mismatch: column tasks\.blorp missing/i);
    expect(alert).toHaveTextContent(/retries have slowed down/i);
    // It must NOT read as a transient one-off failure.
    expect(alert).not.toHaveTextContent(/last sync failed/i);
  });

  it("Account tab shows signed-in status and scope", async () => {
    await openProperties();
    await fireEvent.click(screen.getByRole("tab", { name: /account/i }));
    const dialog = screen.getByRole("dialog", { name: /properties/i });
    expect(dialog).toHaveTextContent(/signed in/i);
    expect(dialog).toHaveTextContent(/Google Tasks/i);
    expect(dialog).toHaveTextContent(/Use an isolated instance to sign in with another Google account/i);
    expect(screen.getByRole("button", { name: /sign out/i })).toBeInTheDocument();
  });

  it("Account tab surfaces an expired session with a Sign in again action", async () => {
    // needs_reauth: tokens exist (authenticated) but Google permanently
    // rejects the refresh — the user must re-run the OAuth flow.
    mockBackend();
    settings.needs_reauth = true;
    render(App);
    await waitFor(() =>
      expect(screen.getByRole("button", { name: /properties/i })).toBeInTheDocument(),
    );
    await fireEvent.click(screen.getByRole("button", { name: /properties/i }));
    const dialog = await screen.findByRole("dialog", { name: /properties/i });
    await fireEvent.click(screen.getByRole("tab", { name: /account/i }));
    expect(dialog).toHaveTextContent(/session expired/i);
    expect(dialog).toHaveTextContent(/kept locally/i);
    const signIn = screen.getByRole("button", { name: /sign in again/i });
    await fireEvent.click(signIn);
    await waitFor(() =>
      expect(invoke.mock.calls.some((c) => c[0] === "auth_login")).toBe(true),
    );
  });

  it("Shortcuts tab lists key bindings", async () => {
    await openProperties();
    await fireEvent.click(screen.getByRole("tab", { name: /shortcuts/i }));
    const dialog = screen.getByRole("dialog", { name: /properties/i });
    expect(dialog).toHaveTextContent(/Next task/i);
    expect(dialog).toHaveTextContent(/Open Properties/i);
  });

  it("About tab shows version and repository (folded-in About)", async () => {
    await openProperties();
    await fireEvent.click(screen.getByRole("tab", { name: /about/i }));
    const dialog = screen.getByRole("dialog", { name: /properties/i });
    expect(dialog).toHaveTextContent(`v${pkg.version}`);
    const link = screen.getByRole("link", { name: /github\.com\/yalovoy\/axiotask/i });
    expect(link).toHaveAttribute("href", "https://github.com/yalovoy/axiotask");
  });

  it("About tab labels the default instance", async () => {
    await openProperties();
    await fireEvent.click(screen.getByRole("tab", { name: /about/i }));
    expect(screen.getByRole("dialog", { name: /properties/i })).toHaveTextContent(
      /default \(production\)/i,
    );
  });

  it("shows the instance name when an isolated instance is active", async () => {
    mockBackend();
    settings.instance = "dev";
    render(App);
    await waitFor(() =>
      expect(screen.getByRole("button", { name: /properties/i })).toBeInTheDocument(),
    );
    await fireEvent.click(screen.getByRole("button", { name: /properties/i }));
    const dialog = await screen.findByRole("dialog", { name: /properties/i });
    // Badge in the header.
    expect(dialog).toHaveTextContent("dev");
    await fireEvent.click(screen.getByRole("tab", { name: /about/i }));
    expect(dialog).toHaveTextContent("dev");
  });

  it("exposes Export and Restore backup buttons in the Sync tab", async () => {
    await openProperties();
    expect(screen.getByRole("button", { name: /export backup/i })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /restore latest/i })).toBeInTheDocument();
  });

  it("Export backup confirms with a toast naming the counts and file", async () => {
    await openProperties();
    await fireEvent.click(screen.getByRole("button", { name: /export backup/i }));
    // mock export_backup returns { lists: 1, tasks: 2, path: "/tmp/b.json" }.
    await waitFor(() =>
      expect(screen.getByText(/Backed up 2 tasks in 1 list → \/tmp\/b\.json/)).toBeInTheDocument(),
    );
  });

  it("Restore latest confirms with a toast naming the counts and file", async () => {
    await openProperties();
    await fireEvent.click(screen.getByRole("button", { name: /restore latest/i }));
    // mock import_backup returns { lists: 1, tasks: 2, path: "/tmp/b.json" }.
    await waitFor(() =>
      expect(screen.getByText(/Restored 2 tasks in 1 list ← \/tmp\/b\.json/)).toBeInTheDocument(),
    );
  });

  it("Fresh sync uses a styled confirmation inside Properties", async () => {
    const confirmSpy = vi.spyOn(window, "confirm");
    await openProperties();
    const dialog = screen.getByRole("dialog", { name: /properties/i });

    await fireEvent.click(within(dialog).getByRole("button", { name: /fresh sync/i }));

    expect(confirmSpy).not.toHaveBeenCalled();
    const alert = await screen.findByRole("alertdialog", { name: /fresh sync/i });
    expect(alert).toHaveTextContent(/drop local data/i);
    expect(invoke.mock.calls.some((c) => c[0] === "fresh_sync")).toBe(false);

    await fireEvent.click(within(alert).getByRole("button", { name: /^fresh sync$/i }));

    await waitFor(() =>
      expect(invoke.mock.calls.some((c) => c[0] === "fresh_sync")).toBe(true),
    );
    await waitFor(() =>
      expect(screen.getByRole("dialog", { name: /properties/i })).toHaveTextContent(/↓7 ↑0/i),
    );
    confirmSpy.mockRestore();
  });

  it("canceling the Fresh sync confirmation keeps local data untouched", async () => {
    const confirmSpy = vi.spyOn(window, "confirm");
    await openProperties();
    const dialog = screen.getByRole("dialog", { name: /properties/i });

    await fireEvent.click(within(dialog).getByRole("button", { name: /fresh sync/i }));
    await fireEvent.click(await screen.findByRole("button", { name: /cancel/i }));

    expect(confirmSpy).not.toHaveBeenCalled();
    expect(invoke.mock.calls.some((c) => c[0] === "fresh_sync")).toBe(false);
    expect(screen.queryByRole("alertdialog", { name: /fresh sync/i })).not.toBeInTheDocument();
    confirmSpy.mockRestore();
  });

  it("closes on Escape", async () => {
    await openProperties();
    await fireEvent.keyDown(window, { key: "Escape" });
    await waitFor(() =>
      expect(screen.queryByRole("dialog", { name: /properties/i })).not.toBeInTheDocument(),
    );
  });

  it("closes when the close button is clicked", async () => {
    await openProperties();
    await fireEvent.click(screen.getByRole("button", { name: /^close$/i }));
    await waitFor(() =>
      expect(screen.queryByRole("dialog", { name: /properties/i })).not.toBeInTheDocument(),
    );
  });
});
