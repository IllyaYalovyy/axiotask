import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
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
  pending_pushes: 2,
  sync: {
    last_synced: new Date(Date.now() - 120000).toISOString(),
    last_pulled: 3,
    last_pushed: 1,
    last_conflicts: 0,
    last_deleted: 0,
    total_syncs: 5,
    last_error: null,
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
      case "get_settings": return structuredClone(settings);
      case "set_push_enabled":
        settings.push_enabled = args.enabled;
        return structuredClone(settings);
      case "set_auto_sync":
        settings.auto_sync_on_start = args.enabled;
        return structuredClone(settings);
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

  it("toggling read-write sync invokes set_push_enabled", async () => {
    await openProperties();
    const toggle = screen.getByRole("checkbox", { name: /read-write sync/i });
    await fireEvent.click(toggle);
    await waitFor(() => {
      const call = invoke.mock.calls.find((c) => c[0] === "set_push_enabled");
      expect(call).toBeTruthy();
      expect(call[1]).toEqual({ enabled: true });
    });
    await waitFor(() => expect(toggle).toBeChecked());
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

  it("Account tab shows signed-in status and scope", async () => {
    await openProperties();
    await fireEvent.click(screen.getByRole("tab", { name: /account/i }));
    const dialog = screen.getByRole("dialog", { name: /properties/i });
    expect(dialog).toHaveTextContent(/signed in/i);
    expect(dialog).toHaveTextContent(/Google Tasks/i);
    expect(screen.getByRole("button", { name: /sign out/i })).toBeInTheDocument();
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
