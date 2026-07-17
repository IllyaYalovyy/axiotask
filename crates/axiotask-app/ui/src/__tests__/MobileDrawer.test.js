import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

const lists = [
  { id: "L1", title: "Work" },
  { id: "L2", title: "Personal" },
];

function mockBackend({ authenticated = true } = {}) {
  invoke.mockImplementation(async (cmd) => {
    switch (cmd) {
      case "auth_status": return authenticated;
      case "list_tasklists": return lists;
      case "list_tasks": return [];
      case "sync_now": return "pulled=0, pushed=0, conflicts=0, deleted=0";
      case "get_settings":
        return {
          version: "0.1.0",
          instance: null,
          push_enabled: false,
          auto_sync_on_start: true,
          authenticated,
          scopes: ["https://www.googleapis.com/auth/tasks"],
          db_path: "/tmp/axiotask.sqlite",
          config_path: "/tmp/config.toml",
          needs_reauth: false,
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
      default: return null;
    }
  });
}

describe("Mobile drawer navigation", () => {
  beforeEach(() => invoke.mockReset());

  it("opens the sidebar drawer with sync and Properties actions, then closes after navigation", async () => {
    mockBackend({ authenticated: true });
    render(App);

    const menu = await screen.findByRole("button", { name: /open navigation/i });
    expect(menu).toHaveAttribute("aria-expanded", "false");

    await fireEvent.click(menu);
    expect(menu).toHaveAttribute("aria-expanded", "true");
    expect(screen.getByRole("navigation", { name: /mobile navigation/i })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /sync now/i })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /properties/i })).toBeInTheDocument();

    await fireEvent.click(await screen.findByRole("button", { name: /Personal/i }));
    await waitFor(() => expect(menu).toHaveAttribute("aria-expanded", "false"));
  });

  it("keeps sign-in reachable from the mobile drawer when offline", async () => {
    mockBackend({ authenticated: false });
    render(App);

    const menu = await screen.findByRole("button", { name: /open navigation/i });
    await fireEvent.click(menu);

    expect(screen.getByRole("button", { name: /sign in with google/i })).toBeInTheDocument();
  });

  it("opens Properties from the drawer without leaving the drawer over the dialog", async () => {
    mockBackend({ authenticated: true });
    render(App);

    const menu = await screen.findByRole("button", { name: /open navigation/i });
    await fireEvent.click(menu);
    await fireEvent.click(screen.getByRole("button", { name: /properties/i }));

    await waitFor(() => expect(menu).toHaveAttribute("aria-expanded", "false"));
    expect(await screen.findByRole("dialog", { name: /properties/i })).toBeInTheDocument();
  });
});
