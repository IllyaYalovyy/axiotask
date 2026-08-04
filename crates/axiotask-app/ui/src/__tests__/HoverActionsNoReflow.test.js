// Regression for #168: desktop task rows changed height on hover/click.
//
// The quick-action strip (`.actions`, the →o/→t/→w/→m/✕ buttons) was hidden
// with `display: none` and revealed with `display: flex` on
// `.task-widget:hover` / `.focused`. Because each button carries a
// `min-height: 1.5rem` — taller than the ~0.9rem title line — bringing the
// strip into the flex flow GREW `.main-row`, so every row visibly jumped
// height the instant the pointer entered it (and settled back on leave). The
// fix reveals the strip WITHOUT reflow: on desktop the strip is taken out of
// normal flow (`position: absolute`) and toggled with `visibility`, so its
// box never contributes to the row's height and the row size is identical
// hovered or not.
//
// jsdom does not evaluate scoped component stylesheets (getComputedStyle
// returns empty for Svelte's class-scoped rules — see SafeAreaInsets.test.js),
// so — as with the safe-area and theme-contrast regressions — this asserts the
// shipped CSS carries the no-reflow contract rather than measuring a pixel.

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const src = readFileSync(resolve(process.cwd(), "src/TaskRow.svelte"), "utf8");

// The <style> block, comments stripped so a `/* … */` mentioning `display`
// can't be mistaken for a real declaration.
const style = src
  .slice(src.indexOf("<style>"), src.indexOf("</style>"))
  .replace(/\/\*[\s\S]*?\*\//g, "");

// Return every CSS declaration body (between `{` and its matching `}`) whose
// selector list contains `selector`. Recurses into at-rules so a rule nested
// in an @media is found too. Copied in spirit from SafeAreaInsets.test.js.
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
    } else if (
      new RegExp(`(^|[\\s,>])${selector.replace(".", "\\.")}(\\s|$|[,:.])`).test(head)
    ) {
      bodies.push(body);
    }
    i = j;
  }
  return bodies;
}

// Extract the body of the first at-rule whose head names a fine (mouse)
// pointer — the desktop context where hover/focus (and therefore the reflow
// bug) actually happen.
function fineMediaBlock(css) {
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
    if (head.startsWith("@") && /pointer\s*:\s*fine/.test(head)) {
      return css.slice(open + 1, j - 1);
    }
    i = j;
  }
  return "";
}

describe("#168: desktop task rows must not change height on hover/click", () => {
  const desktop = fineMediaBlock(style);

  it("scopes the no-reflow reveal to a fine (mouse) pointer so mobile swipe is untouched", () => {
    expect(desktop).not.toBe("");
  });

  it("takes the action strip OUT OF FLOW on desktop so its box can't grow the row", () => {
    // Whatever the hidden/shown toggle is, an absolutely-positioned strip
    // contributes zero height to `.main-row` — the mechanical guarantee that
    // the row size is identical hovered or not.
    const actions = ruleBodies(desktop, ".actions");
    expect(actions.length).toBeGreaterThanOrEqual(1);
    const positioned = actions.filter((b) => /position:\s*absolute/.test(b));
    expect(positioned.length).toBeGreaterThanOrEqual(1);
  });

  it("reveals the strip with visibility, NOT by toggling display into a box", () => {
    // The hover / focus reveal rule must flip `visibility`, not `display`.
    // Toggling `display: none` -> a box is exactly what reflowed the row.
    const revealBodies = [
      ...ruleBodies(desktop, ".actions"),
    ];
    const revealSource = desktop;
    // The reveal declaration exists and uses visibility…
    expect(/visibility:\s*visible/.test(revealSource)).toBe(true);
    // …and the hidden desktop strip is hidden via visibility, not removed.
    const hiddenStrip = ruleBodies(desktop, ".actions").find((b) =>
      /visibility:\s*hidden/.test(b),
    );
    expect(hiddenStrip).toBeTruthy();
    // Non-happy path guard: no rule inside the desktop reveal may hide the
    // strip with `display: none` (which, paired with a `display: flex` reveal,
    // is the reflow pattern we removed).
    for (const b of revealBodies) {
      expect(b).not.toMatch(/display:\s*none/);
    }
  });

  it("keeps the mobile swipe-reveal path (coarse pointer) intact and in-flow", () => {
    // Non-happy path: the coarse-pointer / swipe mechanism must NOT be
    // converted to the desktop absolute+visibility scheme — it still shows the
    // strip with display on swipe. Guards invariant #8 (pointer classes differ
    // on purpose). We check the coarse override still toggles display.
    const coarseIdx = style.search(/@media\s*\(\s*pointer\s*:\s*coarse/);
    expect(coarseIdx).toBeGreaterThan(-1);
    const coarseTail = style.slice(coarseIdx);
    expect(coarseTail).toMatch(/\.swipe-actions-(open|peeking)[^{]*\.actions[^{]*\{[^}]*display:\s*flex/);
  });
});
