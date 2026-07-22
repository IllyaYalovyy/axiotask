// Single source of truth for keyboard shortcuts.
//
// This registry backs the cheatsheet overlay so the documented shortcuts can
// never drift from a hand-maintained list. Each category groups related
// bindings; each binding declares the key(s) that trigger it and a short
// human-readable description.
//
// See designs/RFC-007-keyboard-navigation.md (the cheatsheet is generated from
// the same registry) and designs/RFC-008-keystroke-date-moves.md.

/**
 * @typedef {Object} Shortcut
 * @property {string[]} keys  One or more keys that trigger the action (alternatives).
 * @property {string} description  Short, human-readable label.
 *
 * @typedef {Object} ShortcutCategory
 * @property {string} name  Display name of the category.
 * @property {Shortcut[]} shortcuts  Bindings in this category.
 */

/** @type {ShortcutCategory[]} */
export const SHORTCUT_CATEGORIES = [
  {
    name: "Navigation",
    shortcuts: [
      { keys: ["j", "↓"], description: "Next task" },
      { keys: ["k", "↑"], description: "Previous task" },
    ],
  },
  {
    name: "Tasks",
    shortcuts: [
      { keys: ["n"], description: "New task" },
      { keys: ["Enter"], description: "Open / close detail panel" },
      { keys: ["e"], description: "Edit title" },
      { keys: ["Space"], description: "Toggle complete" },
      { keys: ["d"], description: "Delete" },
      { keys: ["x"], description: "Select / deselect (bulk)" },
    ],
  },
  {
    name: "Due dates",
    shortcuts: [
      { keys: ["o"], description: "Today" },
      { keys: ["t"], description: "Tomorrow" },
      { keys: ["w"], description: "Next week" },
      { keys: ["m"], description: "Next month" },
      { keys: ["r"], description: "Remove due date" },
    ],
  },
  {
    name: "Organize",
    shortcuts: [
      { keys: ["Alt+↑"], description: "Move up" },
      { keys: ["Alt+↓"], description: "Move down" },
      { keys: ["Ctrl+M"], description: "Move to list" },
    ],
  },
  {
    name: "App",
    shortcuts: [
      { keys: ["/"], description: "Search" },
      { keys: [","], description: "Open Properties" },
      { keys: ["?"], description: "This cheatsheet" },
      { keys: ["Esc"], description: "Close / clear selection" },
    ],
  },
];

/**
 * Format a shortcut's keys for display, e.g. ["j", "↓"] -> "j / ↓".
 * @param {string[]} keys
 * @returns {string}
 */
export function formatKeys(keys) {
  return keys.join(" / ");
}
