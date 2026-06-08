import { render, screen } from "@testing-library/svelte";
import { describe, it, expect, vi } from "vitest";
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

describe("GH#18: Rich task widget — metadata always visible", () => {
  describe("Checkbox and title always rendered", () => {
    it("renders checkbox in unchecked state", () => {
      const { container } = render(TaskRow, { props: { ...defaultProps, task: makeTask() } });
      expect(container.querySelector(".checkbox")).toBeInTheDocument();
      expect(container.querySelector(".checkbox").textContent).toBe("☐");
    });

    it("renders checkbox in checked state for completed tasks", () => {
      const { container } = render(TaskRow, { props: { ...defaultProps, task: makeTask({ status: "completed" }) } });
      expect(container.querySelector(".checkbox").textContent).toBe("☑");
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

    it("shows notes badge 📝 when task has notes", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ notes: "Some notes here" }) },
      });
      expect(container.querySelector(".meta-row")).toBeInTheDocument();
      expect(container.querySelector(".meta-row").textContent).toContain("📝");
    });

    it("does not show notes badge when task has no notes", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ notes: null }) },
      });
      expect(container.querySelector(".meta-row").textContent).not.toContain("📝");
    });

    it("shows link badge 🔗 when title contains URL", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ title: "Check https://example.com docs" }) },
      });
      const linkBadge = container.querySelector(".link-badge");
      expect(linkBadge).toBeInTheDocument();
      expect(linkBadge.textContent).toContain("🔗");
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

    it("shows recurrence badge 🔁 with a human summary when the notes carry a rule", () => {
      const { container } = render(TaskRow, {
        props: {
          ...defaultProps,
          task: makeTask({ title: "Daily standup", notes: "[[recur:FREQ=WEEKLY;BYDAY=MO,WE,FR]]" }),
        },
      });
      const text = container.querySelector(".meta-row").textContent;
      expect(text).toContain("🔁");
      expect(text).toContain("Weekly on Mon, Wed, Fri");
    });

    it("does not show a recurrence badge for a plain task", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ title: "One-off task" }) },
      });
      expect(container.querySelector(".meta-row").textContent).not.toContain("🔁");
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
      expect(marker.textContent).toContain("📅");
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
});
