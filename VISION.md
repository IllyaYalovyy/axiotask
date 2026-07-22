# axiotask — Vision

## The Problem

Google Tasks is a capable backend — it syncs across devices, integrates with Gmail and Calendar,
and has a clean API. But its frontends are afterthoughts: a cramped sidebar in Gmail, a minimal
mobile app, and no standalone desktop client at all.

Power users who rely on task management hit walls immediately:

- No keyboard-driven workflow
- No bulk operations
- No way to see task hierarchies at a glance
- No offline-first experience with fast local access
- No customization of views, filters, or sorting beyond the basics
- No desktop presence — it's always buried inside another app

## The Solution

axiotask is a native cross-platform desktop application that treats Google Tasks as a
first-class backend while providing the frontend it deserves.

**Core principles:**

1. **Local-first, sync-second** — Tasks are cached locally. The app is fast and usable offline.
   Sync happens in the background when connectivity is available. Conflicts are resolved
   predictably.

2. **Keyboard-driven** — Every action is reachable without a mouse. Navigation, creation,
   editing, completion, reordering — all from the keyboard. Mouse is supported but never required. "Single click" - to add a new task. "Single click" to move task to tomorrow, next week, next month. 

3. **One level of subtasks, always clear** — Google Tasks allows exactly one level of nesting,
   and so do we — permanently. Lists and smart views show top-level tasks only; a parent card
   surfaces its subtask progress ("2/5"), and the subtasks themselves live in the task's detail
   panel where they can be added, checked off, dated, and detached. A subtask is never a
   standalone row and never a visual orphan.

4. **Fast and native** — Built in Rust. Starts instantly. Uses minimal resources. Feels like
   a system application, not a web page in a wrapper.

5. **Cross-platform without compromise** — Linux, macOS, and Windows from a single codebase.
   Respects each platform's conventions where it matters (file paths, notifications, system tray).

6. **Privacy-respecting** — No telemetry. No analytics. No accounts beyond Google OAuth. Your tasks stay between you and Google's API.

7. **TDD** - strong tdd development culture. EVERY feature or bugfix MUST be covered with unit test. Think first about HOW to make it testable (architercture, mocks) then plan do tests, then do implementation. Run all tests after every change - zero regressions. Test must be maintainable and clear. Think what creates should be used to achieve that goal.  

## What axiotask is NOT

- Not a replacement for Google Tasks the backend — we use it, not compete with it
- Not a project management tool — no Gantt charts, no team features, no time tracking
- Not a note-taking app — tasks have titles and notes, not documents
- Not a calendar — but it respects due dates and surfaces them clearly
- Not a generic frontend - deep integration with Google tasks. No abstraction layers between gui and backend api. (only for unit testing mocking)

## Target Users

Developers, writers, and knowledge workers who:

- Already use Google Tasks (or would, if the frontend didn't hold them back)
- Want a dedicated desktop app that's always a keystroke away
- Value speed and keyboard efficiency over visual polish
- Need to manage dozens to hundreds of tasks across multiple lists

## Success Criteria

axiotask succeeds when a user can:

- Launch the app and see all their Google Tasks in under 2 seconds
- Create, complete, and reorganize tasks entirely from the keyboard
- Work offline and have changes sync seamlessly when back online
- Trust that the app will never lose or corrupt their data
