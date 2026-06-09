// Per-instance localStorage namespacing.
//
// Multiple axiotask instances (production + a dev/test instance launched with
// AXIOTASK_PREFIX) share the same WebView, and therefore the same localStorage,
// because they run from the same app identifier. To keep their UI state (view,
// sort, window geometry, etc.) isolated, every key is namespaced by the active
// instance prefix.
//
// The Rust side injects `window.__AXIOTASK_PREFIX__` before any page script
// runs (see main.rs initialization_script), so the prefix is available
// synchronously here — even for `$state` initializers that read storage at
// module load. The default (production) instance keeps the bare "axiotask:"
// keys for backward compatibility with previously-saved state.
const PREFIX =
  (typeof window !== "undefined" && window.__AXIOTASK_PREFIX__) || null;

const NS = PREFIX ? `axiotask:${PREFIX}:` : "axiotask:";

/**
 * Full localStorage key for a logical name (given without the "axiotask:"
 * root), namespaced to the active instance.
 * @param {string} name
 * @returns {string}
 */
export function storageKey(name) {
  return NS + name;
}
