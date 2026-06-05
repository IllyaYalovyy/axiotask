import { render, fireEvent, waitFor } from "@testing-library/svelte";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import TaskRow from "../TaskRow.svelte";
import App from "../App.svelte";

function makeTask(overrides = {}) {
  return {
    id: "t1",
    parent_id: null,
    title: "Test task",
    notes: null,
    status: "needsAction",
    due: "2026-06-03T00:00:00.000Z",
    position: "00001",
    sync_state: "clean",
    listId: "L1",
    listTitle: "Work",
    depth: 0,
    hasChildren: false,
    isCollapsed: false,
    ...overrides,
  };
}

const noop = () => {};

function renderRow(overrides = {}, taskOverrides = {}) {
  const onsetdue = vi.fn();
  const props = {
    task: makeTask(taskOverrides),
    focused: false,
    editing: false,
    onrename: noop,
    oncanceledit: noop,
    onclick: noop,
    ontoggle: noop,
    onsetdue,
    oncontextmenu: noop,
    onaddsubtask: noop,
    showList: false,
    subtaskProgress: null,
    ...overrides,
  };
  const result = render(TaskRow, { props });
  return { ...result, onsetdue };
}

describe("GH#10: One-click reschedule buttons", () => {
  describe("Button visibility", () => {
    it("renders →t, →w, →m buttons on every task row", () => {
      const { container } = renderRow();
      const actions = container.querySelector(".actions");
      expect(actions).toBeInTheDocument();
      const buttons = actions.querySelectorAll("button");
      const labels = [...buttons].map((b) => b.textContent);
      expect(labels).toContain("→t");
      expect(labels).toContain("→w");
      expect(labels).toContain("→m");
    });

    it("renders ✕ (clear) button when task has a due date", () => {
      const { container } = renderRow({}, { due: "2026-06-10T00:00:00.000Z" });
      const buttons = container.querySelectorAll(".actions button");
      const labels = [...buttons].map((b) => b.textContent);
      expect(labels).toContain("✕");
    });

    it("does not render ✕ button when task has no due date", () => {
      const { container } = renderRow({}, { due: null });
      const buttons = container.querySelectorAll(".actions button");
      const labels = [...buttons].map((b) => b.textContent);
      expect(labels).not.toContain("✕");
    });

    it("shows actions when focused", () => {
      const { container } = renderRow({ focused: true });
      const actions = container.querySelector(".actions");
      // focused class on parent triggers display:flex via CSS
      expect(container.querySelector(".task-widget.focused")).toBeInTheDocument();
      expect(actions).toBeInTheDocument();
    });
  });

  describe("Click interactions trigger onsetdue", () => {
    it("clicking →t calls onsetdue with Tomorrow", async () => {
      const { container, onsetdue } = renderRow();
      const btn = [...container.querySelectorAll(".actions button")].find(
        (b) => b.textContent === "→t"
      );
      await fireEvent.click(btn);
      expect(onsetdue).toHaveBeenCalledWith("t1", "Tomorrow");
    });

    it("clicking →o calls onsetdue with Today", async () => {
      const { container, onsetdue } = renderRow();
      const btn = [...container.querySelectorAll(".actions button")].find(
        (b) => b.textContent === "→o"
      );
      await fireEvent.click(btn);
      expect(onsetdue).toHaveBeenCalledWith("t1", "Today");
    });

    it("clicking →w calls onsetdue with NextWeek", async () => {
      const { container, onsetdue } = renderRow();
      const btn = [...container.querySelectorAll(".actions button")].find(
        (b) => b.textContent === "→w"
      );
      await fireEvent.click(btn);
      expect(onsetdue).toHaveBeenCalledWith("t1", "NextWeek");
    });

    it("clicking →m calls onsetdue with NextMonth", async () => {
      const { container, onsetdue } = renderRow();
      const btn = [...container.querySelectorAll(".actions button")].find(
        (b) => b.textContent === "→m"
      );
      await fireEvent.click(btn);
      expect(onsetdue).toHaveBeenCalledWith("t1", "NextMonth");
    });

    it("clicking ✕ calls onsetdue with Clear", async () => {
      const { container, onsetdue } = renderRow({}, { due: "2026-06-10T00:00:00.000Z" });
      const btn = [...container.querySelectorAll(".actions button")].find(
        (b) => b.textContent === "✕"
      );
      await fireEvent.click(btn);
      expect(onsetdue).toHaveBeenCalledWith("t1", "Clear");
    });
  });

  describe("Buttons have accessible titles", () => {
    it("→t has title 'Tomorrow (t)'", () => {
      const { container } = renderRow();
      const btn = [...container.querySelectorAll(".actions button")].find(
        (b) => b.textContent === "→t"
      );
      expect(btn.getAttribute("title")).toBe("Tomorrow (t)");
    });

    it("→w has title 'Next week (w)'", () => {
      const { container } = renderRow();
      const btn = [...container.querySelectorAll(".actions button")].find(
        (b) => b.textContent === "→w"
      );
      expect(btn.getAttribute("title")).toBe("Next week (w)");
    });

    it("→m has title 'Next month (m)'", () => {
      const { container } = renderRow();
      const btn = [...container.querySelectorAll(".actions button")].find(
        (b) => b.textContent === "→m"
      );
      expect(btn.getAttribute("title")).toBe("Next month (m)");
    });

    it("✕ has title 'Remove date (r)'", () => {
      const { container } = renderRow({}, { due: "2026-06-10T00:00:00.000Z" });
      const btn = [...container.querySelectorAll(".actions button")].find(
        (b) => b.textContent === "✕"
      );
      expect(btn.getAttribute("title")).toBe("Remove date (r)");
    });
  });

  describe("Click does not propagate to row", () => {
    it("clicking reschedule button does not trigger row onclick", async () => {
      const onclick = vi.fn();
      const { container } = render(TaskRow, {
        props: {
          task: makeTask(),
          focused: false,
          editing: false,
          onrename: noop,
          oncanceledit: noop,
          onclick,
          ontoggle: noop,
          onsetdue: noop,
          oncontextmenu: noop,
          onaddsubtask: noop,
          showList: false,
          subtaskProgress: null,
        },
      });
      const btn = [...container.querySelectorAll(".actions button")].find(
        (b) => b.textContent === "→t"
      );
      await fireEvent.click(btn);
      expect(onclick).not.toHaveBeenCalled();
    });
  });
});

describe("GH#10: Reschedule integration — task moves between views", () => {
  const DAY = 86400000;
  const baseNow = new Date();
  baseNow.setHours(0, 0, 0, 0);
  function daysFromNow(n) {
    return new Date(baseNow.getTime() + n * DAY).toISOString();
  }

  beforeEach(() => {
    localStorage.clear();
    localStorage.setItem("axiotask:view", "focus");
    invoke.mockReset();
  });

  it("clicking →w on overdue task calls set_due and task disappears from Focus", async () => {
    const tasks = [
      {
        id: "t1",
        parent_id: null,
        title: "Overdue task",
        notes: null,
        status: "needsAction",
        due: daysFromNow(-2),
        position: "1",
        sync_state: "clean",
        listId: "L1",
        listTitle: "Work",
      },
    ];

    let setDueCalled = false;
    invoke.mockImplementation(async (cmd, args) => {
      switch (cmd) {
        case "auth_status":
          return true;
        case "list_tasklists":
          return [{ id: "L1", title: "Work" }];
        case "list_tasks":
          // After set_due, task has future date (no longer in focus)
          if (setDueCalled)
            return tasks.map((t) => ({ ...t, due: daysFromNow(14) }));
          return tasks;
        case "set_due":
          setDueCalled = true;
          expect(args.id).toBe("t1");
          expect(args.mv).toBe("NextWeek");
          return null;
        case "sync_now":
          return "ok";
        default:
          return null;
      }
    });

    const { container } = render(App);
    await waitFor(() =>
      expect(container.querySelector(".task-widget")).toBeInTheDocument()
    );

    // Click the →w button
    const btn = [...container.querySelectorAll(".actions button")].find(
      (b) => b.textContent === "→w"
    );
    expect(btn).toBeInTheDocument();
    await fireEvent.click(btn);

    // Task should disappear from Focus view (now due in 14 days, beyond this week)
    await waitFor(() =>
      expect(container.querySelector(".task-widget")).not.toBeInTheDocument()
    );
    expect(setDueCalled).toBe(true);
  });
});
