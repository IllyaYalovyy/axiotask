# axiotask — Vision

## The Problem

Google Tasks is a capable backend — it syncs across devices, integrates with Gmail and Calendar,
and has a clean API. But its frontends are afterthoughts: a cramped sidebar in Gmail, a minimal
mobile app, and no standalone desktop client at all.

Power users who rely on task management hit walls immediately:

- No fast, low-friction workflow — frequent actions take too many steps
- No bulk operations
- No way to see task hierarchies at a glance
- No offline-first experience with fast local access
- No customization of views, filters, or sorting beyond the basics
- No desktop presence — it's always buried inside another app

## The Solution

axiotask is a native cross-platform application that treats Google Tasks as a
first-class backend while providing the frontend it deserves — one codebase,
one UI, on Linux desktop and Android.

**Core principles:**

1. **Local-first, sync-second** — Tasks are cached locally. The app is fast and usable offline.
   Sync happens in the background when connectivity is available. Conflicts are resolved
   predictably.

2. **One gesture per action** — Frequent actions take a single interaction: one click or tap to
   add a task; one click to move a task to tomorrow, next week, next month; swipe left/right on
   mobile for quick actions. Keyboard shortcuts may exist as a convenience but are never the
   backbone — the app is fully usable by touch and mouse alone.

3. **One level of subtasks, always clear** — Google Tasks allows exactly one level of nesting,
   and so do we — permanently. Lists and smart views show top-level tasks only; a parent card
   surfaces its subtask progress ("2/5"), and the subtasks themselves live in the task's detail
   panel where they can be added, checked off, dated, and detached. A subtask is never a
   standalone row and never a visual orphan.

4. **Fast and native-feeling** — Built with Flutter/Dart. Starts instantly. Uses minimal
   resources. Feels like a system application, not a web page in a wrapper.

5. **One codebase, one UI, without compromise** — Linux desktop and Android from a single
   Flutter codebase and a single UI. Respects each platform's conventions where it matters
   (safe areas, gestures, file paths, notifications).

6. **Privacy-respecting** — No telemetry. No analytics. No accounts beyond Google OAuth. Your tasks stay between you and Google's API.

7. **TDD** — strong test-driven development culture. EVERY feature or bugfix MUST be covered with
   tests. Think first about HOW to make it testable (architecture, fakes), then plan the tests,
   then implement. Run all tests after every change — zero regressions. Tests must be
   maintainable and clear, and must assert user-visible behavior.

## What axiotask is NOT

- Not a replacement for Google Tasks the backend — we use it, not compete with it
- Not a project management tool — no Gantt charts, no team features, no time tracking
- Not a note-taking app — tasks have titles and notes, not documents
- Not a calendar — but it respects due dates and surfaces them clearly
- Not a generic frontend — deep integration with Google Tasks. No abstraction layers between GUI and backend API (only for unit-test mocking)

## Target Users

Developers, writers, and knowledge workers who:

- Already use Google Tasks (or would, if the frontend didn't hold them back)
- Want a dedicated app that's always one tap or click away, on desktop and phone
- Value speed and low-friction interaction over visual polish
- Need to manage dozens to hundreds of tasks across multiple lists

## Success Criteria

axiotask succeeds when a user can:

- Launch the app and see all their Google Tasks in under 2 seconds
- Create, complete, and reorganize tasks in one or two gestures
- Work offline and have changes sync seamlessly when back online
- Trust that the app will never lose or corrupt their data
