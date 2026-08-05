// Regression for #172: an error toast raised from inside a modal (Properties,
// the detail panel, a picker) was rendered UNDER that modal — the toast stack
// sat at z-index 1000 while every modal overlay lives at 2000-6000, so the very
// feedback telling the user their save failed was invisible until they closed
// the dialog. Invariant #11: "a protection that doesn't reach the human
// protects nothing." The toast stack must out-stack every modal overlay.
//
// jsdom does not evaluate scoped Svelte stylesheets (getComputedStyle returns
// empty for class-scoped rules — same limitation ThemeContrast/#81 and
// SafeAreaInsets/#160 work around), so this asserts the shipped CSS carries the
// stacking contract: toast z-index > the highest modal overlay z-index. A
// rendered test below proves the toast still appears while a modal is open.

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, fireEvent, waitFor, within } from "@testing-library/svelte";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import App from "../App.svelte";
import { invoke } from "@tauri-apps/api/core";
import pkg from "../../package.json";

const read = (rel) => readFileSync(resolve(process.cwd(), rel), "utf8");

// The <style> block of a component, comments stripped so a commented value
// can't be mistaken for a live declaration.
const styleOf = (src) =>
  src
    .slice(src.indexOf("<style>"), src.indexOf("</style>"))
    .replace(/\/\*[\s\S]*?\*\//g, "");

// Every numeric z-index declared in a style block.
function zIndexes(css) {
  return [...css.matchAll(/z-index:\s*(\d+)/g)].map((m) => Number(m[1]));
}

// Every rule body (between `{` and its matching `}`) whose selector list
// contains `selector`, recursing into @media/@supports at-rules so a rule
// nested in a media query is found too. (Same brace-matching approach as
// SafeAreaInsets.test.js.)
function ruleBodies(css, selector) {
  const bodies = [];
  let i = 0;
  while (i < css.length) {
    const open = css.indexOf("{", i);
    if (open === -1) break;
    const head = css.slice(i, open).trim();
    let depth = 1;
    let j = open + 1;
    for (; j < css.length && depth > 0; j++) {
      if (css[j] === "{") depth++;
      else if (css[j] === "}") depth--;
    }
    const body = css.slice(open + 1, j - 1);
    if (head.startsWith("@")) {
      bodies.push(...ruleBodies(body, selector));
    } else if (new RegExp(`(^|[\\s,>])${selector.replace(".", "\\.")}(\\s|$|[,:.{])`).test(head)) {
      bodies.push(body);
    }
    i = j;
  }
  return bodies;
}

// The (first) z-index declared for a selector across all its rule bodies.
function zIndexOfRule(css, selector) {
  for (const body of ruleBodies(css, selector)) {
    const m = body.match(/z-index:\s*(\d+)/);
    if (m) return Number(m[1]);
  }
  return undefined;
}

// Modal overlay components — each renders a full-window overlay whose highest
// z-index is the level the toast must beat.
const MODAL_COMPONENTS = [
  "src/BulkAdd.svelte",
  "src/Cheatsheet.svelte",
  "src/Properties.svelte",
  "src/TaskDetail.svelte",
  "src/SearchOverlay.svelte",
  "src/ContextMenu.svelte",
  "src/DatePicker.svelte",
  "src/MoveToListPicker.svelte",
  "src/ParentPicker.svelte",
];

describe("#172: toast stack out-stacks every modal overlay", () => {
  const appStyle = styleOf(read("src/App.svelte"));
  const toastZ = zIndexOfRule(appStyle, ".toast-stack");

  it("declares a toast-stack z-index above 3000", () => {
    expect(toastZ).toBeGreaterThan(3000);
  });

  it("out-stacks App's own confirm-overlay and mobile drawer", () => {
    expect(toastZ).toBeGreaterThan(zIndexOfRule(appStyle, ".confirm-overlay"));
    expect(toastZ).toBeGreaterThan(zIndexOfRule(appStyle, ".sidebar-shell"));
    expect(toastZ).toBeGreaterThan(zIndexOfRule(appStyle, ".mobile-drawer-backdrop"));
  });

  it("out-stacks the highest z-index of every modal overlay component", () => {
    for (const file of MODAL_COMPONENTS) {
      const maxZ = Math.max(...zIndexes(styleOf(read(file))));
      expect(maxZ, `${file} declares no z-index`).toBeGreaterThan(0);
      expect(toastZ, `toast (${toastZ}) must beat ${file} (${maxZ})`).toBeGreaterThan(maxZ);
    }
  });
});

// --- Rendered proof: a failing command inside the open detail panel still
// surfaces its error toast, and the panel stays open (non-happy-path: modal
// open when the toast is raised). ---

const lists = [{ id: "L1", title: "Work" }];

function task(id, title) {
  return {
    id, parent_id: null, title, notes: null, status: "needsAction",
    due: null, position: "1", sync_state: "clean", listId: "L1", listTitle: "Work",
  };
}

function mockBackend(failCmd, failMsg) {
  const store = [task("t1", "Open me")];
  invoke.mockImplementation(async (cmd, args) => {
    if (cmd === failCmd) throw new Error(failMsg);
    switch (cmd) {
      case "auth_status": return true;
      case "list_tasklists": return lists;
      case "list_tasks": return store.filter((t) => t.listId === args?.listId);
      case "rename_task": return null;
      case "sync_now": return "ok";
      default: return null;
    }
  });
}

describe("#172: error toast is reachable while the detail panel is open", () => {
  beforeEach(() => {
    localStorage.clear();
    localStorage.setItem("axiotask:view", "L1");
    invoke.mockReset();
  });
  afterEach(() => vi.useRealTimers());

  it("shows the error toast alert AND keeps the detail panel open", async () => {
    // "cannot nest under a subtask..." is an authored refusal shown verbatim,
    // so we get a stable, non-redacted toast to assert on.
    mockBackend("rename_task", "cannot nest under a subtask: subtasks are one level deep");
    const { container } = render(App);
    await waitFor(() => expect(screen.getByText("Open me")).toBeInTheDocument());

    // Open the detail panel for the task.
    await fireEvent.click(screen.getByText("Open me"));
    const panel = await waitFor(() => {
      const p = container.querySelector(".detail-panel");
      expect(p).toBeTruthy();
      return p;
    });

    // Rename inside the panel; the backend rejects it.
    const titleInput = within(panel).getByDisplayValue("Open me");
    await fireEvent.input(titleInput, { target: { value: "Renamed" } });
    await fireEvent.blur(titleInput);

    // The error toast renders...
    const alert = await waitFor(() => screen.getByRole("alert"));
    expect(alert.textContent).toContain("cannot nest under a subtask");
    // ...inside the root toast stack (a sibling of the modal, not nested in it)...
    expect(container.querySelector(".toast-stack")).toContainElement(alert);
    // ...and the detail panel is still open behind it.
    expect(container.querySelector(".detail-panel")).toBeInTheDocument();
  });
});
