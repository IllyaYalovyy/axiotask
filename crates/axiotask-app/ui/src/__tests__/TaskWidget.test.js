import { render, screen, fireEvent } from "@testing-library/svelte";
import { describe, it, expect, vi, afterEach } from "vitest";
import TaskRow from "../TaskRow.svelte";

function makeTask(overrides = {}) {
  return {
    id: "t1",
    parent_id: null,
    title: "Test task",
    notes: null,
    status: "needsAction",
    due: null,
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
const originalMatchMedia = window.matchMedia;
const defaultProps = {
  focused: false,
  editing: false,
  onrename: noop,
  oncanceledit: noop,
  onclick: noop,
  ontoggle: noop,
  onsetdue: noop,
  oncontextmenu: noop,
  onaddsubtask: noop,
  showList: false,
  subtaskProgress: null,
};

afterEach(() => {
  vi.useRealTimers();
  window.matchMedia = originalMatchMedia;
});

describe("GH#18: Rich task widget — metadata always visible", () => {
  describe("Checkbox and title always rendered", () => {
    it("renders a real checkbox in unchecked state", () => {
      render(TaskRow, { props: { ...defaultProps, task: makeTask() } });
      const checkbox = screen.getByRole("checkbox", { name: /mark test task complete/i });
      expect(checkbox).toBeInTheDocument();
      expect(checkbox).not.toBeChecked();
    });

    it("renders a real checked checkbox for completed tasks", () => {
      render(TaskRow, { props: { ...defaultProps, task: makeTask({ status: "completed" }) } });
      expect(screen.getByRole("checkbox", { name: /mark test task incomplete/i })).toBeChecked();
    });

    it("toggling the checkbox does not select the row", async () => {
      const onToggle = vi.fn();
      const onClick = vi.fn();
      render(TaskRow, {
        props: { ...defaultProps, task: makeTask(), ontoggle: onToggle, onclick: onClick },
      });
      await fireEvent.click(screen.getByRole("checkbox", { name: /mark test task complete/i }));
      expect(onToggle).toHaveBeenCalledWith("t1");
      expect(onClick).not.toHaveBeenCalled();
    });

    it("renders task title", () => {
      render(TaskRow, { props: { ...defaultProps, task: makeTask({ title: "Buy milk" }) } });
      expect(screen.getByText("Buy milk")).toBeInTheDocument();
    });
  });

  describe("Metadata row always visible (no hover-to-reveal)", () => {
    it("meta-row is rendered without focus or hover", () => {
      const { container } = render(TaskRow, { props: { ...defaultProps, task: makeTask() } });
      const metaRow = container.querySelector(".meta-row");
      expect(metaRow).toBeInTheDocument();
      // Verify it's not hidden via display:none
      expect(metaRow).toBeVisible();
    });

    it("shows notes icon when task has notes", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ notes: "Some notes here" }) },
      });
      expect(container.querySelector(".meta-row")).toBeInTheDocument();
      expect(screen.getByLabelText("Has notes")).toBeInTheDocument();
    });

    it("does not show notes icon when task has no notes", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ notes: null }) },
      });
      expect(container.querySelector(".notes-icon")).not.toBeInTheDocument();
    });

    it("shows link icon when title contains URL", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ title: "Check https://example.com docs" }) },
      });
      const linkBadge = container.querySelector(".link-badge");
      expect(linkBadge).toBeInTheDocument();
      expect(linkBadge).toHaveAccessibleName(/open link/i);
    });

    it("shows link badge 🔗 when notes contain URL", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ notes: "See http://example.org/page" }) },
      });
      const linkBadge = container.querySelector(".link-badge");
      expect(linkBadge).toBeInTheDocument();
    });

    it("shows link count when multiple URLs found", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ title: "https://a.com and https://b.com" }) },
      });
      const linkBadge = container.querySelector(".link-badge");
      expect(linkBadge.textContent).toContain("2");
    });

    it("does not show link badge when no URLs present", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ title: "No links here", notes: null }) },
      });
      expect(container.querySelector(".link-badge")).not.toBeInTheDocument();
    });

    it("shows relative due date", () => {
      // Build tomorrow's *local* date (date-only dues are interpreted locally;
      // toISOString() would roll the date forward near the UTC day boundary).
      const t = new Date();
      t.setDate(t.getDate() + 1);
      const due = `${t.getFullYear()}-${String(t.getMonth() + 1).padStart(2, "0")}-${String(t.getDate()).padStart(2, "0")}T00:00:00.000Z`;
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ due }) },
      });
      expect(container.querySelector(".due")).toBeInTheDocument();
      expect(container.querySelector(".due").textContent).toBe("tomorrow");
    });

    it("shows 'today' for tasks due today", () => {
      const t = new Date();
      const due = `${t.getFullYear()}-${String(t.getMonth() + 1).padStart(2, "0")}-${String(t.getDate()).padStart(2, "0")}T00:00:00.000Z`;
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ due }) },
      });
      expect(container.querySelector(".due").textContent).toBe("today");
    });

    it("shows overdue styling for past due tasks", () => {
      const past = new Date();
      past.setDate(past.getDate() - 3);
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ due: past.toISOString() }) },
      });
      const due = container.querySelector(".due");
      expect(due.textContent).toContain("overdue");
      expect(due.classList.contains("overdue")).toBe(true);
    });

    it("shows 'no date' when task has no due date", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ due: null }) },
      });
      expect(container.querySelector(".no-due")).toBeInTheDocument();
      expect(container.querySelector(".no-due").textContent).toBe("no date");
    });

    it("shows list tag in smart views", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ listTitle: "Work" }), showList: true },
      });
      expect(container.querySelector(".list-tag")).toBeInTheDocument();
      expect(container.querySelector(".list-tag").textContent).toBe("Work");
    });

    it("hides list tag when showList is false", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ listTitle: "Work" }), showList: false },
      });
      expect(container.querySelector(".list-tag")).not.toBeInTheDocument();
    });
  });

  describe("Subtask progress", () => {
    it("shows progress bar and count when subtaskProgress is provided", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask(), subtaskProgress: { done: 2, total: 5 } },
      });
      expect(container.querySelector(".progress")).toBeInTheDocument();
      expect(container.querySelector(".progress-text").textContent).toBe("2/5");
      expect(container.querySelector(".progress-fill")).toBeInTheDocument();
    });

    it("progress bar width reflects completion percentage", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask(), subtaskProgress: { done: 3, total: 4 } },
      });
      const fill = container.querySelector(".progress-fill");
      expect(fill.style.width).toBe("75%");
    });

    it("does not show progress when subtaskProgress is null", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask(), subtaskProgress: null },
      });
      expect(container.querySelector(".progress")).not.toBeInTheDocument();
    });

    it("clicking progress opens the row's detail (bubbles to the row)", async () => {
      // Subtasks live in the detail panel (#82); the progress badge no longer
      // toggles an inline tree — clicking it (like the rest of the row) opens
      // the panel where the subtasks are.
      const onClick = vi.fn();
      const { container } = render(TaskRow, {
        props: {
          ...defaultProps,
          task: makeTask(),
          onclick: onClick,
          subtaskProgress: { done: 1, total: 2 },
        },
      });
      await fireEvent.click(container.querySelector(".progress"));
      expect(onClick).toHaveBeenCalledWith("t1");
    });
  });

  describe("No inline tree — one level only (#82)", () => {
    it("renders no expand/collapse toggle even for a task with children", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ hasChildren: true, title: "Parent" }) },
      });
      expect(screen.queryByRole("button", { name: /collapse|expand/i })).not.toBeInTheDocument();
      expect(container.querySelector(".tree-toggle")).toBeNull();
    });

    it("renders no subtask connector or indent for a task with a parent", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ parent_id: "p1", title: "Child" }) },
      });
      expect(container.querySelector(".tree-icon.sub")).toBeNull();
      // No depth-based indent — every rendered row sits at the top level.
      expect(container.querySelector(".task-widget").style.paddingLeft).toBe("0.5rem");
    });
  });

  describe("Scheduled marker", () => {
    function dueOn(offsetDays) {
      const t = new Date();
      t.setDate(t.getDate() + offsetDays);
      return `${t.getFullYear()}-${String(t.getMonth() + 1).padStart(2, "0")}-${String(t.getDate()).padStart(2, "0")}T00:00:00.000Z`;
    }

    it("shows a scheduled marker when the task has a due date", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ due: dueOn(1) }) },
      });
      const marker = container.querySelector(".scheduled-marker");
      expect(marker).toBeInTheDocument();
      expect(marker).toBeVisible();
      expect(marker.querySelector(".icon")).toBeInTheDocument();
    });

    it("does not show a scheduled marker when the task has no due date", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ due: null }) },
      });
      expect(container.querySelector(".scheduled-marker")).not.toBeInTheDocument();
    });

    it("marks overdue scheduled tasks with the scheduled marker too", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ due: dueOn(-3) }) },
      });
      expect(container.querySelector(".scheduled-marker")).toBeInTheDocument();
    });

    it("exposes the marker for accessibility via title/aria-label", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ due: dueOn(1) }) },
      });
      const marker = container.querySelector(".scheduled-marker");
      expect(marker.getAttribute("title") || marker.getAttribute("aria-label")).toBeTruthy();
    });
  });

  describe("Touch-friendly", () => {
    it("renders action buttons that are accessible for touch", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask(), focused: true },
      });
      const buttons = container.querySelectorAll(".actions button");
      // Should have reschedule buttons: +, →t, →w, →m
      expect(buttons.length).toBeGreaterThanOrEqual(4);
      // Each button should have a title for accessibility
      buttons.forEach((btn) => {
        expect(btn.getAttribute("title")).toBeTruthy();
      });
    });
  });

  // #4 step 3: a per-row indicator so the user can see which changes haven't
  // reached Google yet (sync_state === "dirty").
  describe("Pending-sync indicator", () => {
    it("shows a pending-sync marker for a dirty (unsynced) task", () => {
      const { container } = render(TaskRow, { props: { ...defaultProps, task: makeTask({ sync_state: "dirty" }) } });
      expect(container.querySelector(".sync-pending")).toBeInTheDocument();
      expect(screen.getByLabelText("Pending sync")).toBeInTheDocument();
    });

    it("shows no pending marker for a clean (synced) task", () => {
      const { container } = render(TaskRow, { props: { ...defaultProps, task: makeTask({ sync_state: "clean" }) } });
      expect(container.querySelector(".sync-pending")).not.toBeInTheDocument();
    });
  });

  // #37: clicking the due area opens the date picker.
  describe("Due-date picker trigger", () => {
    it("clicking the due badge requests the date picker", async () => {
      const onpickdate = vi.fn();
      render(TaskRow, { props: { ...defaultProps, task: makeTask({ due: "2026-06-15T00:00:00Z" }), onpickdate } });
      await fireEvent.click(screen.getByTitle("Pick a date"));
      expect(onpickdate).toHaveBeenCalledWith("t1");
    });

    it("clicking 'no date' requests the date picker for an undated task", async () => {
      const onpickdate = vi.fn();
      render(TaskRow, { props: { ...defaultProps, task: makeTask({ due: null }), onpickdate } });
      await fireEvent.click(screen.getByText("no date"));
      expect(onpickdate).toHaveBeenCalledWith("t1");
    });
  });
});

describe("#50: touch task row interactions", () => {
  it("long-pressing the row toggles bulk selection", async () => {
    vi.useFakeTimers();
    const onselect = vi.fn();
    const { container } = render(TaskRow, {
      props: { ...defaultProps, task: makeTask(), onselect },
    });

    const row = container.querySelector(".task-widget");
    await fireEvent.touchStart(row, { touches: [{ clientX: 40, clientY: 80 }] });
    vi.advanceTimersByTime(500);
    await Promise.resolve();

    expect(onselect).toHaveBeenCalledWith("t1");
  });

  it("does not let a long-press without a generated click suppress the next tap", async () => {
    vi.useFakeTimers();
    const onClick = vi.fn();
    const onselect = vi.fn();
    const { container } = render(TaskRow, {
      props: { ...defaultProps, task: makeTask(), onclick: onClick, onselect },
    });

    const row = container.querySelector(".task-widget");
    await fireEvent.touchStart(row, { touches: [{ clientX: 40, clientY: 80 }] });
    vi.advanceTimersByTime(500);
    await Promise.resolve();
    await fireEvent.touchEnd(row);

    expect(onselect).toHaveBeenCalledWith("t1");
    expect(onClick).not.toHaveBeenCalled();

    await fireEvent.touchStart(row, { touches: [{ clientX: 40, clientY: 80 }] });
    await fireEvent.touchEnd(row);
    await fireEvent.click(row);

    expect(onClick).toHaveBeenCalledWith("t1");
  });

  it("cancels long-press selection when the touch moves", async () => {
    vi.useFakeTimers();
    const onselect = vi.fn();
    const { container } = render(TaskRow, {
      props: { ...defaultProps, task: makeTask(), onselect },
    });

    const row = container.querySelector(".task-widget");
    await fireEvent.touchStart(row, { touches: [{ clientX: 40, clientY: 80 }] });
    await fireEvent.touchMove(row, { touches: [{ clientX: 45, clientY: 112 }] });
    vi.advanceTimersByTime(500);

    expect(onselect).not.toHaveBeenCalled();
  });

  it("swiping right completes the task", async () => {
    const ontoggle = vi.fn();
    const { container } = render(TaskRow, {
      props: { ...defaultProps, task: makeTask(), ontoggle },
    });

    const row = container.querySelector(".task-widget");
    await fireEvent.touchStart(row, { touches: [{ clientX: 20, clientY: 80 }] });
    await fireEvent.touchMove(row, { touches: [{ clientX: 126, clientY: 84 }] });
    await fireEvent.touchEnd(row);

    expect(ontoggle).toHaveBeenCalledWith("t1");
  });

  it("swiping left reveals the action strip without rescheduling", async () => {
    const onsetdue = vi.fn();
    const { container } = render(TaskRow, {
      props: { ...defaultProps, task: makeTask(), onsetdue },
    });

    const row = container.querySelector(".task-widget");
    await fireEvent.touchStart(row, { touches: [{ clientX: 140, clientY: 80 }] });
    await fireEvent.touchMove(row, { touches: [{ clientX: 36, clientY: 84 }] });
    await fireEvent.touchEnd(row);

    expect(onsetdue).not.toHaveBeenCalled();
    expect(row).toHaveClass("swipe-actions-open");
    expect(row.querySelector(".actions")).toHaveAttribute("aria-label", "Task actions");
  });

  it("swiping left on coarse pointers follows the drag and reveals the hidden action strip", async () => {
    window.matchMedia = vi.fn((query) => ({
      matches: query === "(pointer: coarse)",
      media: query,
      onchange: null,
      addListener: vi.fn(),
      removeListener: vi.fn(),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      dispatchEvent: vi.fn(),
    }));
    const onsetdue = vi.fn();
    const { container } = render(TaskRow, {
      props: { ...defaultProps, task: makeTask(), onsetdue },
    });

    const row = container.querySelector(".task-widget");
    await fireEvent.touchStart(row, { touches: [{ clientX: 140, clientY: 80 }] });
    await fireEvent.touchMove(row, { touches: [{ clientX: 72, clientY: 84 }] });

    expect(row).toHaveClass("swipe-actions-peeking");
    expect(row.style.getPropertyValue("--swipe-reveal")).toBe("68px");
    expect(row.querySelector(".actions")).toHaveAttribute("aria-label", "Task actions");

    await fireEvent.touchMove(row, { touches: [{ clientX: 36, clientY: 84 }] });
    await fireEvent.touchEnd(row);

    expect(onsetdue).not.toHaveBeenCalled();
    expect(row).toHaveClass("swipe-actions-open");
    expect(row).not.toHaveClass("swipe-actions-peeking");
    expect(row.style.getPropertyValue("--swipe-reveal")).toBe("0px");
    expect(row.querySelector(".actions")).toHaveAttribute("aria-label", "Task actions");
  });

  it("keeps the action strip hidden by default on coarse pointers", () => {
    window.matchMedia = vi.fn((query) => ({
      matches: query === "(pointer: coarse)",
      media: query,
      onchange: null,
      addListener: vi.fn(),
      removeListener: vi.fn(),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      dispatchEvent: vi.fn(),
    }));

    const { container } = render(TaskRow, {
      props: { ...defaultProps, task: makeTask(), focused: true },
    });

    const row = container.querySelector(".task-widget");
    expect(row).not.toHaveClass("swipe-actions-open");
    expect(row).not.toHaveClass("swipe-actions-peeking");
    expect(row.querySelector(".actions")).toHaveAttribute("aria-label", "Task actions");
  });

  it("a revealed action strip still lets the user choose Tomorrow explicitly", async () => {
    const onsetdue = vi.fn();
    const { container } = render(TaskRow, {
      props: { ...defaultProps, task: makeTask(), onsetdue },
    });

    const row = container.querySelector(".task-widget");
    await fireEvent.touchStart(row, { touches: [{ clientX: 140, clientY: 80 }] });
    await fireEvent.touchMove(row, { touches: [{ clientX: 36, clientY: 84 }] });
    await fireEvent.touchEnd(row);

    const tomorrow = [...row.querySelectorAll(".actions button")].find(
      (b) => b.textContent === "→t"
    );
    await fireEvent.click(tomorrow);

    expect(onsetdue).toHaveBeenCalledWith("t1", "Tomorrow");
  });
});
