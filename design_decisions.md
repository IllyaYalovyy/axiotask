# Design Decisions (FAQ)

The pivotal architecture and behavior decisions, and the "why" behind each. This is a short FAQ of the choices that shape the system — not a full spec. UX decisions live in `ux_decisions.md`.

**Q: Where does the truth live — local or Google?**
Local. The SQLite database is the source of truth and the app is fully offline-first. Google Tasks is a replica the sync engine reconciles in the background. Every edit is written locally and marked `dirty` immediately; the push happens on the next sync.

**Q: Why is the code split into two crates?**
`axiotask-core` holds the hard logic (store, sync, conflict resolution, dates)
with no UI dependency, so it is tested headless. `axiotask-app` is just the Tauri
shell and IPC. Sync correctness never depends on a running UI.

**Q: How deep can subtasks go?**
Exactly one level — a top-level task and its subtasks. We match Google's product
exactly (two levels). A subtask's parent is always a top-level task.

**Q: How do we change the database schema before 1.0?**
No migrations. A schema change wipes and recreates the database from scratch —
local data re-pulls from Google. Migrations return only after release, when real
user data must be preserved.

**Q: Push or pull first?**
Push local changes first, then pull remote changes. Reconciliation is
bidirectional, per list.

**Q: What happens when the same task is edited in two places (a conflict)?**
Remote wins, but the local edit is never lost. On a stale-etag `412` the engine
fetches the remote version; if it already matches, it just absorbs it; otherwise
the remote becomes canonical and the local edit survives as a new
"(conflicted copy)" task, pushed on the next run.

**Q: What if one task fails to push?**
The run continues. A single row's server rejection is logged and left `dirty` to
retry next run; it never starves the other rows or the pull. Only an auth failure
aborts the run — every call would fail the same way.

**Q: Can a crash duplicate a created task?**
No. An in-flight create is recorded before the insert; a restarted run adopts the
server's row instead of inserting again. This covers the case where the server
commits but the response is lost.

**Q: How does moving a task to another list work?**
Google has no cross-list move, and deleting a parent cascades its children. So the
move clones the task and its whole subtree under new ids in the target list, then
deletes the original. The subtree always moves together — nothing is left behind.

**Q: What do complete and delete do to subtasks?**
They mirror Google. Completing a task completes its subtasks (un-completing does
not reopen them). Deleting a task deletes its whole subtree. We reproduce these
server behaviors locally so state is truthful immediately.

**Q: How is a task's date determined?**
Effective date = the task's own due date, or, if it has none, the earliest date
among its unfinished subtasks. All date logic uses the effective date. This is
settled — do not change it.

**Q: How are the three auth states handled?**
Signed-out, signed-in, and needs-reauth (tokens exist but the refresh token is
permanently revoked/expired). A permanently denied refresh surfaces as
"session expired" and prompts re-auth, distinct from a transient network failure,
and never hides local data.

**Q: Why don't IPC commands return `Ok(())`?**
Tauri serializes `Ok(())` as `null`, which the frontend cannot tell apart from an
error's `null`. Commands return a real value and the frontend re-queries state
rather than guessing success from `null`.
