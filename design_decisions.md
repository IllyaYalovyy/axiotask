# Design Decisions (FAQ)

The pivotal architecture and behavior decisions, and the "why" behind each. This is a short FAQ of the choices that shape the system — not a full spec. UX decisions live in `ux_decisions.md`.

**Q: Where does the truth live — local or Google?**
For local lists - local. For remote lists Google is source of truth. With many clients connected and sending changes to the server, we need to prioritize changes that come from the remote. 

**Q: How tasks and subtasks are organized?**
There are only 2 levels of task:
- top level tasks: visible in all lists and filters
- sub task (no nesting). Sub task has a very strong relation to the parent, and always represented in a context of its parent. 

**Q: Push or pull first?**
Push first, then pull — but the order is not the safety mechanism. Every push is etag-guarded (`If-Match`), and Google Tasks has no global version: conflicts are per-task, so an unrelated remote change never blocks a local push. Push resolves every dirty row (landed, conflicted-copy, or left dirty to retry), which lets the pull be a plain refresh that skips dirty rows. A remote change landing mid-run is caught by the next run; no ordering closes that window. The invariant that actually matters: a row's etag must never match while its content diverges — a matching etag makes every future pull skip the row permanently.

**Q: What happens when the same task is edited in two places (a conflict)?**
Edit vs. edit: remote wins, and the local edit survives as a "(conflicted copy)" task pushed next run. Edit vs. **delete** (either direction): the delete wins and the edit is discarded — deliberately, no conflicted copy. The full local×remote permutation matrix lives in `designs/RFC-009-sync-conflict-matrix.md`.

**Q: What if one task fails to push?**
The run continues. A single row's server rejection is logged and left `dirty` to retry next run; it never starves the other rows or the pull. Only an auth failure aborts the run — every call would fail the same way.

**Q: Can a crash duplicate a created task?**
No. An in-flight create is recorded before the insert; a restarted run adopts the server's row instead of inserting again. This covers the case where the server commits but the response is lost.

**Q: How does moving a task to another list work?**
Google has no cross-list move, and deleting a parent cascades its children. So the move clones the task and its whole subtree under new ids in the target list, then deletes the original. The subtree always moves together — nothing is left behind.

**Q: What do complete and delete do to subtasks?**
They mirror Google. Completing a task completes its subtasks (un-completing does not reopen them). Deleting a task deletes its whole subtree. We reproduce these server behaviors locally so state is truthful immediately.

**Q: How is a task's date determined?**
For a parent task Effective date = the task's own due date, or, if it has none, the earliest date among its unfinished subtasks. All date logic uses the effective date. This is settled — do not change it.
For a sub task, it only its own date.

**Q: How are the three auth states handled?**
Signed-out, signed-in, and needs-reauth (tokens exist but the refresh token is permanently revoked/expired). A permanently denied refresh surfaces as "session expired" and prompts re-auth, distinct from a transient network failure, and never hides local data.

**Q: Why don't IPC commands return `Ok(())`?**
Tauri serializes `Ok(())` as `null`, which the frontend cannot tell apart from an error's `null`. Commands return a real value and the frontend re-queries state rather than guessing success from `null`.
