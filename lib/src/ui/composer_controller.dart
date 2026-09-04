// The quick-add composer, lifted ABOVE the view switch (#274).
//
// The composer used to belong to whichever [TaskListView] happened to be
// mounted, and that is exactly one thing too many: a view switch mounts TWO
// panes at once ([ViewSwitch] keeps the outgoing one alive for the length of
// the cross-fade), so there were briefly two composers. Both of them listened
// to the FAB, so one tap opened two stacked bottom sheets; the lower one was
// aimed at the view the user had just LEFT, because it still held that view's
// list snapshot and its own default target. And a half-typed title died with
// the pane the moment the user tapped another tab.
//
// [ComposerHost] owns it instead — one controller, one draft, one focus node,
// one FAB listener, for the whole app — and publishes it to the panes below
// through [ComposerScope]. The panes never own creation again; they ask.
//
// What is still per-VIEW is the AIM (#217/#264): moving to another view drops
// the picked date and destination back to that view's defaults rather than
// silently keeping tasks flowing into the list — or onto the date — you left
// behind. The typed TITLE is not an aim; it survives, because a tab tap is not
// a decision to throw away what you were writing.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/pending_edits.dart';
import '../app/prefs_controller.dart';
import '../app/providers.dart';
import '../app/quick_add.dart';
import '../model/dates.dart' show DateMove, ymdForMove;
import '../model/task_view.dart';
import '../store/stored.dart';
import 'bulk_add.dart';
import 'composer_draft.dart';
import 'composer_sheet.dart';
import 'due_date_picker.dart';
import 'new_task_fab.dart' show NewTaskFab;
import 'quick_add_bar.dart';
import 'theme.dart';
import 'toast.dart';
import 'views.dart';
import 'visible_rows.dart';

/// Everything a composer surface — the desktop bar, the phone's sheet, the
/// toolbar's bulk-add — needs from the one composer.
///
/// A [Listenable]: it forwards the draft's own notifications, so any surface
/// showing the aim rebuilds when the aim moves, from whichever surface moved
/// it. There is exactly one value and no second copy of it to drift (#264).
abstract class ComposerController implements Listenable {
  /// The single text field every composer surface attaches to.
  TextEditingController get text;

  /// The draft AIM — the picked due date, the silenced date phrase, and the
  /// destination list.
  ComposerDraft get draft;

  /// The view the composer is currently aimed at.
  String get viewId;

  /// The list a fresh insert targets given the CURRENT [lists]: the user's pick
  /// while it is still a known list, else the view's own default. A picked list
  /// can vanish under the composer (a sync deletes it elsewhere) — falling back
  /// keeps the add landing somewhere real instead of against a dead id.
  String? targetListIn(List<StoredTaskList> lists);

  /// The list a fresh insert targets when the user has picked nothing: the
  /// current list, or the first list when a smart view is active. Also what the
  /// bulk-add dialog opens on, and `null` when there is no list to create in at
  /// all (which is what disables both creation entries).
  String? defaultTargetIn(List<StoredTaskList> lists);

  /// The natural-language due parsed from the current input, unless the user
  /// dismissed it for this exact text — or the date they picked outright.
  String? get previewDue;

  /// Aim the next add at [listId].
  void aimAtList(String listId);

  /// Set the draft's date from the shared quick-date set (#243).
  void setDue(DateMove move);

  /// Open the calendar for the draft ("Pick a date…").
  Future<void> pickDue(BuildContext context);

  /// The date chip's ×: keep the typed phrase as literal title text.
  void dismissPreview();

  /// Commit the current draft as a task.
  Future<void> submit();

  /// Accept the multi-line-paste offer (#219): one task per line.
  Future<void> addPastedLines(String raw);

  /// Open the touch composer sheet (the FAB's own surface).
  Future<void> openSheet(BuildContext context);

  /// Open the bulk-add dialog on this view's default target list; `null` when
  /// there is no list to create in.
  Future<void>? openBulkAdd(BuildContext context);
}

/// Publishes the app's one [ComposerController] to the list panes below it.
class ComposerScope extends InheritedNotifier<ComposerController> {
  const ComposerScope({
    required ComposerController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static ComposerController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ComposerScope>()?.notifier;

  static ComposerController of(BuildContext context) => maybeOf(context)!;
}

/// Mounts the app's one composer above [child] (the view switch), rendering the
/// always-visible desktop bar itself and publishing the controller downwards.
class ComposerHost extends ConsumerStatefulWidget {
  const ComposerHost({
    required this.viewId,
    required this.child,
    this.selectedTaskId,
    this.onOpenTask,
    this.onOpenInView,
    super.key,
  });

  /// The view the composer is aimed at — the source of its default target list
  /// and of the smart view's implied due date.
  final String viewId;

  /// The task the detail panel currently shows, or `null` when it is closed —
  /// drives the "new task follows the open panel" behavior.
  final String? selectedTaskId;

  /// Open the detail panel for a task id.
  final ValueChanged<String>? onOpenTask;

  /// Open a task in a SPECIFIC view — the landing toast's "View" jump (#190).
  final void Function(String viewId, String taskId)? onOpenInView;

  final Widget child;

  @override
  ConsumerState<ComposerHost> createState() => _ComposerHostState();
}

/// The controller's [Listenable] half, held rather than mixed in: a
/// `ChangeNotifier` mixed onto a `State` hijacks `super.dispose()` (it resolves
/// to the notifier's, and the element is never released).
class _ComposerNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

class _ComposerHostState extends ConsumerState<ComposerHost>
    implements ComposerController {
  final _ComposerNotifier _notifier = _ComposerNotifier();

  @override
  void addListener(VoidCallback listener) => _notifier.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _notifier.removeListener(listener);

  @override
  final TextEditingController text = TextEditingController();

  @override
  final ComposerDraft draft = ComposerDraft();

  @override
  String get viewId => widget.viewId;

  late final PendingEdits _pendingEdits;

  bool get _isSmartView => SmartView.byId(widget.viewId) != null;

  List<StoredTaskList> get _lists =>
      ref.read(listsProvider).asData?.value ?? const <StoredTaskList>[];

  /// Mirrors the reference's bulkTargetList.
  @override
  String? defaultTargetIn(List<StoredTaskList> lists) => _isSmartView
      ? (lists.isEmpty ? null : lists.first.list.id)
      : widget.viewId;

  @override
  String? targetListIn(List<StoredTaskList> lists) {
    final picked = draft.pickedListId;
    if (picked != null && lists.any((l) => l.list.id == picked)) return picked;
    return defaultTargetIn(lists);
  }

  @override
  String? get previewDue =>
      draft.pickedDue ??
      (text.text == draft.dateIgnoredFor ? null : parseQuickAddDue(text.text));

  @override
  void initState() {
    super.initState();
    // The composer's surfaces render the aim, so they rebuild when it moves.
    draft.addListener(_notifier.notify);
    // A non-empty quick-add draft is an in-progress "create a task" edit; commit
    // it when the app is backgrounded so a swiped-away process never loses it
    // (#183). Captured so [dispose] unregisters without a `ref` lookup on a
    // deactivated widget.
    _pendingEdits = ref.read(pendingEditsProvider)
      ..register(PendingEdit.quickAdd, _flushDraft);
  }

  @override
  void didUpdateWidget(covariant ComposerHost old) {
    super.didUpdateWidget(old);
    if (old.viewId != widget.viewId) {
      // The aim belongs to the VIEW, not the session (#217/#264). The typed
      // title does not: it is what the user was writing, and a tab tap is not a
      // decision to discard it.
      draft.release();
      // "Just created here" stops being true the moment "here" changes.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(newestTaskProvider.notifier).clear();
      });
    }
  }

  @override
  void dispose() {
    _pendingEdits.unregister(PendingEdit.quickAdd, _flushDraft);
    draft.removeListener(_notifier.notify);
    _notifier.dispose();
    text.dispose();
    draft.dispose();
    // The FocusNode is owned by quickAddFocusProvider (app-wide) — not disposed
    // here.
    super.dispose();
  }

  // ── the aim ───────────────────────────────────────────────────────────────

  @override
  void aimAtList(String listId) => draft.aimAtList(listId);

  @override
  void dismissPreview() => draft.keepAsText(text.text);

  @override
  void setDue(DateMove move) {
    // The coarse-pointer path arrives one frame AFTER its sheet popped
    // (quick_date_menu's post-frame invoke), so the host can be gone by then.
    if (!mounted) return;
    final moved = ymdForMove(move);
    if (moved == null) {
      // [DateMove.clear] drops the date AND silences a date phrase already
      // typed in the title, so "no date" means no date however the date got
      // there — exactly what the preview chip's × does.
      draft.keepAsText(text.text);
    } else {
      draft.pickDue(moved);
    }
  }

  @override
  Future<void> pickDue(BuildContext context) async {
    final pick = await showDueDatePicker(context, initial: previewDue);
    if (pick == null || !mounted) return;
    switch (pick) {
      case DuePickClear():
        draft.keepAsText(text.text);
      case DuePickDate(:final ymd):
        draft.pickDue(ymd);
    }
  }

  // ── creating ──────────────────────────────────────────────────────────────

  /// Commit the current draft as a task (never an empty one), pin it, and clear
  /// the field. Returns the created task, or null when there is nothing to
  /// create (empty draft, or no list to create in). Shared by the Enter/+
  /// submit and the app-backgrounded flush (#183).
  Future<StoredTask?> _createFromDraft() async {
    final title = text.text.trim();
    if (title.isEmpty) return null; // never create an empty task

    // Resolve the date from the current input BEFORE any await (the field is
    // only cleared after the create lands).
    final explicitDue = previewDue;
    final due =
        explicitDue ?? (_isSmartView ? quickAddDueFor(widget.viewId) : null);

    // Where it lands: the composer's picked list (#217) when the user aimed it
    // somewhere, else the view's default — a smart view imposes no target list,
    // so the first list wins (the default "My Tasks"); a concrete list view
    // targets itself.
    final target = targetListIn(_lists);
    if (target == null) return null; // no list to create in

    final stored = await ref
        .read(commandsProvider)
        .createTask(listId: target, title: title, due: due);
    if (!mounted) return stored;
    ref.read(newestTaskProvider.notifier).pin(stored.task.id);
    text.clear();
    // The title became a task; the AIM — the picked date and destination — is
    // what the user set for the adds that FOLLOW, and stays (#264).
    draft.titleConsumed();
    return stored;
  }

  /// The quick-add's entry in the pending-edits registry — commit the draft on
  /// the way to the background so a killed process never drops it (#183).
  void _flushDraft() {
    _createFromDraft();
  }

  @override
  Future<void> submit() async {
    final toasts = ref.read(toastControllerProvider);
    final created = await _createFromDraft();
    if (created == null || !mounted) return;
    // Landing feedback (#190): when the new task's date fails the current
    // view's filter it renders nowhere here — toast WHERE it actually went
    // (with a jump) rather than leaving a silent, invisible create.
    final dest = landingDestinationFor(
      viewId: widget.viewId,
      due: _bareDue(created.task.due),
      listId: created.listId,
      listTitle: _listTitle(created.listId),
      excludedLists: ref.read(prefsControllerProvider).excludedLists.toSet(),
      window: dateWindowNow(),
    );
    if (dest != null) {
      _landingToast(
        toasts,
        dest,
        subject: 'Added "${created.task.title}"',
        taskIds: [created.task.id],
      );
    }
    // Creating a task never opens the panel on its own; if it was already open,
    // follow it to the new task instead of leaving a stale one selected.
    if (widget.selectedTaskId != null) widget.onOpenTask?.call(created.task.id);
  }

  /// The created task's own due reduced to a bare `YYYY-MM-DD` so it compares
  /// against the smart-view window bounds (which are bare) — a fresh task has no
  /// subtasks, so its effective due is its own explicit date.
  static String? _bareDue(String? due) =>
      (due == null || due.length < 10) ? due : due.substring(0, 10);

  /// The title of the list with [listId], for the landing toast — falls back to
  /// the first known list (the lists set is never empty once a create landed).
  String _listTitle(String listId) {
    final lists = _lists;
    if (lists.isEmpty) return '';
    return lists
        .firstWhere((l) => l.list.id == listId, orElse: () => lists.first)
        .list
        .title;
  }

  /// The #190 landing toast: "`<subject>` to `<where>`" with a **View** jump to
  /// the view that actually shows the just-created task(s). Fired only when the
  /// current view hides the create — an in-view create stays toast-free.
  void _landingToast(
    ToastController toasts,
    LandingDestination dest, {
    required String subject,
    required List<String> taskIds,
  }) {
    final jump = widget.onOpenInView;
    final message = '$subject to ${dest.label}';
    if (jump == null || taskIds.isEmpty) {
      toasts.showInfo(message);
    } else {
      toasts.showAction(
        message,
        actionLabel: 'View',
        onAction: () => jump(dest.viewId, taskIds.first),
      );
    }
  }

  @override
  Future<void> addPastedLines(String raw) async {
    final target = targetListIn(_lists);
    if (target == null) return;
    text.clear();
    draft.titleConsumed();
    await _commitBulkAdd(
      BulkAddResult(text: raw, mode: BulkAddMode.perLine, listId: target),
    );
  }

  @override
  Future<void>? openBulkAdd(BuildContext context) {
    final target = defaultTargetIn(_lists);
    if (target == null) return null;
    return _openBulkAdd(context, target);
  }

  Future<void> _openBulkAdd(BuildContext context, String target) async {
    final result = await showBulkAddDialog(
      context,
      lists: _lists,
      defaultListId: target,
      initialText: '',
    );
    if (result == null || !mounted) return;
    await _commitBulkAdd(result);
  }

  /// Create the tasks a confirmed [result] describes and toast the count — the
  /// ONE bulk-split commit path, shared by the toolbar dialog and the
  /// composer's multi-line-paste offer (#219), so both create identically.
  ///
  /// Per-line mode reads each line's trailing natural-language date exactly as
  /// the quick-add bar does (title kept verbatim, only the due parsed), so a
  /// pasted "call bob tomorrow" lands dated instead of arriving unscheduled.
  Future<void> _commitBulkAdd(BulkAddResult result) async {
    final commands = ref.read(commandsProvider);
    final createdIds = <String>[];
    final dues = <String?>{};
    if (result.mode == BulkAddMode.titleNotes) {
      final all = result.text.split('\n');
      final title = all.first.trim();
      final notes = all.skip(1).join('\n').trim();
      if (title.isNotEmpty) {
        final task = await commands.createTask(
          listId: result.listId,
          title: title,
        );
        if (notes.isNotEmpty) await commands.setNotes(task.task.id, notes);
        createdIds.add(task.task.id);
        dues.add(null);
      }
    } else {
      for (final line in splitBulkLines(result.text)) {
        final due = parseQuickAddDue(line);
        final task = await commands.createTask(
          listId: result.listId,
          title: line,
          due: due,
        );
        createdIds.add(task.task.id);
        dues.add(due);
      }
    }
    if (!mounted || createdIds.isEmpty) return;
    final n = createdIds.length;
    final countPrefix = 'Added $n task${n == 1 ? '' : 's'}';
    // Where they went (#190): undated rows from a dated smart view land in
    // Unscheduled, invisible to the view that created them. A landing hint can
    // only name ONE place, so it is offered only when every new row shares a
    // date — mixed per-line dates scatter, and the honest feedback is then the
    // bare count.
    final dest = dues.length == 1
        ? landingDestinationFor(
            viewId: widget.viewId,
            due: dues.single,
            listId: result.listId,
            listTitle: _listTitle(result.listId),
            excludedLists: ref
                .read(prefsControllerProvider)
                .excludedLists
                .toSet(),
            window: dateWindowNow(),
          )
        : null;
    final toasts = ref.read(toastControllerProvider);
    if (dest == null) {
      toasts.showInfo(countPrefix);
    } else {
      _landingToast(toasts, dest, subject: countPrefix, taskIds: createdIds);
    }
  }

  @override
  Future<void> openSheet(BuildContext context) =>
      showComposerSheet(context, ref, this);

  @override
  Widget build(BuildContext context) {
    // ONE creation affordance per pointer class (#216): touch creates through
    // the FAB's bottom-sheet composer (thumb zone, IME pre-raised), so the
    // inline bar — which duplicated the FAB and cost a row of screen — mounts
    // on a fine pointer only. The FAB bumps [newTaskRequestProvider]; THIS
    // host — the one above the view switch — opens the sheet, so a tap during
    // a switch can never be answered twice.
    final touch = coarsePointerPlatform(Theme.of(context).platform);
    ref.listen(newTaskRequestProvider, (previous, next) {
      if (touch && next != previous) openSheet(context);
    });
    final scoped = ComposerScope(controller: this, child: widget.child);
    if (touch) return scoped;
    return Column(
      children: [
        ComposerBar(controller: this),
        const Divider(height: 1),
        Expanded(child: scoped),
      ],
    );
  }
}

/// The always-visible desktop composer bar, watching the LIVE list set so a
/// list arriving or vanishing under it is immediately offerable (#274).
class ComposerBar extends ConsumerWidget {
  const ComposerBar({required this.controller, super.key});

  final ComposerController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lists =
        ref.watch(listsProvider).asData?.value ?? const <StoredTaskList>[];
    final focus = ref.watch(quickAddFocusProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => QuickAddBar(
        controller: controller.text,
        focusNode: focus,
        dateIgnoredFor: controller.draft.dateIgnoredFor,
        pickedDue: controller.draft.pickedDue,
        lists: lists,
        targetListId: controller.targetListIn(lists),
        onTargetChanged: (id) {
          controller.aimAtList(id);
          // Aiming is a detour, not a destination: hand the caret straight back
          // so the next keystroke goes into the draft.
          focus.requestFocus();
        },
        onSubmit: controller.submit,
        onAddPastedLines: controller.addPastedLines,
        onDismissPreview: () {
          controller.dismissPreview();
          focus.requestFocus();
        },
        onSetDue: (move) {
          controller.setDue(move);
          // Setting a date is a detour, not a destination: the caret comes
          // straight back to the draft (the #217 rule).
          focus.requestFocus();
        },
        onPickDue: () async {
          await controller.pickDue(context);
          if (context.mounted) focus.requestFocus();
        },
      ),
    );
  }
}

/// The bottom padding the composer sheet keeps clear: the keyboard when it is
/// up (#166's IME contract), and the gesture pill when it is not.
double composerSheetInset(BuildContext context) => math.max(
  MediaQuery.viewInsetsOf(context).bottom,
  MediaQuery.paddingOf(context).bottom,
);

/// The clearance the list keeps below its last row for the floating FAB.
double get fabClearance => NewTaskFab.clearance;
