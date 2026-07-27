import { render, screen, waitFor } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";
import { mockInvoke, resetMocks, emitMockEvent } from "../test-setup.js";

// #136: a *permanent*, backed-off sync failure ("needs attention") used to be
// visible only inside the Properties dialog. It must also surface as a
// persistent indicator in the main window, and — because the streak/attention
// state is deliberately NOT persisted across restarts — it must track the live
// backend state: appear when a run reports it, and clear the moment a later run
// recovers.
describe("Needs-attention indicator in the main window (#136)", () => {
  beforeEach(() => {
    resetMocks();
    invoke.mockClear();
    localStorage.clear();
    mockInvoke("auth_status", () => true);
    mockInvoke("list_tasklists", () => [{ id: "L1", title: "My Tasks" }]);
    mockInvoke("list_tasks", () => []);
    mockInvoke("sync_now", () => "ok");
  });

  it("surfaces a stuck (needs-attention) sync as a persistent main-window indicator", async () => {
    render(App);
    await waitFor(() => expect(screen.getByText("My Tasks")).toBeInTheDocument());

    emitMockEvent("sync-updated", {
      last_error: "Sync is stuck and needs attention.",
      last_synced: null,
      needs_attention: true,
    });

    await waitFor(() =>
      expect(
        screen.getByRole("button", { name: /needs attention/i }),
      ).toBeInTheDocument(),
    );
  });

  it("does not show the indicator for a merely transient failure", async () => {
    render(App);
    await waitFor(() => expect(screen.getByText("My Tasks")).toBeInTheDocument());

    // Transient: last_error is set but needs_attention is false. The user sees
    // the usual error toast, but NOT the persistent needs-attention indicator.
    emitMockEvent("sync-updated", {
      last_error: "network: timeout",
      last_synced: null,
      needs_attention: false,
    });

    await waitFor(() =>
      expect(screen.getByText(/Sync failed: network: timeout/)).toBeInTheDocument(),
    );
    expect(
      screen.queryByRole("button", { name: /needs attention/i }),
    ).not.toBeInTheDocument();
  });

  it("clears the indicator once a later sync recovers", async () => {
    render(App);
    await waitFor(() => expect(screen.getByText("My Tasks")).toBeInTheDocument());

    emitMockEvent("sync-updated", {
      last_error: "Sync is stuck and needs attention.",
      last_synced: null,
      needs_attention: true,
    });
    await waitFor(() =>
      expect(
        screen.getByRole("button", { name: /needs attention/i }),
      ).toBeInTheDocument(),
    );

    // A successful run clears needs_attention — the indicator must disappear.
    emitMockEvent("sync-updated", {
      last_error: null,
      last_synced: "2026-07-27T10:00:00Z",
      needs_attention: false,
    });
    await waitFor(() =>
      expect(
        screen.queryByRole("button", { name: /needs attention/i }),
      ).not.toBeInTheDocument(),
    );
  });
});
