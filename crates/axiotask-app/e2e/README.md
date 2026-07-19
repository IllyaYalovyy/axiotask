# End-to-end smoke test

The unit tests under `ui/src/__tests__` run in happy-dom with **Tauri IPC and the
webview fully mocked**. They verify component logic, but they **cannot** catch a
broken launch, a stuck "Loading..." screen, dead clicks, or broken IPC — the app
can be completely unusable while all of them pass.

This smoke test is the antidote: it launches the **real built binary** through
`tauri-driver` + `WebKitWebDriver`, drives the **real webview**, and asserts the
app actually works:

1. renders and is not stuck on "Loading..." (catches startup/IPC wedges);
2. clicking **+ New task** creates an editable task (catches dead clicks);
3. typing a title + Enter round-trips through the backend and renders (catches
   broken IPC / rendering);
4. the core task flows work in the packaged app: due-date actions, subtask tree
   rendering, detail-panel edits, completion/show-completed, and search result
   selection.

It runs in a nested Xephyr X server with **software rendering (no GPU)**, so it is
hardware-independent and CI-friendly. GPU/compositor-specific rendering problems
that only affect one host are deliberately out of scope.

## Prerequisites

- `cargo install tauri-driver`
- `WebKitWebDriver` (Fedora: `webkit2gtk4.1`), `Xephyr` (`xorg-x11-server-Xephyr`), Node, ImageMagick optional
- A **production** build (embeds the frontend, not the dev server):
  `cd crates/axiotask-app && cargo tauri build --no-bundle`

## Run

```
cd crates/axiotask-app && cargo tauri build --no-bundle   # once, after frontend/rust changes
cd ui && npm run test:e2e                                  # or: bash ../e2e/run-smoke.sh
```

Exit code 0 = the app genuinely works end to end.
