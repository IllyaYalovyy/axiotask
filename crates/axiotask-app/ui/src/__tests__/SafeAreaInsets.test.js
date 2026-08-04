// Regression for #160: safe-area insets on notched / gesture-nav devices.
//
// Android (and iOS) draw the status bar, notch, and gesture navigation pill on
// top of an edge-to-edge webview. Without `viewport-fit=cover` the webview is
// letterboxed inside the safe area; WITH it, our fixed/edge-hugging chrome —
// the top toolbar, the bottom-right FAB, and the slide-in drawer — would sit
// UNDER the system UI unless it is padded by `env(safe-area-inset-*)`.
//
// jsdom does not evaluate scoped component stylesheets (getComputedStyle
// returns empty for Svelte's class-scoped rules — verified), and it cannot
// simulate a physical notch, so — as with ThemeContrast (#81) — this asserts
// the shipped CSS/markup carries the inset contract rather than a pixel.

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const read = (rel) => readFileSync(resolve(process.cwd(), rel), "utf8");

const indexHtml = read("index.html");
const appSvelte = read("src/App.svelte");
const taskDetailSvelte = read("src/TaskDetail.svelte");

// The <style> block of a component, where the chrome lives — comments stripped
// so a `/* … */` before an `@media` can't hide the selector token from the
// rule-head parser.
const styleOf = (src) =>
  src
    .slice(src.indexOf("<style>"), src.indexOf("</style>"))
    .replace(/\/\*[\s\S]*?\*\//g, "");

const styleBlock = styleOf(appSvelte);
const detailStyleBlock = styleOf(taskDetailSvelte);

// Return every CSS declaration body (between `{` and its matching `}`) whose
// selector list contains `selector`. Recurses into at-rules (@media/@supports)
// so a mobile-override rule nested in a media query is found too — a selector
// can appear as a base rule PLUS one or more media-query overrides.
function ruleBodies(css, selector) {
  const bodies = [];
  let i = 0;
  while (i < css.length) {
    const open = css.indexOf("{", i);
    if (open === -1) break;
    const head = css.slice(i, open).trim();
    // brace-match to find this rule's close, skipping nested blocks
    let depth = 1;
    let j = open + 1;
    for (; j < css.length && depth > 0; j++) {
      if (css[j] === "{") depth++;
      else if (css[j] === "}") depth--;
    }
    const body = css.slice(open + 1, j - 1);
    if (head.startsWith("@")) {
      // at-rule wrapper — descend into its inner rules
      bodies.push(...ruleBodies(body, selector));
    } else if (
      new RegExp(`(^|[\\s,>])${selector.replace(".", "\\.")}(\\s|$|[,:.])`).test(head)
    ) {
      bodies.push(body);
    }
    i = j;
  }
  return bodies;
}

describe("#160: safe-area insets for notched / gesture-nav devices", () => {
  it("declares viewport-fit=cover so the webview draws edge to edge", () => {
    const viewport = indexHtml.match(/<meta\s+name=["']viewport["'][^>]*>/i)?.[0] || "";
    expect(viewport).toMatch(/viewport-fit\s*=\s*cover/);
  });

  it("pads the toolbar past the status bar / notch (top + side insets)", () => {
    const bodies = ruleBodies(styleBlock, ".toolbar");
    // Base rule + the <=700px mobile override both set padding; every padding
    // declaration on the toolbar must fold in the inset so neither layout ends
    // up under the status bar.
    const paddingBodies = bodies.filter((b) => /(^|[\s;{])padding\s*:/.test(b));
    expect(paddingBodies.length).toBeGreaterThanOrEqual(2);
    for (const b of paddingBodies) {
      expect(b).toMatch(/env\(safe-area-inset-top/);
      expect(b).toMatch(/env\(safe-area-inset-right/);
      expect(b).toMatch(/env\(safe-area-inset-left/);
    }
  });

  it("lifts the FAB above the bottom gesture pill and off the right edge", () => {
    const [fab] = ruleBodies(styleBlock, ".mobile-fab");
    expect(fab).toBeTruthy();
    expect(fab).toMatch(/bottom:\s*calc\([^)]*env\(safe-area-inset-bottom/);
    expect(fab).toMatch(/right:\s*calc\([^)]*env\(safe-area-inset-right/);
  });

  it("insets the slide-in drawer from the top, bottom, and left edges", () => {
    const bodies = ruleBodies(styleBlock, ".sidebar-shell");
    const joined = bodies.join("\n");
    expect(joined).toMatch(/env\(safe-area-inset-top/);
    expect(joined).toMatch(/env\(safe-area-inset-bottom/);
    expect(joined).toMatch(/env\(safe-area-inset-left/);
  });

  // #166: on mobile the TaskDetail panel drops its docked-sidebar layout for a
  // full-screen `position: fixed; inset: 0` overlay. Its content is anchored to
  // the TOP edge (the panel-header with the close/nav buttons is the first
  // child), so without inset-aware padding the header renders UNDER the status
  // bar / notch — and the only way to close the panel becomes unreachable. The
  // full-screen rule must fold all four insets into its padding.
  it("insets the full-screen TaskDetail panel so its header clears the status bar", () => {
    const bodies = ruleBodies(detailStyleBlock, ".detail-panel");
    // The fullscreen override is the rule that pins the panel to every edge.
    const fullscreen = bodies.filter((b) => /position:\s*fixed/.test(b) && /inset:\s*0/.test(b));
    expect(fullscreen.length).toBeGreaterThanOrEqual(1);
    for (const b of fullscreen) {
      expect(b).toMatch(/env\(safe-area-inset-top/);
      expect(b).toMatch(/env\(safe-area-inset-right/);
      expect(b).toMatch(/env\(safe-area-inset-bottom/);
      expect(b).toMatch(/env\(safe-area-inset-left/);
    }
  });

  // Non-happy path: a device with NO notch — or a webview that predates env() —
  // must fall back to the original offsets, never collapse to 0. Every inset
  // must carry an explicit fallback so `calc(1rem + env(...))` can't degrade to
  // `calc(1rem + )` (invalid → whole declaration dropped). Holds across every
  // component that ships inset-aware chrome, not just App.
  it("gives every safe-area-inset an explicit fallback for un-notched/legacy webviews", () => {
    const insets = [styleBlock, detailStyleBlock].flatMap(
      (css) => css.match(/env\(safe-area-inset-[a-z]+[^)]*\)/g) || [],
    );
    expect(insets.length).toBeGreaterThan(0);
    for (const inset of insets) {
      expect(inset).toMatch(/env\(safe-area-inset-[a-z]+\s*,\s*0px\)/);
    }
  });
});
