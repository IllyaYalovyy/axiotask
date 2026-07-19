import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { compile } from "svelte/compiler";
import { describe, expect, it } from "vitest";

const warningCodesUnderTest = new Set([
  "a11y_click_events_have_key_events",
  "a11y_no_noninteractive_element_interactions",
  "a11y_no_noninteractive_element_to_interactive_role",
  "a11y_no_static_element_interactions",
  "css_unused_selector",
  "state_referenced_locally",
]);

const components = [
  "src/App.svelte",
  "src/BulkAdd.svelte",
  "src/DatePicker.svelte",
  "src/MoveToListPicker.svelte",
  "src/Properties.svelte",
];

describe("Svelte compiler warnings", () => {
  it("keeps known accessibility and local-state warnings fixed", () => {
    const warnings = components.flatMap((component) => {
      const filename = resolve(component);
      const source = readFileSync(filename, "utf8");
      return compile(source, { filename, generate: "client" }).warnings.map((warning) => ({
        component,
        code: warning.code,
        message: warning.message,
      }));
    });

    expect(warnings.filter((warning) => warningCodesUnderTest.has(warning.code))).toEqual([]);
  });
});
