import { render, screen, waitFor } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import App from "../App.svelte";
import { mockInvoke, resetMocks } from "../test-setup.js";

/**
 * Regression: the app must never drive the window through setSize/setPosition
 * during startup. Doing so wedges WebKitGTK's IPC/repaint path on some Linux
 * setups, which manifested as the app being stuck forever on "Loading...".
 * Geometry restore is disabled; startup must not call setSize/setPosition even
 * when a saved geometry exists, and the app must still load.
 */
describe("No window resize during startup", () => {
  beforeEach(() => {
    resetMocks();
    invoke.mockClear();
    getCurrentWindow().setSize.mockClear();
    getCurrentWindow().setPosition.mockClear();
    localStorage.clear();
    localStorage.setItem("axiotask:windowGeometry", JSON.stringify({ width: 1052, height: 752, x: 0, y: 0 }));
    localStorage.setItem("axiotask:view", "missed");
  });

  it("loads without calling setSize/setPosition", async () => {
    mockInvoke("auth_status", () => false);
    mockInvoke("list_tasklists", () => [{ id: "L1", title: "My Tasks" }]);
    mockInvoke("list_tasks", () => []);

    render(App);

    await waitFor(() => {
      expect(screen.queryByText("Loading...")).not.toBeInTheDocument();
    });

    expect(getCurrentWindow().setSize).not.toHaveBeenCalled();
    expect(getCurrentWindow().setPosition).not.toHaveBeenCalled();
  });
});
