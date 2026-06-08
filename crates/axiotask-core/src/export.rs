//! Export / backup serialization.
//!
//! Produces a complete, human-readable, future-proof snapshot of everything
//! axiotask holds locally — every task list, every task, and **all** of their
//! fields and sync metadata. Nothing the app stores is dropped, so a backup is
//! a lossless mirror of the local database.
//!
//! # Format
//!
//! The backup is a single JSON document. JSON was chosen because it is:
//!
//! * **Human-readable** — pretty-printed, diff-friendly, and openable in any
//!   text editor.
//! * **Easy to read and write** — every language (and every future version of
//!   axiotask) has a JSON parser; no bespoke format to maintain.
//! * **Extensible** — the top-level [`Backup::version`] field lets future
//!   releases evolve the schema, and unknown fields are ignored on read, so
//!   older backups keep loading and newer backups degrade gracefully.
//!
//! Tasks are nested under the list they belong to, which mirrors the mental
//! model a user has and keeps the parent/child relationships obvious when
//! reading the file by eye. The list/task ordering is preserved exactly as the
//! store returns it (Google's `position` strings are also exported verbatim, so
//! ordering survives a restore even if the reader re-sorts).
//!
//! # Coverage (no missing data)
//!
//! Google's Tasks REST API has no recurrence field — axiotask stores repeat
//! rules inside the task `notes` as an RFC 5545 trailer (see
//! [`crate::recurrence`]). The backup keeps `notes` **verbatim** (trailer
//! included), so recurrence round-trips with zero loss. As a readability bonus
//! a derived [`BackupRecurrence`] (RRULE + human summary) is added alongside;
//! it is purely additive — `notes` remains the source of truth.
//!
//! This module is pure (no IO) and fully unit tested, matching the
//! `recurrence.rs` / `dates.rs` convention. Callers own reading from the store
//! and writing the resulting string to disk.

use serde::{Deserialize, Serialize};

use crate::model::{Task, TaskList, TaskStatus};
use crate::recurrence;
use crate::store::{StoredTask, StoredTaskList, SyncState};

/// Current backup schema version. Bump when the shape changes incompatibly;
/// readers should refuse versions they do not understand.
pub const BACKUP_VERSION: u32 = 1;

/// Producing application name, embedded so a backup is self-describing.
pub const BACKUP_APP: &str = "axiotask";

/// A complete local snapshot: the root of an exported backup document.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Backup {
    /// Schema version for forward/backward compatibility.
    pub version: u32,
    /// Producing application name (always `"axiotask"` today).
    pub app: String,
    /// RFC 3339 timestamp of when the backup was produced.
    pub exported_at: String,
    /// Every task list, each with its tasks nested for readability.
    pub lists: Vec<BackupList>,
}

/// A task list plus all of its sync metadata and tasks.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BackupList {
    /// Google's identifier (or a local UUID before first push).
    pub id: String,
    /// Display title.
    pub title: String,
    /// Opaque etag returned by Google; `None` for local-only rows.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub etag: Option<String>,
    /// Server-side `updated` timestamp (RFC 3339).
    pub updated: String,
    /// Local-only list: never synced to Google.
    pub local_only: bool,
    /// Local sync state: `clean` | `dirty` | `deleted`.
    pub sync_state: String,
    /// Local timestamp of the last edit (RFC 3339).
    pub local_updated: String,
    /// Pending push operation when dirty: `create` | `update` | `delete`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending_op: Option<String>,
    /// Tasks belonging to this list, in store order.
    pub tasks: Vec<BackupTask>,
}

/// A task with every domain field and all sync metadata.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BackupTask {
    /// Google's identifier (or a local UUID before first push).
    pub id: String,
    /// Parent task id; `None` means a top-level task.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
    /// Google's lex-sortable position string (preserves ordering on restore).
    pub position: String,
    /// Display title.
    pub title: String,
    /// Free-form notes, **verbatim** (recurrence trailer included if present).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    /// Completion status: `needsAction` | `completed`.
    pub status: String,
    /// Due date (RFC 3339).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub due: Option<String>,
    /// Completion timestamp (RFC 3339).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed: Option<String>,
    /// Opaque etag returned by Google.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub etag: Option<String>,
    /// Server-side `updated` timestamp.
    pub updated: String,
    /// Local sync state: `clean` | `dirty` | `deleted`.
    pub sync_state: String,
    /// Local timestamp of the last edit (RFC 3339).
    pub local_updated: String,
    /// Pending push operation when dirty: `create` | `update` | `delete`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending_op: Option<String>,
    /// Derived, human-readable recurrence info. Additive only — the source of
    /// truth is the trailer embedded in `notes`. `None` when the task does not
    /// repeat.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recurrence: Option<BackupRecurrence>,
}

/// Human-readable recurrence summary derived from a task's `notes` trailer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BackupRecurrence {
    /// RFC 5545 `RRULE` value (without the `RRULE:` prefix).
    pub rrule: String,
    /// Plain-English description, e.g. "Every 2 weeks on Mon, Wed".
    pub summary: String,
}

impl BackupTask {
    fn from_stored(st: &StoredTask) -> Self {
        let recurrence = st
            .task
            .notes
            .as_deref()
            .and_then(|n| recurrence::extract_from_notes(n).1)
            .map(|r| BackupRecurrence {
                rrule: r.to_rrule(),
                summary: r.summary(),
            });
        Self {
            id: st.task.id.clone(),
            parent: st.task.parent.clone(),
            position: st.task.position.clone(),
            title: st.task.title.clone(),
            notes: st.task.notes.clone(),
            status: st.task.status.as_api_str().to_string(),
            due: st.task.due.clone(),
            completed: st.task.completed.clone(),
            etag: st.task.etag.clone(),
            updated: st.task.updated.clone(),
            sync_state: st.sync_state.as_str().to_string(),
            local_updated: st.local_updated.clone(),
            pending_op: st.pending_op.clone(),
            recurrence,
        }
    }
}

impl Backup {
    /// Assemble a backup from the store's lists paired with their tasks.
    ///
    /// `exported_at` should be an RFC 3339 timestamp. Order is preserved
    /// exactly as provided.
    pub fn build(
        exported_at: impl Into<String>,
        lists: Vec<(StoredTaskList, Vec<StoredTask>)>,
    ) -> Self {
        let lists = lists
            .into_iter()
            .map(|(list, tasks)| BackupList {
                id: list.list.id,
                title: list.list.title,
                etag: list.list.etag,
                updated: list.list.updated,
                local_only: list.local_only,
                sync_state: list.sync_state.as_str().to_string(),
                local_updated: list.local_updated,
                pending_op: list.pending_op,
                tasks: tasks.iter().map(BackupTask::from_stored).collect(),
            })
            .collect();
        Self {
            version: BACKUP_VERSION,
            app: BACKUP_APP.to_string(),
            exported_at: exported_at.into(),
            lists,
        }
    }

    /// Serialize to pretty-printed JSON (human-readable, diff-friendly).
    pub fn to_json_pretty(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string_pretty(self)
    }

    /// Parse a backup document from its JSON text.
    ///
    /// The inverse of [`to_json_pretty`](Backup::to_json_pretty). Unknown
    /// fields are ignored and `#[serde(default)]` lets older documents load, so
    /// this stays forward- and backward-compatible. Callers should still check
    /// [`version`](Backup::version) before trusting newer documents.
    pub fn from_json(json: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(json)
    }

    /// Reconstruct store rows (each list paired with its tasks) from a backup.
    ///
    /// The exact inverse of [`build`](Backup::build): every domain field and
    /// all sync metadata are restored verbatim, so a backup round-trips
    /// losslessly back into the local store. Unknown enum strings degrade
    /// safely rather than failing the whole restore (`sync_state` → `Clean`,
    /// `status` → `NeedsAction`). The derived `recurrence` summary is dropped —
    /// the source of truth is the verbatim `notes` trailer, which is preserved.
    pub fn into_stored(self) -> Vec<(StoredTaskList, Vec<StoredTask>)> {
        self.lists.into_iter().map(BackupList::into_stored).collect()
    }

    /// Total number of tasks across all lists (handy for status messages).
    pub fn task_count(&self) -> usize {
        self.lists.iter().map(|l| l.tasks.len()).sum()
    }
}

impl BackupList {
    /// Rebuild a stored list plus its stored tasks. Inverse of the mapping in
    /// [`Backup::build`].
    fn into_stored(self) -> (StoredTaskList, Vec<StoredTask>) {
        let list_id = self.id.clone();
        let tasks = self
            .tasks
            .into_iter()
            .map(|t| t.into_stored(&list_id))
            .collect();
        let stored = StoredTaskList {
            list: TaskList {
                id: self.id,
                title: self.title,
                etag: self.etag,
                updated: self.updated,
            },
            sync_state: SyncState::parse(&self.sync_state).unwrap_or(SyncState::Clean),
            local_updated: self.local_updated,
            pending_op: self.pending_op,
            local_only: self.local_only,
        };
        (stored, tasks)
    }
}

impl BackupTask {
    /// Rebuild a stored task for `list_id`. Inverse of [`from_stored`].
    fn into_stored(self, list_id: &str) -> StoredTask {
        StoredTask {
            task: Task {
                id: self.id,
                parent: self.parent,
                position: self.position,
                title: self.title,
                notes: self.notes,
                status: TaskStatus::parse_api(&self.status).unwrap_or(TaskStatus::NeedsAction),
                due: self.due,
                completed: self.completed,
                etag: self.etag,
                updated: self.updated,
            },
            list_id: list_id.to_string(),
            sync_state: SyncState::parse(&self.sync_state).unwrap_or(SyncState::Clean),
            local_updated: self.local_updated,
            pending_op: self.pending_op,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Task, TaskList, TaskStatus};
    use crate::store::SyncState;

    fn list(id: &str, title: &str, local_only: bool) -> StoredTaskList {
        StoredTaskList {
            list: TaskList {
                id: id.into(),
                title: title.into(),
                etag: Some("etag-l".into()),
                updated: "2026-01-01T00:00:00Z".into(),
            },
            sync_state: SyncState::Clean,
            local_updated: "2026-01-02T00:00:00Z".into(),
            pending_op: None,
            local_only,
        }
    }

    fn task(id: &str, list_id: &str, title: &str) -> StoredTask {
        StoredTask {
            task: Task {
                id: id.into(),
                parent: None,
                position: "00000000000001".into(),
                title: title.into(),
                notes: None,
                status: TaskStatus::NeedsAction,
                due: None,
                completed: None,
                etag: Some("etag-t".into()),
                updated: "2026-01-01T00:00:00Z".into(),
            },
            list_id: list_id.into(),
            sync_state: SyncState::Clean,
            local_updated: "2026-01-02T00:00:00Z".into(),
            pending_op: None,
        }
    }

    #[test]
    fn build_sets_envelope_metadata() {
        let b = Backup::build("2026-06-08T00:00:00Z", vec![]);
        assert_eq!(b.version, BACKUP_VERSION);
        assert_eq!(b.app, "axiotask");
        assert_eq!(b.exported_at, "2026-06-08T00:00:00Z");
        assert!(b.lists.is_empty());
        assert_eq!(b.task_count(), 0);
    }

    #[test]
    fn build_preserves_lists_and_nested_tasks_in_order() {
        let l1 = list("L1", "Inbox", false);
        let l2 = list("L2", "Local", true);
        let b = Backup::build(
            "now",
            vec![
                (l1, vec![task("T1", "L1", "first"), task("T2", "L1", "second")]),
                (l2, vec![]),
            ],
        );
        assert_eq!(b.lists.len(), 2);
        assert_eq!(b.lists[0].id, "L1");
        assert!(!b.lists[0].local_only);
        assert_eq!(b.lists[0].tasks.len(), 2);
        assert_eq!(b.lists[0].tasks[0].title, "first");
        assert_eq!(b.lists[0].tasks[1].title, "second");
        assert_eq!(b.lists[1].id, "L2");
        assert!(b.lists[1].local_only);
        assert!(b.lists[1].tasks.is_empty());
        assert_eq!(b.task_count(), 2);
    }

    #[test]
    fn task_exports_every_field_with_no_loss() {
        let mut st = task("T1", "L1", "Pay rent");
        st.task.parent = Some("P0".into());
        st.task.position = "00000000000099".into();
        st.task.notes = Some("transfer to landlord".into());
        st.task.status = TaskStatus::Completed;
        st.task.due = Some("2026-07-01T00:00:00Z".into());
        st.task.completed = Some("2026-06-30T12:00:00Z".into());
        st.task.etag = Some("etag-xyz".into());
        st.task.updated = "2026-06-30T12:00:00Z".into();
        st.sync_state = SyncState::Dirty;
        st.local_updated = "2026-06-30T12:05:00Z".into();
        st.pending_op = Some("update".into());

        let b = Backup::build("now", vec![(list("L1", "Inbox", false), vec![st])]);
        let t = &b.lists[0].tasks[0];
        assert_eq!(t.id, "T1");
        assert_eq!(t.parent.as_deref(), Some("P0"));
        assert_eq!(t.position, "00000000000099");
        assert_eq!(t.title, "Pay rent");
        assert_eq!(t.notes.as_deref(), Some("transfer to landlord"));
        assert_eq!(t.status, "completed");
        assert_eq!(t.due.as_deref(), Some("2026-07-01T00:00:00Z"));
        assert_eq!(t.completed.as_deref(), Some("2026-06-30T12:00:00Z"));
        assert_eq!(t.etag.as_deref(), Some("etag-xyz"));
        assert_eq!(t.updated, "2026-06-30T12:00:00Z");
        assert_eq!(t.sync_state, "dirty");
        assert_eq!(t.local_updated, "2026-06-30T12:05:00Z");
        assert_eq!(t.pending_op.as_deref(), Some("update"));
        assert!(t.recurrence.is_none());
    }

    #[test]
    fn list_exports_all_sync_metadata() {
        let mut l = list("L1", "Work", false);
        l.sync_state = SyncState::Deleted;
        l.pending_op = Some("delete".into());
        let b = Backup::build("now", vec![(l, vec![])]);
        let bl = &b.lists[0];
        assert_eq!(bl.title, "Work");
        assert_eq!(bl.etag.as_deref(), Some("etag-l"));
        assert_eq!(bl.updated, "2026-01-01T00:00:00Z");
        assert_eq!(bl.sync_state, "deleted");
        assert_eq!(bl.local_updated, "2026-01-02T00:00:00Z");
        assert_eq!(bl.pending_op.as_deref(), Some("delete"));
    }

    #[test]
    fn recurring_task_keeps_notes_verbatim_and_adds_derived_summary() {
        let mut st = task("T1", "L1", "Water plants");
        // notes carry the recurrence trailer; it must survive verbatim.
        st.task.notes =
            Some("Water the plants\n[[recur:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE]]".into());

        let b = Backup::build("now", vec![(list("L1", "Inbox", false), vec![st])]);
        let t = &b.lists[0].tasks[0];
        // Source of truth preserved exactly (no stripping of the trailer).
        assert_eq!(
            t.notes.as_deref(),
            Some("Water the plants\n[[recur:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE]]")
        );
        // Derived, additive recurrence info present and parseable.
        let rec = t.recurrence.as_ref().expect("recurrence derived");
        assert!(rec.rrule.contains("FREQ=WEEKLY"));
        assert!(rec.rrule.contains("INTERVAL=2"));
        assert!(rec.rrule.contains("BYDAY=MO,WE"));
        assert!(!rec.summary.is_empty());
    }

    #[test]
    fn json_is_pretty_and_round_trips() {
        let b = Backup::build(
            "2026-06-08T00:00:00Z",
            vec![(list("L1", "Inbox", false), vec![task("T1", "L1", "Buy milk")])],
        );
        let json = b.to_json_pretty().expect("serialize");
        // Pretty-printed: contains newlines and indentation.
        assert!(json.contains('\n'));
        assert!(json.contains("  "));
        // Self-describing envelope is visible to a human reader.
        assert!(json.contains("\"version\": 1"));
        assert!(json.contains("\"app\": \"axiotask\""));
        // Lossless: deserializing yields the same structure.
        let back: Backup = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(back, b);
    }

    #[test]
    fn unknown_future_fields_are_ignored_on_read() {
        // Forward-compatibility: a backup written by a newer axiotask with
        // extra fields must still load in an older reader.
        let json = r#"{
            "version": 1,
            "app": "axiotask",
            "exported_at": "2026-06-08T00:00:00Z",
            "future_top_level": {"anything": true},
            "lists": [
                {
                    "id": "L1",
                    "title": "Inbox",
                    "updated": "2026-01-01T00:00:00Z",
                    "local_only": false,
                    "sync_state": "clean",
                    "local_updated": "2026-01-02T00:00:00Z",
                    "future_list_field": 42,
                    "tasks": []
                }
            ]
        }"#;
        let b: Backup = serde_json::from_str(json).expect("ignore unknown fields");
        assert_eq!(b.version, 1);
        assert_eq!(b.lists.len(), 1);
        assert_eq!(b.lists[0].id, "L1");
    }

    // ─── Import / restore (inverse of build) ─────────────────────────────────

    #[test]
    fn from_json_parses_a_backup_document() {
        let b = Backup::build(
            "2026-06-08T00:00:00Z",
            vec![(list("L1", "Inbox", false), vec![task("T1", "L1", "Buy milk")])],
        );
        let json = b.to_json_pretty().unwrap();
        let parsed = Backup::from_json(&json).expect("parse backup");
        assert_eq!(parsed, b);
    }

    #[test]
    fn from_json_rejects_malformed_input() {
        assert!(Backup::from_json("not json at all").is_err());
    }

    #[test]
    fn into_stored_is_the_inverse_of_build() {
        // A backup built from store rows must restore to byte-identical rows,
        // including every sync-metadata field and the verbatim notes trailer.
        let mut st = task("T1", "L1", "Pay rent");
        st.task.parent = Some("P0".into());
        st.task.position = "00000000000099".into();
        st.task.notes = Some("transfer\n[[recur:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE]]".into());
        st.task.status = TaskStatus::Completed;
        st.task.due = Some("2026-07-01T00:00:00Z".into());
        st.task.completed = Some("2026-06-30T12:00:00Z".into());
        st.sync_state = SyncState::Dirty;
        st.pending_op = Some("update".into());

        let mut l = list("L1", "Inbox", true);
        l.sync_state = SyncState::Deleted;
        l.pending_op = Some("delete".into());

        let original_list = l.clone();
        let original_task = st.clone();

        let restored = Backup::build("now", vec![(l, vec![st])]).into_stored();

        assert_eq!(restored.len(), 1);
        let (rlist, rtasks) = &restored[0];
        assert_eq!(*rlist, original_list);
        assert_eq!(rtasks.len(), 1);
        assert_eq!(rtasks[0], original_task);
    }

    #[test]
    fn into_stored_round_trips_through_json() {
        let backup = Backup::build(
            "now",
            vec![
                (
                    list("L1", "Inbox", false),
                    vec![task("T1", "L1", "a"), task("T2", "L1", "b")],
                ),
                (list("L2", "Work", true), vec![]),
            ],
        );
        let json = backup.to_json_pretty().unwrap();
        let restored = Backup::from_json(&json).unwrap().into_stored();

        assert_eq!(restored.len(), 2);
        assert_eq!(restored[0].0.list.id, "L1");
        assert_eq!(restored[0].1.len(), 2);
        // Each restored task is tagged with the list it belongs to.
        assert_eq!(restored[0].1[0].list_id, "L1");
        assert_eq!(restored[0].1[1].list_id, "L1");
        assert_eq!(restored[1].0.list.id, "L2");
        assert!(restored[1].0.local_only);
        assert!(restored[1].1.is_empty());
    }

    #[test]
    fn into_stored_degrades_unknown_enums_safely() {
        // A backup from a newer axiotask may carry enum strings this reader
        // doesn't know. They must degrade to safe defaults, never panic.
        let json = r#"{
            "version": 1, "app": "axiotask", "exported_at": "now",
            "lists": [{
                "id": "L1", "title": "Inbox", "updated": "u",
                "local_only": false, "sync_state": "weird", "local_updated": "lu",
                "tasks": [{
                    "id": "T1", "position": "p", "title": "t",
                    "status": "bogus", "updated": "u",
                    "sync_state": "nonsense", "local_updated": "lu"
                }]
            }]
        }"#;
        let restored = Backup::from_json(json).unwrap().into_stored();
        let (rlist, rtasks) = &restored[0];
        assert_eq!(rlist.sync_state, SyncState::Clean);
        assert_eq!(rtasks[0].sync_state, SyncState::Clean);
        assert_eq!(rtasks[0].task.status, TaskStatus::NeedsAction);
    }
}
