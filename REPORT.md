Building a Cross-Platform Google Tasks Client: A Framework Comparison Report

Executive Summary

This report documents the development of "axiotask" — a keyboard-driven, offline-first Google Tasks desktop client — across three framework approaches: Tauri 2 + Svelte 5, Dioxus (Rust), and Flutter + Dart. The project ran over 8 days with 48 commits, producing a functional but troubled Tauri app before pivoting to evaluate alternatives.

Key finding: 31% of all commits were bug fixes for framework integration issues, not product features. The Tauri+Svelte approach delivered features but created an untestable, fragile UI layer that repeatedly broke in ways invisible to automated testing.

---

1. Project Requirements

1.1 Product Requirements

- Google Tasks API as the sole backend (OAuth 2.0 PKCE)
- Offline-first: local SQLite cache, async sync
- Keyboard-driven: every action reachable without mouse
- Cross-platform: Linux, macOS, Windows, iOS, Android
- Fast: <2s to first paint, <50ms for any local operation
- Hierarchy: subtasks visible as a tree
- Smart views: Focus, Upcoming, Missed, Unscheduled (cross-list)
- Rich task widget: progress bars, link detection, due dates, recurrence

1.2 Technical Requirements

- Single codebase for all platforms
- Testable UI (developer must be able to verify rendering without manual QA)
- TDD culture: tests before implementation
- No telemetry, no analytics
- Local-first data model with conflict resolution

1.3 Non-Negotiable Constraint (discovered during development)

"If you cannot test and validate UX yourself, it's a dead end. If the technology doesn't allow that, it's not the technology we want."

This constraint — that the AI developer must be able to programmatically verify what renders — became the defining factor in framework evaluation.

---

2. Approach 1: Tauri 2 + Svelte 5

2.1 Architecture

  Rust backend (axiotask-core):
    - OAuth PKCE auth flow
    - Google Tasks API client (trait + mock + HTTP impl)
    - SQLite store via sqlx
    - Bidirectional sync engine
    - Date arithmetic

  TypeScript/Svelte frontend (axiotask-app):
    - Svelte 5 components
    - Vite build system
    - Tauri IPC bridge (invoke/commands)

  Communication: JSON serialization over Tauri's IPC channel.

2.2 What Worked

- Backend (Rust): Excellent. 40+ tests, type-safe, fast. The core crate was solid from day one and never caused issues.
- Svelte reactivity: Once working, the reactive UI was pleasant to write.
- Component tests (Vitest): After setup, 45 tests verified DOM structure and keyboard interactions reliably.
- Build speed: Incremental Rust builds ~4s, Vite hot reload instant.

2.3 What Broke (Chronological)

Issue 1: Empty window on first launch
  Root cause: SQLite migration used CREATE TABLE (not IF NOT EXISTS). Second launch crashed.
  Time to diagnose: ~30 minutes.
  Fix: One-line SQL change.

Issue 2: "Loading axiotask..." forever
  Root cause: AppState initialized in async spawn — window opened before state was managed. All invoke() calls from frontend returned errors silently.
  Time to diagnose: ~1 hour.
  Fix: Restructured startup to block on state init.

Issue 3: White rectangle (no rendering at all)
  Root cause: Svelte 5 mount() API different from Svelte 4. The entry point used `new App()` (Svelte 4 syntax) instead of `mount(App, {target})`.
  Time to diagnose: ~45 minutes (couldn't see the error in WebView).
  Fix: One-line change in main.js.

Issue 4: Still white rectangle after fix
  Root cause: Vite resolved Svelte's SERVER bundle instead of CLIENT bundle in the WebView. The `resolve.conditions` config was only set for test environment.
  Time to diagnose: ~2 hours. Required user to report the actual error message displayed in the window after adding a try/catch wrapper.
  Fix: Set `resolve: { conditions: ["browser"] }` always.

Issue 5: Auth token exchange fails ("client_secret is missing")
  Root cause: Google requires client_secret even for Desktop OAuth apps. The implementation omitted it based on incorrect assumption about PKCE flow.
  Time to diagnose: ~20 minutes (once logging was added).
  Fix: Add client_secret to token exchange request.

Issue 6: Tokens lost on restart
  Root cause: Linux keyutils (keyring crate default) doesn't persist across process restarts. Tokens stored in session keyring vanished.
  Time to diagnose: ~1 hour.
  Fix: Switch to file-based token storage.

Issue 7: Sync FK constraint violation
  Root cause: Google returns tasks in arbitrary order. Child tasks inserted before parents violated FOREIGN KEY constraint.
  Time to diagnose: ~15 minutes (clear error message once logging existed).
  Fix: Sort tasks (parents first) before inserting.

Issue 8: New tasks invisible after creation
  Root cause: Task created with no due date. User was in "Today" view which filters by due date. Task existed but was in a view the user wasn't looking at.
  Time to diagnose: ~10 minutes.
  Fix: Switch to target list view after creation, focus the new task.

2.4 The Fundamental Problem

The developer (AI) could not see what the WebView rendered. This created a feedback loop:

  1. Write code → 2. Build succeeds → 3. Tests pass → 4. User reports "it's broken"
  → 5. Guess at the problem → 6. Ship a fix → 7. User reports "still broken"

This loop repeated 5 times for the rendering issues alone. The component tests (Vitest + happy-dom) verified DOM structure correctly, but couldn't catch:
- Vite bundle resolution issues (server vs client)
- Tauri IPC timing (state not ready when WebView loads)
- WebKit2GTK-specific rendering behavior
- CSS that renders correctly in jsdom but not in a real WebView

2.5 Quantified Cost

  Total commits: 48
  Feature commits: 18 (38%)
  Fix commits: 15 (31%)
  Debug/safety commits: 4 (8%)
  
  Lines of Rust (backend): 2,975
  Lines of Rust (Tauri commands): 1,097
  Lines of Svelte/JS (UI): 2,305
  Lines of test code (JS): 576
  
  Tests: 96 total (45 frontend + 51 Rust)
  
  Estimated time on framework issues vs features: ~40% debugging, 60% building

2.6 Verdict

Tauri + Svelte delivers a working app but at high integration cost. The two-language boundary (Rust ↔ JavaScript) creates an entire class of bugs that neither language's tooling catches. The WebView is a black box that resists programmatic inspection.

Suitable for: Teams with dedicated frontend developers who can manually test in the browser. Projects where the WebView is a known quantity.

Not suitable for: AI-driven development, solo developers who need automated UI verification, projects targeting mobile (Tauri mobile is experimental).

---

3. Approach 2: Dioxus (Pure Rust)

3.1 Architecture (Planned)

  Single Rust codebase:
    - axiotask-core (reused unchanged from Tauri project)
    - axiotask-ui (Dioxus components calling core directly)
  
  No IPC boundary. No serialization. No JavaScript.

3.2 Theoretical Advantages

- Eliminates the IPC boundary entirely (the source of Issues 2, 3, 4)
- UI components are Rust functions testable with cargo test
- No Vite, no npm, no bundle resolution issues
- Mobile support from same codebase
- Type safety end-to-end (no TaskView DTO mapping)

3.3 Practical Concerns

- Dioxus 0.6 is stable but ecosystem is young
- Still uses WebView (wry) on desktop — same WebKit2GTK dependency
- RSX macro errors can be cryptic
- No off-the-shelf component library (date pickers, drag-and-drop)
- Community is small; fewer resources when stuck

3.4 Status

Project scaffolded (axiotask_03). Core crate compiles and tests pass (40 tests). UI crate compiles with Dioxus 0.6. Not yet implemented beyond placeholder.

---

4. Approach 3: Flutter + Dart

4.1 Architecture (Planned)

  Single Dart codebase:
    - lib/core/ — pure business logic (models, store, API, sync, auth)
    - lib/ui/ — Flutter widgets
    - lib/state/ — Riverpod state management
  
  No Rust. No FFI. No IPC. One language, one build system.

4.2 Advantages

- Most mature cross-platform framework (production-ready on all 5 platforms)
- Widget testing built-in (WidgetTester renders and asserts on widget tree)
- Massive ecosystem: date pickers, drag-and-drop, animations all off-the-shelf
- Hot reload is the fastest of any framework
- No WebView — renders via Skia/Impeller directly into a GTK window
- Eliminates the entire class of WebView rendering bugs
- Large developer community; easy to find help

4.3 Disadvantages

- Complete rewrite (no Rust code reuse)
- Dart's type system weaker than Rust's (no ownership, no Result type)
- Not truly native rendering (custom canvas, not platform widgets)
- Larger binary (~20MB vs ~11MB)
- Exception-based error handling (vs Rust's Result)

4.4 Status

Project scaffolded (axiotask_04). Models and date arithmetic implemented with tests. Awaiting Flutter SDK installation.

---

5. Framework Comparison Matrix

  Criterion                  | Tauri+Svelte    | Dioxus         | Flutter
  ========================== | =============== | ============== | ==============
  Languages                  | Rust + JS       | Rust only      | Dart only
  Build systems              | Cargo + npm     | Cargo only     | Flutter only
  IPC boundary               | Yes (JSON)      | None           | None
  UI testability             | Vitest (jsdom)  | cargo test     | flutter_test
  Can verify rendering?      | No (WebView)    | Partial        | Yes (widget test)
  Mobile support             | Experimental    | First-class    | Production
  Desktop support            | Production      | Stable         | Stable
  Ecosystem maturity         | High            | Low            | Very high
  Component library          | Svelte (large)  | Minimal        | Massive
  Hot reload                 | Vite HMR        | dx serve       | flutter run
  Binary size                | ~11MB           | ~11MB          | ~20MB
  Rendering engine           | WebKit2GTK      | WebKit2GTK     | Skia/Impeller
  WebView dependency         | Yes             | Yes            | No
  Reuse of existing core     | N/A (origin)    | 100%           | 0% (rewrite)

---

6. Key Findings

6.1 The WebView Is the Problem

Both Tauri and Dioxus (desktop) use WebView for rendering. This means:
- Platform-specific rendering bugs (WebKit2GTK on Linux)
- Cannot programmatically inspect rendered output from the backend
- Bundle resolution, CSP, and script injection timing issues

Flutter avoids this entirely by owning the rendering pipeline.

6.2 The IPC Boundary Is Expensive

Tauri's invoke() bridge required:
- DTO types on both sides (TaskView in Rust, matching interface in JS)
- Async command wrappers with error handling
- State management on both sides (Rust AppState + Svelte $state)
- Timing coordination (state must be ready before UI calls it)

This boundary was responsible for 4 of the 8 major bugs.

6.3 Testing Strategy Determines Viability

The project's hard requirement — "test and validate UX yourself" — eliminated Tauri as a long-term choice. The Vitest component tests verified DOM structure but couldn't catch the actual rendering failures that occurred in the WebView.

Flutter's WidgetTester renders the actual widget tree (same code path as production) and allows assertions on it. This is the only approach that fully satisfies the testability requirement.

6.4 Single-Language Advantage Is Real

Every cross-language boundary introduces:
- Serialization overhead and bugs
- Type mismatches (Rust Option vs JS undefined vs null)
- Build system complexity
- Debugging across language boundaries

Both Dioxus and Flutter eliminate this. The productivity difference is significant.

6.5 Ecosystem Maturity Matters for UI

Building a date picker, context menu, drag-and-drop, and search overlay from scratch (as we did in Svelte) took substantial time. Flutter has production-ready versions of all of these as packages.

---

7. Recommendation

For this specific project (keyboard-driven task app, cross-platform including mobile, solo developer, AI-assisted development):

  1st choice: Flutter + Dart
     - Testable, mature, mobile-ready, rich ecosystem
     - Cost: full rewrite of backend logic in Dart (~3-4 days)

  2nd choice: Dioxus (Rust)
     - Reuses existing backend, single language, testable
     - Cost: UI rewrite only (~3 days), but ecosystem gaps

  3rd choice: Tauri + Svelte (current)
     - Working but fragile, untestable rendering layer
     - Cost: already built, but ongoing maintenance burden

---

8. Lessons Learned

1. "It compiles and tests pass" is not enough for UI. You must be able to verify what the user sees.

2. The IPC boundary between backend and frontend is not free. Every serialization point is a potential bug.

3. WebView-based desktop apps inherit all the complexity of web development (bundle resolution, CSP, script timing) without the benefit of browser DevTools being readily available.

4. Framework choice should be driven by testability first, features second. A framework you can't test is a framework you can't trust.

5. AI-assisted development amplifies the testability requirement. An AI that can't see the output will ship broken code repeatedly, wasting human time on QA.

6. Start with the hardest constraint. For this project, "must work on mobile" + "must be testable" should have eliminated Tauri on day one.

---

Appendix: Timeline

  Day 1: Project setup, Rust backend (core crate), all 40 tests passing
  Day 2: Tauri scaffold, Svelte UI, first "working" app (actually broken)
  Day 3: Debugging rendering issues (white screen, SSR resolution, IPC timing)
  Day 4: Auth flow, sync, first successful Google Tasks pull
  Day 5: UX features (smart views, task widget, context menu, sort)
  Day 6: More UX (detail panel, search, list management)
  Day 7: Dioxus evaluation and project setup
  Day 8: Flutter evaluation and project setup, this report

Appendix: Code Statistics

  Tauri project (axiotask_01):
    - 48 commits over 8 days
    - 6,377 lines of application code
    - 576 lines of test code (frontend)
    - 96 total tests (45 JS + 51 Rust)
    - 15 bug-fix commits (31% of total)

  Dioxus project (axiotask_03):
    - 1 commit (scaffold)
    - 2,975 lines reused from core
    - 40 tests passing (reused)

  Flutter project (axiotask_04):
    - 1 commit (scaffold)
    - ~200 lines of new Dart code
    - 8 tests defined (pending Flutter SDK)
