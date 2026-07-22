// Regression for #81: dark-theme (and light-theme) unreadable text.
//
// `.no-due` ("no date") and the `.tree-icon.sub` subtask connector (└) used
// --border-faint as a *text* color, giving ~1:1 contrast (invisible). The
// focused-row `.actions button` used --fg-muted on --bg-elevated (~4.2:1), too
// dim. This test resolves the CSS-variable token each rule uses against the
// theme.css palette (both themes) and asserts real contrast, so a regression
// back to a border/near-invisible token fails deterministically.

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

// vitest runs with cwd at the ui package root.
const src = (rel) => readFileSync(resolve(process.cwd(), "src", rel), "utf8");

const themeCss = src("theme.css");
const taskRow = src("TaskRow.svelte");

// --- WCAG relative-luminance contrast -------------------------------------
function srgbToLinear(c) {
  c /= 255;
  return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
}
function luminance(hex) {
  let h = hex.replace("#", "");
  if (h.length === 3) h = h.split("").map((x) => x + x).join("");
  const r = parseInt(h.slice(0, 2), 16);
  const g = parseInt(h.slice(2, 4), 16);
  const b = parseInt(h.slice(4, 6), 16);
  return 0.2126 * srgbToLinear(r) + 0.7152 * srgbToLinear(g) + 0.0722 * srgbToLinear(b);
}
function contrast(a, b) {
  const l1 = luminance(a);
  const l2 = luminance(b);
  const [hi, lo] = l1 >= l2 ? [l1, l2] : [l2, l1];
  return (hi + 0.05) / (lo + 0.05);
}

// --- parse theme.css into per-theme token maps ----------------------------
function tokenMap(block) {
  const map = {};
  const re = /(--[\w-]+):\s*(#[0-9a-fA-F]{3,6})/g;
  let m;
  while ((m = re.exec(block)) !== null) map[m[1]] = m[2];
  return map;
}
const lightIdx = themeCss.indexOf('[data-theme="light"]');
const THEMES = {
  dark: tokenMap(themeCss.slice(0, lightIdx)),
  light: tokenMap(themeCss.slice(lightIdx)),
};

// --- extract the color token a TaskRow rule uses --------------------------
function colorTokenOf(selector) {
  const re = new RegExp(
    `${selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\s*\\{[^}]*color:\\s*var\\((--[\\w-]+)\\)`,
  );
  const m = taskRow.match(re);
  if (!m) throw new Error(`no color token found for ${selector}`);
  return m[1];
}

describe("theme contrast (#81)", () => {
  const noDueTok = colorTokenOf(".no-due");
  const subTok = colorTokenOf(".tree-icon.sub");
  const actionTok = colorTokenOf(".actions button");

  it("does not use a border token as a text color", () => {
    for (const tok of [noDueTok, subTok, actionTok]) {
      expect(tok).not.toMatch(/border/);
    }
  });

  for (const [name, tokens] of Object.entries(THEMES)) {
    describe(name, () => {
      it("'no date' placeholder is readable on the row background", () => {
        // Line-2 metadata shows on focused (--bg-active) / base (--bg) rows.
        expect(contrast(tokens[noDueTok], tokens["--bg"])).toBeGreaterThanOrEqual(4.5);
        expect(contrast(tokens[noDueTok], tokens["--bg-active"])).toBeGreaterThanOrEqual(3.0);
      });

      it("subtask connector is visible in the detail panel", () => {
        expect(contrast(tokens[subTok], tokens["--bg-panel"])).toBeGreaterThanOrEqual(2.0);
      });

      it("focused-row action button is readable on --bg-elevated", () => {
        expect(contrast(tokens[actionTok], tokens["--bg-elevated"])).toBeGreaterThanOrEqual(4.5);
      });
    });
  }
});
