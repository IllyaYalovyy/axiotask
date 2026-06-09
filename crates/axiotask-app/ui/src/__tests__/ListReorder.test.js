import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import App from "../App.svelte";

const lists = [
  { id: "L1", title: "Work" },
  { id: "L2", title: "Home" },
  { id: "L3", title: "Errands" },
];

function mockBackend() {
  invoke.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return [];
      case "sync_now": return "ok";
      default: return null;
    }
  });
}

// The sidebar list buttons, in document order, by leading title text.
function listButtonTitles() {
  return [...document.querySelectorAll(".lists button")].map((b) =>
    b.textContent.trim().split(/\s{2,}|\n/)[0].trim(),
  );
}

const dt = { dataTransfer: { setData: () => {}, getData: () => "", effectAllowed: "", dropEffect: "" } };

async function renderApp() {
  mockBackend();
  render(App);
  await waitFor(() => expect(screen.getByText("Work")).toBeInTheDocument());
}

function listButton(title) {
  return [...document.querySelectorAll(".lists button")].find((b) =>
    b.textContent.includes(title),
  );
}

// The whole row (drag/drop target) for a given list title.
function listRow(title) {
  return listButton(title)?.closest(".list-row");
}

// The dedicated drag handle within a list's row.
function dragHandle(title) {
  return listRow(title)?.querySelector(".list-drag-handle");
}

describe("Sidebar: reorder lists", () => {
  beforeEach(() => { localStorage.clear(); invoke.mockReset(); });

  it("renders lists in backend order by default", async () => {
    await renderApp();
    expect(listButtonTitles()).toEqual(["Work", "Home", "Errands"]);
  });

  it("applies a saved custom order", async () => {
    localStorage.setItem("axiotask:listOrder", JSON.stringify(["L3", "L1", "L2"]));
    await renderApp();
    expect(listButtonTitles()).toEqual(["Errands", "Work", "Home"]);
  });

  it("each list has a dedicated drag handle", async () => {
    await renderApp();
    expect(dragHandle("Work")).toBeTruthy();
    expect(dragHandle("Home")).toBeTruthy();
    expect(dragHandle("Errands")).toBeTruthy();
  });

  it("dragging by the handle onto another row reorders and persists", async () => {
    await renderApp();
    const handle = dragHandle("Errands");
    const target = listRow("Work");

    await fireEvent.dragStart(handle, dt);
    await fireEvent.dragOver(target, dt);
    await fireEvent.drop(target, dt);

    // Errands moved to the front (inserted before Work).
    await waitFor(() => expect(listButtonTitles()).toEqual(["Errands", "Work", "Home"]));
    // Persisted for next launch.
    expect(JSON.parse(localStorage.getItem("axiotask:listOrder"))).toEqual(["L3", "L1", "L2"]);
  });

  it("clicking a list (not the handle) still selects it", async () => {
    await renderApp();
    await fireEvent.click(listButton("Home"));
    // Selecting a list sets it as the active view → its tasks load.
    await waitFor(() =>
      expect(invoke.mock.calls.some((c) => c[0] === "list_tasks")).toBe(true),
    );
  });

  it("a new list (absent from saved order) appears at the end", async () => {
    localStorage.setItem("axiotask:listOrder", JSON.stringify(["L2", "L1"]));
    await renderApp();
    // L3 is not in the saved order, so it sorts after the known ones.
    expect(listButtonTitles()).toEqual(["Home", "Work", "Errands"]);
  });
});
