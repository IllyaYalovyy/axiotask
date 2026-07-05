// Theme preference (light / dark / system), persisted per instance (#46).
import { storageKey } from "./storage.js";

/** The saved preference: "dark" (default), "light", or "system". */
export function getThemePref() {
  return localStorage.getItem(storageKey("theme")) || "dark";
}

/** Resolve a preference to a concrete theme, honoring the OS for "system". */
function resolve(pref) {
  if (pref === "system") {
    return window.matchMedia?.("(prefers-color-scheme: light)").matches ? "light" : "dark";
  }
  return pref === "light" ? "light" : "dark";
}

/** Apply a preference to the document (sets <html data-theme>). */
export function applyTheme(pref = getThemePref()) {
  document.documentElement.dataset.theme = resolve(pref);
}

/** Persist and apply a preference. */
export function setThemePref(pref) {
  localStorage.setItem(storageKey("theme"), pref);
  applyTheme(pref);
}
