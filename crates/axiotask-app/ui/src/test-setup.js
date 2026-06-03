import "@testing-library/jest-dom/vitest";
import { vi } from "vitest";

// Mock Tauri APIs globally for all tests
// Each test can override these via mockInvoke()

const handlers = {};

export function mockInvoke(cmd, handler) {
  handlers[cmd] = handler;
}

export function resetMocks() {
  Object.keys(handlers).forEach((k) => delete handlers[k]);
}

// Mock @tauri-apps/api/core
vi.mock("@tauri-apps/api/core", () => ({
  invoke: vi.fn(async (cmd, args) => {
    if (handlers[cmd]) return handlers[cmd](args);
    // Default handlers for common commands
    switch (cmd) {
      case "auth_status":
        return false;
      case "list_tasklists":
        return [];
      case "list_tasks":
        return [];
      case "create_list":
        return { id: "list-1", title: args?.title || "My Tasks" };
      case "create_task":
        return {
          id: "task-" + Math.random().toString(36).slice(2, 8),
          parent_id: args?.parentId || null,
          title: args?.title || "",
          notes: null,
          status: "needsAction",
          due: null,
          position: "99999999999999",
          sync_state: "dirty",
        };
      case "sync_now":
        return "pulled=0, pushed=0, conflicts=0, deleted=0";
      default:
        return null;
    }
  }),
}));

// Mock @tauri-apps/api/window
const mockWindow = {
  setTitle: vi.fn().mockResolvedValue(undefined),
  outerSize: vi.fn().mockResolvedValue({ width: 1024, height: 768 }),
  outerPosition: vi.fn().mockResolvedValue({ x: 100, y: 50 }),
  setSize: vi.fn().mockResolvedValue(undefined),
  setPosition: vi.fn().mockResolvedValue(undefined),
};
vi.mock("@tauri-apps/api/window", () => ({
  getCurrentWindow: () => mockWindow,
  LogicalSize: class LogicalSize { constructor(w, h) { this.width = w; this.height = h; } },
  LogicalPosition: class LogicalPosition { constructor(x, y) { this.x = x; this.y = y; } },
}));
