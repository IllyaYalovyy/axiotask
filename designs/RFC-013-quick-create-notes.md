# RFC-013: Add notes while creating a task

| Field | Value |
|-------|-------|
| Status | Accepted |
| Author(s) | Illya Yalovyy |
| Supersedes | — |
| Superseded by | — |

Implementation issue: [#327](https://github.com/IllyaYalovyy/axiotask/issues/327).

## Summary

Add a visible **Add details** action to quick create. It reveals a multiline
**Notes** field before the task is saved. The same draft and creation operation
serve Android and Linux. Title-only capture keeps its existing fast path.

## Goals

- Write a title and a long description in one creation flow, without creating
  a task first and finding it elsewhere to edit.
- Expose notes in one tap or click from the composer on both platforms.
- Preserve the existing date preview, destination picker and rapid title-only
  capture behavior.

## Non-Goals

- Rich text, attachments, new task fields, a database migration, or a new sync
  protocol.
- A second independent draft, a replacement task-detail editor, or a redesign
  of Bulk Add.
- Automatically opening task details after every ordinary quick add.

## Background & Motivation

The user reports regularly needing a longer description during capture.
`QuickAddBar` currently accepts only a title, date and destination.
`ComposerHost._createFromDraft` creates that task; normal submission opens
details only when a detail pane was already open. The user must otherwise
locate and reopen the new task to write notes.

Bulk Add has a "First line is the title, the rest are notes" mode, but that
separate batch-oriented entry is not discoverable from ordinary quick create.
VISION.md calls for useful options within one or two interactions.

## Considered Options

### A — Expand the current composer with notes (recommended)

One extra action reveals an appropriately sized editor before saving. Title,
date, destination and notes remain one draft. Requires extending the shared
composer and the existing create command's optional inputs.

### B — Add and immediately open task details

Reuses the current editor and avoids searching for the new task. It still
creates the task before its description is ready, introduces navigation, and
makes returning to rapid capture less direct.

### C — Direct users to Bulk Add's title-and-notes mode

Already available, but asks people to discover a batch tool for an ordinary
single-task action and re-enter a partly written quick-add draft.

## Decision

**Accepted: Option A. Approved by the owner on 2026-09-20.**

## Design

### Interaction

- Show a labeled **Add details** action in the existing composer, reachable
  with touch and mouse. It must not depend on hover, a long press or an
  overflow menu. Use a small secondary row if necessary rather than squeezing
  the title field between another set of icons.
- Activation preserves the draft and focuses a multiline **Notes** field.
  Notes use ordinary text, line breaks and paste; pasting several lines here
  must never offer to create several tasks or parse dates from the notes.
- Collapsed title-only Enter/IME Done behavior stays as it is. With notes
  expanded, the title's Enter/IME Next moves into Notes; Enter inside Notes
  inserts a newline. The visible Add action submits the complete draft.
- Keep the editor bounded and scrollable for long text. On a small phone,
  keyboard-visible landscape, or enlarged text, scrolling must still reach
  every field and Add without overflow or an obscured button. Preserve the
  current top-mounted phone composer and its close/back behavior.
- Closing/reopening the composer or changing views retains typed title and
  notes in the host. Existing view/session rules for resetting date and list
  choices remain; do not silently discard notes when those choices reset.
- Successful creation consumes title and notes, returns to compact capture,
  and retains the current date/list behavior for consecutive additions.
  No new setting is needed.

### State and persistence

- Keep notes and expansion state in the existing `ComposerHost`/controller,
  alongside the title draft; both composer presentations render that state.
- Add an optional notes argument to `Commands.createTask` and its
  `TaskEditCommands` implementation. Populate the existing `Task.notes` before
  the first store write, then notify mutation once. This needs no schema or
  sync-engine change. Existing callers that omit notes remain valid.
- Submit and the existing background flush use the same complete draft.
  Ignore blank titles without losing entered notes. Serialize overlapping
  submits/background flushes with a small in-flight guard so one draft creates
  one task. Clear draft text only after the local write succeeds; keep it and
  show an actionable error on failure.
- Continue the current new-row placement, landing feedback and detail-follow
  behavior. Do not change smart-view filtering to keep a newly created task
  visible: the user has already entered its notes before submitting.

## Testing Strategy

- Widget flow on Android and Linux: enter a title, reveal Notes, enter several
  paragraphs, choose a date/list and add. Verify the stored row and reopened
  task details contain the complete notes, title, date and destination.
- Verify title-only rapid additions stay fast, multiline Notes input does not
  submit/split, and a second task does not inherit the first task's notes.
- Exercise retained notes through a view switch or close/reopen; background
  flush must persist the same complete task. Use controlled futures for one
  failing local write/retry and overlapping submission, without timer sleeps.
- Check a narrow keyboard-visible phone, short landscape viewport and 1.3x
  text scale for reachable controls and no Flutter layout errors. Inspect and
  update only affected goldens.
- Reuse the existing full quality gate and version checks. No broad sync
  stress suite or new testing framework is required.

## Development Plan

- [x] Obtain owner acceptance of this RFC before product implementation.
- [ ] Add focused failing tests and extend the existing create command.
- [ ] Wire the shared draft and both composer presentations; review rendered
      Android/Linux behavior and the focused failure path.
- [ ] Bump the minor version/build from the implementation baseline, including
      the About mirror and AppStream entry; run the full gate and deliver.

## Open Questions

- [X] Does the owner accept Option A and the interaction contract above?
	- Yes
