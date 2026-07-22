import { render, fireEvent } from "@testing-library/svelte";
import { describe, it, expect, vi } from "vitest";
import { invoke } from "@tauri-apps/api/core";
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
  showList: false,
  subtaskProgress: null,
};

describe("GH#21: URL detection and link opening", () => {
  describe("URL extraction from title and notes", () => {
    it("detects https URL in title", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ title: "Read https://example.com/article" }) },
      });
      expect(container.querySelector(".link-badge")).toBeInTheDocument();
    });

    it("detects http URL in notes", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ notes: "Reference: http://docs.example.org/guide" }) },
      });
      expect(container.querySelector(".link-badge")).toBeInTheDocument();
    });

    it("detects URLs in both title and notes", () => {
      const { container } = render(TaskRow, {
        props: {
          ...defaultProps,
          task: makeTask({
            title: "See https://a.com",
            notes: "Also https://b.com",
          }),
        },
      });
      const badge = container.querySelector(".link-badge");
      expect(badge.textContent).toContain("2");
    });

    it("does not detect non-URL text", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ title: "No links here", notes: "plain text" }) },
      });
      expect(container.querySelector(".link-badge")).not.toBeInTheDocument();
    });

    it("handles URLs with query params and fragments", () => {
      const { container } = render(TaskRow, {
        props: {
          ...defaultProps,
          task: makeTask({ title: "Check https://example.com/path?q=1&b=2#section" }),
        },
      });
      expect(container.querySelector(".link-badge")).toBeInTheDocument();
    });
  });

  describe("Link badge display", () => {
    it("shows an accessible link icon without count for single URL", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ title: "Visit https://example.com" }) },
      });
      const badge = container.querySelector(".link-badge");
      expect(badge).toHaveAccessibleName("Open link");
      expect(badge).not.toHaveTextContent("1");
    });

    it("shows link count for multiple URLs", () => {
      const { container } = render(TaskRow, {
        props: {
          ...defaultProps,
          task: makeTask({ title: "https://a.com https://b.com https://c.com" }),
        },
      });
      const badge = container.querySelector(".link-badge");
      expect(badge.textContent).toContain("3");
      expect(badge).toHaveAccessibleName("Open link");
    });

    it("badge has title attribute with first URL", () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ title: "See https://example.com/page" }) },
      });
      const badge = container.querySelector(".link-badge");
      expect(badge.getAttribute("title")).toBe("https://example.com/page");
    });
  });

  describe("Click opens URL in system browser", () => {
    it("calls open_url command on badge click", async () => {
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ title: "Visit https://example.com" }) },
      });
      const badge = container.querySelector(".link-badge");
      await fireEvent.click(badge);
      expect(invoke).toHaveBeenCalledWith("open_url", { url: "https://example.com" });
    });

    it("opens first URL when multiple exist", async () => {
      const { container } = render(TaskRow, {
        props: {
          ...defaultProps,
          task: makeTask({ title: "https://first.com and https://second.com" }),
        },
      });
      const badge = container.querySelector(".link-badge");
      await fireEvent.click(badge);
      expect(invoke).toHaveBeenCalledWith("open_url", { url: "https://first.com" });
    });

    it("does not propagate click to row handler", async () => {
      const onclick = vi.fn();
      const { container } = render(TaskRow, {
        props: { ...defaultProps, task: makeTask({ title: "Visit https://example.com" }), onclick },
      });
      const badge = container.querySelector(".link-badge");
      await fireEvent.click(badge);
      expect(onclick).not.toHaveBeenCalled();
    });
  });
});
