import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";
import pkg from "../../package.json";

function mockBackend(lists = [], tasks = []) {
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return tasks.filter(t => t.listId === args?.listId);
      case "sync_now": return "ok";
      default: return null;
    }
  });
}

const lists = [{ id: "L1", title: "Work" }];

async function renderApp() {
  mockBackend(lists, []);
  render(App);
  await waitFor(() => expect(screen.getByRole("button", { name: /about/i })).toBeInTheDocument());
}

async function openAbout() {
  await renderApp();
  await fireEvent.click(screen.getByRole("button", { name: /about/i }));
  await waitFor(() => expect(screen.getByRole("dialog", { name: /about/i })).toBeInTheDocument());
}

describe("About dialog", () => {
  beforeEach(() => {
    invoke.mockReset();
  });

  it("has an About trigger in the sidebar", async () => {
    await renderApp();
    expect(screen.getByRole("button", { name: /about/i })).toBeInTheDocument();
  });

  it("opens the About dialog when the trigger is clicked", async () => {
    await renderApp();
    expect(screen.queryByRole("dialog", { name: /about/i })).not.toBeInTheDocument();
    await fireEvent.click(screen.getByRole("button", { name: /about/i }));
    await waitFor(() => {
      expect(screen.getByRole("dialog", { name: /about/i })).toBeInTheDocument();
    });
  });

  it("shows the app name", async () => {
    await openAbout();
    const dialog = screen.getByRole("dialog", { name: /about/i });
    expect(dialog).toHaveTextContent("axiotask");
  });

  it("shows the current version from package.json", async () => {
    await openAbout();
    const dialog = screen.getByRole("dialog", { name: /about/i });
    expect(dialog).toHaveTextContent(`v${pkg.version}`);
  });

  it("shows the GitHub repository link", async () => {
    await openAbout();
    const link = screen.getByRole("link", { name: /github\.com\/yalovoy\/axiotask/i });
    expect(link).toHaveAttribute("href", "https://github.com/yalovoy/axiotask");
  });

  it("closes on Escape", async () => {
    await openAbout();
    await fireEvent.keyDown(window, { key: "Escape" });
    await waitFor(() => {
      expect(screen.queryByRole("dialog", { name: /about/i })).not.toBeInTheDocument();
    });
  });

  it("closes when the close button is clicked", async () => {
    await openAbout();
    await fireEvent.click(screen.getByRole("button", { name: /close/i }));
    await waitFor(() => {
      expect(screen.queryByRole("dialog", { name: /about/i })).not.toBeInTheDocument();
    });
  });
});
