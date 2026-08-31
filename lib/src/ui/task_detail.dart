// The task detail panel — the ONLY home of subtasks (invariant #1): the list
// never renders a subtask as a row, and a subtask's own panel offers no way to
// add another (the two-level guard, [canAddSubtask]).
//
// Beyond the T2.4 skeleton (title/notes auto-save, add/toggle subtask, delete),
// this is the complete T7.4 surface:
//   • prev/next sibling navigation across the current view (flush edits first).
//   • the task's own due date: a tappable badge opening the calendar plus the
//     one-gesture quick-date strip, with the #164 cascade toast.
//   • per-subtask due dates, edited inline from the parent's checklist.
//   • "Hide completed" subtasks — a persisted, count-gated toggle that is UX
//     only (never mutates the tasks).
//   • "Un-complete all subtasks" (#89) — reopen a parent's finished children in
//     one action (un-completing never cascades on its own).
//   • hidden-aware subtask reorder via up/down buttons — steps are measured
//     against the FULL sibling list so a move stays correct across a hidden
//     completed row (#90).
//   • detach (#promoteTask): a subtask's panel can promote it back to top level.
//   • the List dropdown, shown for top-level tasks only — a subtask always
//     lives in its parent's list (#93). Moving lists repoints the panel to the
//     recreated row.
//   • clickable links detected in the title/notes.
//   • the #246 hierarchy: the app bar's direct row is Previous/Next ONLY, and
//     every action hangs off the one "⋮" — Duplicate, "Make subtask of…"
//     (#88's parent picker) or Detach, "Open in Google Tasks", then, divided
//     off and error-toned, Delete. The body reads title → Due + List → notes →
//     subtasks → links: the two fields the user edits sit directly under the
//     title, and nothing destructive is a thumb-slip from the navigation pair.
//   • the empty-subtask discard-on-close rule: closing an untitled, dateless,
//     childless subtask left untouched removes it — but NEVER one with children
//     of its own (that would silently take the subtree, with no undo).
//
// Live-tracking updates a field from the store WITHOUT clobbering what the user
// is typing (only an unfocused field is refreshed). Delete/move undo and the
// #164 cascade route through the app-wide [ToastController] (F19 #198) — the one
// feedback surface that out-stacks THIS panel, where a ScaffoldMessenger
// SnackBar would render behind it and be unreachable.

import 'package:async/async.dart' show RestartableTimer;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/pending_edits.dart';
import '../app/prefs_controller.dart';
import '../app/providers.dart';
import '../model/dates.dart' show DateMove;
import '../model/task.dart';
import '../model/task_tree.dart';
import '../store/stored.dart';
import 'date_format.dart';
import 'due_date_picker.dart';
import 'list_pickers.dart';
import 'quick_date_menu.dart';
import 'task_actions.dart' show demoteCandidates, duplicateTask;
import 'theme.dart';
import 'toast.dart';
import 'url_detect.dart';
import 'url_opener.dart';

/// The detail/edit panel for one task, identified by [taskId].
class TaskDetail extends ConsumerStatefulWidget {
  const TaskDetail({
    required this.taskId,
    required this.onClose,
    required this.onOpenTask,
    this.onPrev,
    this.onNext,
    this.autofocusNotes = false,
    super.key,
  });

  /// The task this panel shows.
  final String taskId;

  /// Focus the Notes field once the panel loads (the context menu's
  /// "Edit notes"); a one-shot honored on the first load of [taskId].
  final bool autofocusNotes;

  /// Close the panel (also called after the task is deleted).
  final VoidCallback onClose;

  /// Open another task's panel (a subtask title tap, a detach, a list move, or
  /// the breadcrumb up to a parent). The panel follows it.
  final ValueChanged<String> onOpenTask;

  /// Navigate to the previous / next sibling in the current view; `null`
  /// disables that direction (a boundary, or a subtask with no list ordering).
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  @override
  ConsumerState<TaskDetail> createState() => _TaskDetailState();
}

class _TaskDetailState extends ConsumerState<TaskDetail> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _notes = TextEditingController();
  final TextEditingController _newSubtask = TextEditingController();
  final FocusNode _titleFocus = FocusNode();
  final FocusNode _notesFocus = FocusNode();
  final FocusNode _newSubtaskFocus = FocusNode();

  // The task id the controllers were last loaded for, so switching the panel to
  // a different task re-seeds the fields (rather than clobbering across tasks).
  String? _loadedId;

  // The most recent task snapshot, so the focus-loss savers can diff against the
  // persisted values without re-reading the provider off the widget tree.
  StoredTask? _current;

  // Debounce for save-on-change: a focused field is persisted [_debounceDelay]
  // after the last keystroke, so an edit is never minutes-unsaved waiting for a
  // blur that a crash or a swiped-away process may never bring (#183). A
  // RestartableTimer (the repo bans a raw dart:async Timer below lib/, see
  // TESTING.md; Future.delayed can't be cancelled) is reset on each keystroke
  // and cancelled on dispose, so it never outlives the panel.
  static const _debounceDelay = Duration(seconds: 1);
  RestartableTimer? _debounce;

  // Captured once so [dispose] can unregister without an unsafe `ref` lookup.
  late final PendingEdits _pendingEdits;

  @override
  void initState() {
    super.initState();
    // Auto-save on blur, diff-only (see [_saveTitle] / [_saveNotes]).
    _titleFocus.addListener(() {
      if (!_titleFocus.hasFocus) _saveTitle();
    });
    _notesFocus.addListener(() {
      if (!_notesFocus.hasFocus) _saveNotes();
    });
    // Register the persist-now hooks for the paths that skip blur-save (#183):
    //   • [PendingEdit.detail] → save title/notes, run on BACKGROUNDING; and
    //   • the detail-close funnel → save AND discard an abandoned blank subtask,
    //     run on the system-back that closes this panel (G4), so it matches the
    //     panel's own Back button. The two are separate so backgrounding never
    //     deletes a task the user merely stepped away from.
    _pendingEdits = ref.read(pendingEditsProvider)
      ..register(PendingEdit.detail, _flushEdits)
      ..registerDetailClose(_flushAndDiscard);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _pendingEdits.unregister(PendingEdit.detail, _flushEdits);
    _pendingEdits.unregisterDetailClose(_flushAndDiscard);
    _title.dispose();
    _notes.dispose();
    _newSubtask.dispose();
    _titleFocus.dispose();
    _notesFocus.dispose();
    _newSubtaskFocus.dispose();
    super.dispose();
  }

  /// Persist any pending title/notes edits immediately (diff-only), cancelling a
  /// scheduled debounce since it has now happened. The registry entry for the
  /// system-back close and the app-backgrounded flush.
  void _flushEdits() {
    _debounce?.cancel();
    _saveTitle();
    _saveNotes();
  }

  /// Schedule (or restart) a debounced save after the current keystroke burst —
  /// so a focused field left mid-edit is persisted without waiting for a blur
  /// (#183).
  void _scheduleSave() {
    final debounce = _debounce;
    if (debounce == null || !debounce.isActive) {
      _debounce = RestartableTimer(_debounceDelay, _onDebounce);
    } else {
      debounce.reset();
    }
  }

  /// The debounce fired: persist if still mounted (the panel may have closed
  /// between the last keystroke and the timer).
  void _onDebounce() {
    if (mounted) _flushEdits();
  }

  /// Seed the fields from [task], or refresh an UNFOCUSED field when the store
  /// changed it out from under us (live-tracking without clobbering typing).
  void _sync(Task task) {
    if (task.id != _loadedId) {
      final firstEver = _loadedId == null;
      _loadedId = task.id;
      _title.text = task.title;
      _notes.text = task.notes ?? '';
      // Honor an "Edit notes" request once, on this task's first load.
      if (firstEver && widget.autofocusNotes) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _notesFocus.requestFocus();
        });
      }
      return;
    }
    if (!_titleFocus.hasFocus && _title.text != task.title) {
      _title.text = task.title;
    }
    final notes = task.notes ?? '';
    if (!_notesFocus.hasFocus && _notes.text != notes) _notes.text = notes;
  }

  void _saveTitle() {
    final task = _current?.task;
    if (task == null) return;
    final value = _title.text.trim();
    // Diff-only: an unchanged (or empty) title never queues a write. The
    // empty-⇒-delete inline-rename rule lives on the row (T7.2), not here; the
    // empty-subtask discard rule handles abandonment on close.
    if (value.isEmpty || value == task.title) return;
    ref.read(commandsProvider).renameTask(task.id, value);
  }

  void _saveNotes() {
    final task = _current?.task;
    if (task == null) return;
    final value = _notes.text;
    if (value == (task.notes ?? '')) return; // diff-only
    ref.read(commandsProvider).setNotes(task.id, value);
  }

  Future<void> _addSubtask(StoredTask parent) async {
    final title = _newSubtask.text.trim();
    if (title.isEmpty) return; // an empty add creates nothing
    await ref
        .read(commandsProvider)
        .createTask(
          listId: parent.listId,
          parentId: parent.task.id,
          title: title,
        );
    if (!mounted) return;
    _newSubtask.clear();
    // Keep focus for rapid successive entry.
    _newSubtaskFocus.requestFocus();
  }

  Future<void> _delete(StoredTask task) async {
    // Flush any pending field edits before the row goes away.
    _saveTitle();
    _saveNotes();
    final commands = ref.read(commandsProvider);
    final toasts = ref.read(toastControllerProvider);
    final token = await commands.deleteTask(task.task.id);
    if (!mounted) return;
    toasts.showUndo(
      'Deleted "${task.task.title}"',
      () => commands.undoDelete(token),
    );
    widget.onClose();
  }

  /// Flush edits, then discard the task if it is an abandoned empty subtask.
  /// Everything that leaves this panel (close, prev/next, breadcrumb, opening a
  /// subtask) funnels through here so a blank subtask never lingers — yet one
  /// with children of its own is always kept.
  void _flushAndDiscard() {
    _saveTitle();
    _saveNotes();
    _discardIfEmptySubtask();
  }

  // The id already sent to discard, so running the flush-and-discard funnel
  // twice for the same task never double-deletes it. That double happens on the
  // panel's OWN Back button in the shell: [_close] discards directly, then its
  // `widget.onClose` (the shell's closeDetail) runs the detail-close funnel,
  // which discards again — and a second deleteTask on an already-gone id throws
  // in the real command layer (G4 #183).
  String? _discardedId;

  /// The #DetailWorkflow rule: an untitled, note-less, dateless SUBTASK left
  /// open (not completed) and WITHOUT children of its own is debris — remove it.
  /// A subtask with children is never touched: deleting it cascades the whole
  /// subtree away, silently and with no undo token.
  void _discardIfEmptySubtask() {
    final all =
        ref.read(allTasksProvider).asData?.value ?? const <StoredTask>[];
    final t = _current?.task;
    if (t == null || t.id == _discardedId) return;
    final empty =
        t.parent != null &&
        t.status != TaskStatus.completed &&
        t.title.trim().isEmpty &&
        (t.notes ?? '').trim().isEmpty &&
        (t.due ?? '').isEmpty &&
        !all.any((c) => c.task.parent == t.id);
    if (empty) {
      _discardedId = t.id;
      ref.read(commandsProvider).deleteTask(t.id);
    }
  }

  void _close() {
    _flushAndDiscard();
    widget.onClose();
  }

  void _navigate(VoidCallback go) {
    _flushAndDiscard();
    go();
  }

  /// Set the task's OWN due date from a one-gesture quick move, surfacing any
  /// #164 cascade as an undoable toast.
  Future<void> _quickDue(String id, DateMove move) async {
    final toasts = ref.read(toastControllerProvider);
    final commands = ref.read(commandsProvider);
    final res = await commands.setDue(id, move);
    if (!mounted) return;
    offerDueCascadeUndo(toasts, commands, res);
  }

  /// Open the calendar for [id] on [currentDue] and apply the choice (a picked
  /// day via `setDueRaw`, Clear via `setDue`), then surface any #164 cascade.
  /// A dismissed picker leaves the date untouched. Shared by the task's own due
  /// badge and each subtask's inline due button.
  Future<void> _pickDue(String id, String? currentDue) async {
    final toasts = ref.read(toastControllerProvider);
    final commands = ref.read(commandsProvider);
    final pick = await showDueDatePicker(context, initial: currentDue);
    if (pick == null || !mounted) return;
    final res = switch (pick) {
      DuePickClear() => await commands.setDue(id, DateMove.clear),
      DuePickDate(:final ymd) => await commands.setDueRaw(id, ymd),
    };
    if (!mounted) return;
    offerDueCascadeUndo(toasts, commands, res);
  }

  /// Reopen every completed subtask of [parentId] (#89). Un-completing a parent
  /// never cascades to its children, so this is the explicit "reopen the whole
  /// checklist" action.
  Future<void> _uncompleteAll(String parentId, List<StoredTask> all) async {
    final commands = ref.read(commandsProvider);
    for (final c in all) {
      if (c.task.parent == parentId && c.task.status == TaskStatus.completed) {
        await commands.toggleComplete(c.task.id);
      }
    }
  }

  /// Move [subId] UP so it renders just above its visible neighbour [aboveId] —
  /// it takes that neighbour's slot, following whatever [aboveId] itself
  /// followed in the FULL ordered [children] (position order), so the move stays
  /// correct across hidden completed rows when "Hide completed" is on (#90).
  /// Issued as ONE anchored reorder (G1 #202): crossing hidden rows emits no
  /// burst of awaited single steps and no display-order slot index.
  Future<void> _reorderUp(
    String subId,
    String aboveId,
    List<StoredTask> children,
  ) async {
    final at = children.indexWhere((c) => c.task.id == aboveId);
    if (at < 0) return;
    // Follow whatever the neighbour above currently follows (null = the front).
    final previousId = at == 0 ? null : children[at - 1].task.id;
    await ref.read(commandsProvider).reorderTaskAfter(subId, previousId);
  }

  /// Move [subId] DOWN so it renders just below its visible neighbour
  /// [belowId] — it lands directly after that neighbour in the FULL ordered
  /// list, crossing any hidden completed rows between them in one move (#90).
  Future<void> _reorderDown(String subId, String belowId) =>
      ref.read(commandsProvider).reorderTaskAfter(subId, belowId);

  /// Detach [subId] from its parent, promoting it to top level directly after
  /// its former parent (#promoteTask). The row keeps its id, so the panel stays
  /// open on it — now showing the top-level affordances.
  Future<void> _detach(String subId, String parentId) async {
    _saveTitle();
    _saveNotes();
    await ref
        .read(commandsProvider)
        .moveTask(subId, parentId: null, previousId: parentId);
  }

  /// Copy this task as "`<title>` (copy)" in the same list and under the same
  /// parent — the ONE duplicate rule ([duplicateTask]) the desktop context menu
  /// and the bulk bar also use. Pending field edits are flushed first, and the
  /// copy is taken from the LIVE title, so duplicating mid-rename copies what is
  /// on screen rather than the last-saved value.
  Future<void> _duplicate(StoredTask t) async {
    _flushEdits();
    final typed = _title.text.trim();
    await duplicateTask(
      ref.read(commandsProvider),
      t,
      title: typed.isEmpty ? null : typed,
    );
    if (!mounted) return;
    // The panel stays on the original, so without a word nothing on screen says
    // the copy happened.
    ref.read(toastControllerProvider).showInfo('Duplicated');
  }

  /// Nest this task under a parent chosen from the #88 picker (offered only for
  /// a childless top-level task with a legal host — see [demoteCandidates]).
  Future<void> _demote(StoredTask t, List<StoredTask> candidates) async {
    if (candidates.isEmpty) return;
    _flushEdits();
    final parentId = await showParentPicker(context, candidates: candidates);
    if (parentId == null || !mounted) return;
    await ref.read(commandsProvider).moveTask(t.task.id, parentId: parentId);
  }

  /// Move the top-level [id] to [targetListId]. `moveTaskToList` recreates the
  /// subtree under a fresh id and returns it, so the panel repoints there (#93
  /// only hides this affordance for subtasks — a parent may still move lists).
  /// A brief toast confirms the move, since the row otherwise just vanishes
  /// from the current view.
  Future<void> _moveList(
    String id,
    String targetListId,
    String targetTitle,
  ) async {
    final commands = ref.read(commandsProvider);
    final toasts = ref.read(toastControllerProvider);
    final token = await commands.moveTaskToList(id, targetListId);
    if (!mounted || token == null) return;
    toasts.showUndo('Moved to $targetTitle', () {
      commands.undoMoveToList(token);
      // Repoint the panel to the restored original (revived in place, so its id
      // is stable) rather than the now-deleted clone.
      widget.onOpenTask(token.original.id);
    });
    widget.onOpenTask(token.newRootId);
  }

  @override
  Widget build(BuildContext context) {
    final all =
        ref.watch(allTasksProvider).asData?.value ?? const <StoredTask>[];
    final matches = all.where((t) => t.task.id == widget.taskId);
    final current = matches.isEmpty ? null : matches.first;
    _current = current;

    if (current == null) {
      // The task was deleted (or never existed) — the panel reacts rather than
      // stranding a stale row.
      return _MissingTask(onClose: widget.onClose);
    }
    _sync(current.task);

    final task = current.task;
    final subtask = isSubtask(task);
    final children = all.where((t) => t.task.parent == task.id).toList()
      ..sort((a, b) => a.task.position.compareTo(b.task.position));
    final completedCount = children
        .where((c) => c.task.status == TaskStatus.completed)
        .length;
    final hideCompleted = ref.watch(
      prefsControllerProvider.select((p) => p.hideCompletedSubtasks),
    );
    final visibleChildren = hideCompleted
        ? children.where((c) => c.task.status != TaskStatus.completed).toList()
        : children;
    // Parent (for a subtask's breadcrumb + detach) and the lists (for a
    // top-level task's List dropdown).
    final parent = subtask
        ? all.where((t) => t.task.id == task.parent).firstOrNull
        : null;
    final lists = ref.watch(orderedListsProvider);
    final links = urlsForTask(title: task.title, notes: task.notes);
    // The legal parents this task could be nested under (#88) — empty for a
    // subtask, for a task with children, and when the list holds no other
    // childless top-level task.
    final hosts = subtask
        ? const <StoredTask>[]
        : demoteCandidates(current, all);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back',
            onPressed: _close,
          ),
          title: Text(subtask ? 'Subtask' : 'Task Details'),
          actions: [
            IconButton(
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Previous task',
              onPressed: widget.onPrev == null
                  ? null
                  : () => _navigate(widget.onPrev!),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Next task',
              onPressed: widget.onNext == null
                  ? null
                  : () => _navigate(widget.onNext!),
            ),
            // Every non-navigation action lives behind the one "⋮": the app
            // bar's direct row is Previous/Next only, so the thumb that walks
            // the list never lands a pixel away from Delete (#246).
            PopupMenuButton<String>(
              key: const Key('detail-overflow'),
              tooltip: 'More actions',
              icon: const Icon(Icons.more_vert),
              onSelected: (value) {
                switch (value) {
                  case 'duplicate':
                    _duplicate(current);
                  case 'demote':
                    _demote(current, hosts);
                  case 'detach':
                    _detach(task.id, task.parent!);
                  case 'open-google':
                    ref.read(urlOpenerProvider)(task.webViewLink!);
                  case 'delete':
                    _delete(current);
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem<String>(
                  key: Key('detail-duplicate'),
                  value: 'duplicate',
                  child: Row(
                    children: [
                      Icon(Icons.copy_all_outlined, size: 20),
                      SizedBox(width: 12),
                      // A Material menu caps its width; at a large text scale
                      // the label wraps rather than being clipped away.
                      Flexible(child: Text('Duplicate')),
                    ],
                  ),
                ),
                // Only a childless TOP-LEVEL task with a legal host may be
                // demoted: a subtask goes the other way (Detach), and a parent
                // can never become a subtask (invariant #1).
                if (!subtask && hosts.isNotEmpty)
                  const PopupMenuItem<String>(
                    key: Key('detail-demote'),
                    value: 'demote',
                    child: Row(
                      children: [
                        Icon(Icons.subdirectory_arrow_right, size: 20),
                        SizedBox(width: 12),
                        Flexible(child: Text('Make subtask of…')),
                      ],
                    ),
                  ),
                if (subtask)
                  const PopupMenuItem<String>(
                    key: Key('detail-detach'),
                    value: 'detach',
                    child: Row(
                      children: [
                        Icon(Icons.subdirectory_arrow_left, size: 20),
                        SizedBox(width: 12),
                        Flexible(child: Text('Detach subtask')),
                      ],
                    ),
                  ),
                // Google assigns the webViewLink on sync; a not-yet-synced task
                // has none, so the entry appears only once it exists. Opens the
                // task in the Google Tasks web app (to set a repeat, etc.).
                if (task.webViewLink != null)
                  const PopupMenuItem<String>(
                    key: Key('detail-open-google'),
                    value: 'open-google',
                    child: Row(
                      children: [
                        Icon(Icons.open_in_new, size: 20),
                        SizedBox(width: 12),
                        Flexible(child: Text('Open in Google Tasks')),
                      ],
                    ),
                  ),
                const PopupMenuDivider(),
                // Last, divided off and error-toned: the only destructive entry
                // reads as one before the finger commits. Undo still follows.
                PopupMenuItem<String>(
                  key: const Key('detail-delete'),
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(
                        Icons.delete_outline,
                        size: 20,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          'Delete',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (subtask && parent != null)
                _Breadcrumb(
                  parentTitle: parent.task.title,
                  onOpenParent: () =>
                      _navigate(() => widget.onOpenTask(parent.task.id)),
                ),
              TextField(
                controller: _title,
                focusNode: _titleFocus,
                decoration: const InputDecoration(
                  labelText: 'Title',
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.done,
                onChanged: (_) => _scheduleSave(),
                onSubmitted: (_) => _saveTitle(),
              ),
              // The two fields the user actually edits sit directly under the
              // title — nothing prominent comes between (#246).
              const SizedBox(height: 16),
              _DueAndList(
                due: _DueField(
                  due: task.due,
                  onPick: () => _pickDue(task.id, task.due),
                  onQuick: (m) => _quickDue(task.id, m),
                ),
                // #93: a subtask always lives in its parent's list.
                list: subtask
                    ? null
                    : _ListDropdown(
                        value: current.listId,
                        lists: lists,
                        onChanged: (target) => _moveList(
                          task.id,
                          target,
                          lists
                              .firstWhere((l) => l.list.id == target)
                              .list
                              .title,
                        ),
                      ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _notes,
                focusNode: _notesFocus,
                minLines: 3,
                maxLines: 6,
                onChanged: (_) => _scheduleSave(),
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
              // Subtasks are top-level tasks' business only — a subtask's panel
              // shows no checklist and no add input (invariant #1).
              if (!subtask) ...[
                const SizedBox(height: 24),
                _SubtaskHeader(
                  completedCount: completedCount,
                  totalCount: children.length,
                  hideCompleted: hideCompleted,
                  onHideCompleted: (v) => ref
                      .read(prefsControllerProvider.notifier)
                      .setHideCompletedSubtasks(v),
                  onUncompleteAll: () => _uncompleteAll(task.id, all),
                ),
                for (var i = 0; i < visibleChildren.length; i++)
                  _SubtaskRow(
                    key: ValueKey(visibleChildren[i].task.id),
                    task: visibleChildren[i].task,
                    isFirst: i == 0,
                    isLast: i == visibleChildren.length - 1,
                    onToggle: () => ref
                        .read(commandsProvider)
                        .toggleComplete(visibleChildren[i].task.id),
                    onOpen: () => _navigate(
                      () => widget.onOpenTask(visibleChildren[i].task.id),
                    ),
                    onPickDue: () => _pickDue(
                      visibleChildren[i].task.id,
                      visibleChildren[i].task.due,
                    ),
                    onSetDue: (m) => _quickDue(visibleChildren[i].task.id, m),
                    onMoveUp: i == 0
                        ? null
                        : () => _reorderUp(
                            visibleChildren[i].task.id,
                            visibleChildren[i - 1].task.id,
                            children,
                          ),
                    onMoveDown: i == visibleChildren.length - 1
                        ? null
                        : () => _reorderDown(
                            visibleChildren[i].task.id,
                            visibleChildren[i + 1].task.id,
                          ),
                  ),
                _AddSubtaskField(
                  controller: _newSubtask,
                  focusNode: _newSubtaskFocus,
                  onSubmit: () => _addSubtask(current),
                ),
              ],
              // Derived reading matter, not an edited field: it trails the
              // whole panel rather than splitting notes from the subtasks.
              if (links.isNotEmpty) ...[
                const SizedBox(height: 16),
                _Links(urls: links, onOpen: ref.read(urlOpenerProvider)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// The subtask breadcrumb ("← Parent") atop a subtask's own panel — the way
/// back up, and nothing else: detaching is an action, and every action lives in
/// the app-bar overflow (#246), so no button outranks the title.
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.parentTitle, required this.onOpenParent});

  final String parentTitle;
  final VoidCallback onOpenParent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: onOpenParent,
          icon: const Icon(Icons.arrow_back, size: 16),
          label: Text(
            parentTitle.isEmpty ? 'Parent task' : parentTitle,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

/// The task's own due date: one field that raises the ONE shared quick-date
/// option set (#243) — Today · Tomorrow · Next week · Next month ·
/// Pick a date… · Clear.
///
/// It used to be a calendar button with its OWN chip row beneath it, worded
/// "+1 week" / "+1 month" — a second vocabulary for the moves the rest of the
/// app called "Next week" / "Next month", and one that could not reach the
/// calendar or a clear without leaving the chips. One control, one list.
///
/// The date itself wears the SHARED urgency tone (#242) — the same colour the
/// row's due badge and the Focus "Overdue (N)" heading use — so opening a task
/// never changes what its date's colour means. The outline stays neutral: the
/// urgency is a property of the DATE, not of the control around it.
class _DueField extends StatelessWidget {
  const _DueField({
    required this.due,
    required this.onPick,
    required this.onQuick,
  });

  final String? due;

  /// Open the calendar ("Pick a date…").
  final VoidCallback onPick;

  /// Apply a frozen move from the shared menu.
  final ValueChanged<DateMove> onQuick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final has = (due ?? '').isNotEmpty;
    final label = has ? formatDue(due) : 'No date';
    final urgency = has ? dueUrgency(due) : DueUrgency.none;
    final color = dueColor(urgency, theme.colorScheme);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Due date', style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        QuickDateAnchor(
          onSetDue: onQuick,
          onPickDate: onPick,
          builder: (context, open) => OutlinedButton.icon(
            key: const Key('due-field'),
            onPressed: open,
            icon: const Icon(Icons.event_outlined, size: 18),
            label: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                label.isEmpty ? 'No date' : label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                // Semibold on overdue only — the same emphasis the row's badge
                // carries, so the two surfaces read as one signal.
                style: TextStyle(
                  color: color,
                  fontWeight: urgency == DueUrgency.overdue
                      ? FontWeight.w600
                      : null,
                ),
              ),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: color,
              minimumSize: const Size.fromHeight(44),
              alignment: Alignment.centerLeft,
            ),
          ),
        ),
      ],
    );
  }
}

/// The Due-date and List pair. They are the panel's two structured fields and
/// are edited together, so on a wide panel they share ONE compact line and the
/// notes stay above the fold; below [_sideBySide] there is no honest room for
/// two controls, and they stack — Due first.
class _DueAndList extends StatelessWidget {
  const _DueAndList({required this.due, required this.list});

  final Widget due;

  /// `null` for a subtask, which has no List field at all (#93) — the Due field
  /// then simply takes the full width.
  final Widget? list;

  /// Below this the two controls would each be narrower than a date reads. It
  /// is scaled by the ambient text scale: at 1.3x the same pixels hold less
  /// text, so a surface that fits both at 1.0x correctly stacks them instead of
  /// ellipsising a list name away.
  static const double _sideBySide = 480;

  @override
  Widget build(BuildContext context) {
    final list = this.list;
    if (list == null) return due;
    final threshold = MediaQuery.textScalerOf(context).scale(_sideBySide);
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth >= threshold
          ? Row(
              // The two controls have different intrinsic heights (a button vs
              // a decorated dropdown); aligning their BOTTOMS keeps the tappable
              // edges on one line.
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: due),
                const SizedBox(width: 12),
                Expanded(child: list),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [due, const SizedBox(height: 16), list],
            ),
    );
  }
}

/// The top-level task's List dropdown — a subtask never renders this (#93).
class _ListDropdown extends StatelessWidget {
  const _ListDropdown({
    required this.value,
    required this.lists,
    required this.onChanged,
  });

  final String value;
  final List<StoredTaskList> lists;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final ids = {for (final l in lists) l.list.id};
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'List',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: const Key('list-dropdown'),
          value: ids.contains(value) ? value : null,
          isExpanded: true,
          items: [
            for (final l in lists)
              DropdownMenuItem(
                value: l.list.id,
                child: Text(
                  l.list.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) {
            if (v != null && v != value) onChanged(v);
          },
        ),
      ),
    );
  }
}

/// The clickable links found in the task's title/notes.
class _Links extends StatelessWidget {
  const _Links({required this.urls, required this.onOpen});

  final List<String> urls;
  final UrlOpener onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Links', style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        for (final url in urls)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: Key('link-$url'),
              onPressed: () => onOpen(url),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: Text(url, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
      ],
    );
  }
}

/// The subtasks section header: the "Subtasks" label, the "x of y complete"
/// summary, the count-gated "Hide completed" toggle, and the count-gated
/// "Un-complete all subtasks" action.
class _SubtaskHeader extends StatelessWidget {
  const _SubtaskHeader({
    required this.completedCount,
    required this.totalCount,
    required this.hideCompleted,
    required this.onHideCompleted,
    required this.onUncompleteAll,
  });

  final int completedCount;

  /// EVERY subtask, including the completed ones "Hide completed" removes from
  /// view — the summary states the task's real progress, not the visible slice
  /// (#220).
  final int totalCount;
  final bool hideCompleted;
  final ValueChanged<bool> onHideCompleted;
  final VoidCallback onUncompleteAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Subtasks', style: theme.textTheme.titleSmall),
            ),
            // The toggle only exists once something can be hidden — an
            // affordance that would do nothing must not render.
            if (completedCount > 0)
              InkWell(
                onTap: () => onHideCompleted(!hideCompleted),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: hideCompleted,
                        onChanged: (v) => onHideCompleted(v ?? false),
                      ),
                      Text('Hide completed', style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
          ],
        ),
        // The bar on the task row shows the same progress as a shape; here the
        // number is spelled out so nothing has to be estimated (#220).
        if (totalCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text(
              '$completedCount of $totalCount complete',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (completedCount > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: onUncompleteAll,
              child: const Text('Un-complete all subtasks'),
            ),
          ),
      ],
    );
  }
}

/// One subtask checklist row: a real checkbox toggles completion, the title
/// opens the subtask's own panel, up/down buttons reorder it (hidden-aware,
/// disabled at the visible ends), and a due button edits its date inline.
class _SubtaskRow extends StatelessWidget {
  const _SubtaskRow({
    required this.task,
    required this.isFirst,
    required this.isLast,
    required this.onToggle,
    required this.onOpen,
    required this.onPickDue,
    required this.onSetDue,
    required this.onMoveUp,
    required this.onMoveDown,
    super.key,
  });

  final Task task;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onToggle;
  final VoidCallback onOpen;

  /// Open the calendar for this subtask ("Pick a date…").
  final VoidCallback onPickDue;

  /// Apply a frozen move to this subtask from the shared menu.
  final ValueChanged<DateMove> onSetDue;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final done = task.status == TaskStatus.completed;
    final hasDue = (task.due ?? '').isNotEmpty;
    return Row(
      children: [
        // 48dp hit area (the glyph stays default-sized — enlarge the target,
        // never the checkbox, #167).
        SizedBox(
          width: 48,
          height: 48,
          child: Checkbox(value: done, onChanged: (_) => onToggle()),
        ),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              // The title is the flexible element of the row (it sits in the
              // Expanded above): a long subtask title ellipsizes on one line so
              // the fixed reorder arrows + due button never get pushed off the
              // edge and overflow a narrow detail pane (G9 #208).
              child: Text(
                task.title.isEmpty ? 'Untitled' : task.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  decoration: done ? TextDecoration.lineThrough : null,
                  color: done ? completedTitleColor(theme.colorScheme) : null,
                ),
              ),
            ),
          ),
        ),
        // Reorder buttons (the touch path; work with a mouse too). Disabled at
        // the visible boundaries.
        IconButton(
          key: Key('sub-up-${task.id}'),
          icon: const Icon(Icons.keyboard_arrow_up),
          iconSize: 20,
          tooltip: 'Move up',
          onPressed: onMoveUp,
        ),
        IconButton(
          key: Key('sub-down-${task.id}'),
          icon: const Icon(Icons.keyboard_arrow_down),
          iconSize: 20,
          tooltip: 'Move down',
          onPressed: onMoveDown,
        ),
        // The per-subtask due button. Its tooltip carries the precise ISO date
        // (stable for tests) while the visible label is the friendly form.
        //
        // It wears the shared urgency tone too (#242): it is a DATE on the same
        // panel as the parent's Due field, and leaving it on the button default
        // would paint every subtask date — overdue ones included — in the tone
        // that now means "due today".
        // The same quick-date set the parent's Due field raises (#243): a
        // subtask is dated the way everything else in the app is dated.
        QuickDateAnchor(
          onSetDue: onSetDue,
          onPickDate: onPickDue,
          sheetTitle: 'Subtask due date',
          builder: (context, open) => Tooltip(
            message:
                'Subtask due date: ${hasDue ? task.due!.substring(0, 10) : 'No date'}',
            child: TextButton(
              key: Key('sub-due-${task.id}'),
              onPressed: open,
              style: TextButton.styleFrom(
                foregroundColor: dueColor(
                  hasDue ? dueUrgency(task.due) : DueUrgency.none,
                  theme.colorScheme,
                ),
              ),
              child: Text(hasDue ? formatDue(task.due) : 'no date'),
            ),
          ),
        ),
      ],
    );
  }
}

/// The inline "Add a subtask" input — Enter or the + button creates the child
/// and the caller keeps focus for rapid entry.
class _AddSubtaskField extends StatelessWidget {
  const _AddSubtaskField({
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              decoration: const InputDecoration(
                hintText: 'Add a subtask',
                isDense: true,
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => onSubmit(),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add subtask',
            onPressed: onSubmit,
          ),
        ],
      ),
    );
  }
}

/// Shown when the panel's task is gone (deleted or never existed).
class _MissingTask extends StatelessWidget {
  const _MissingTask({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back',
            onPressed: onClose,
          ),
          title: const Text('Details'),
        ),
        const Expanded(
          child: Center(child: Text('This task is no longer available.')),
        ),
      ],
    );
  }
}
