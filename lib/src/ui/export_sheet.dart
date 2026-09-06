// The export sheet (#297) — one surface, reached from the list's ⋮ and from the
// view's ⋮, where the user picks a format, decides what goes in, and sends the
// result out of the app.
//
// The SCOPE is not a control here: the entry point already said what is being
// exported (a list from the sidebar, the current view from the app bar), and
// the sheet names it in its heading. Asking again would be a second question
// with one obvious answer — the opposite of "every useful option within one or
// two interactions".
//
// The rows are derived with the SAME [visibleTasksForView] the list renders
// with, so an export is what the user is looking at, in the order they are
// looking at it — except for completed tasks, which follow the sheet's own
// switch rather than the app-wide show-completed pref: "include what is done"
// is a property of the document, not of the screen.
//
// Which button appears is decided by the DELIVERY, not by the width: a phone
// has no filesystem to save into and a Linux desktop has no share sheet, and a
// button that cannot do its job must not render (touch has no hover, and no
// second chance to discover why nothing happened).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../app/export_delivery.dart';
import '../app/prefs_controller.dart';
import '../app/providers.dart';
import '../app/task_export.dart';
import '../model/task_view.dart';
import '../store/stored.dart';
import 'theme.dart' show coarsePointerPlatform;
import 'toast.dart';
import 'user_message.dart';

/// Open the export surface for [viewId], named [title] (the list or view
/// label), in the presentation the POINTER calls for — the same split the
/// quick-date menu already makes: a bottom sheet under the thumb on touch, a
/// centred dialog beside the pointer on a desktop, where a full-width sheet
/// pinned to the bottom edge of a 1000dp window is a phone control that
/// wandered onto the wrong machine.
///
/// The sheet goes on the ROOT navigator (#234): pushed on the shell's nested
/// one it would render under the FAB and the navigation bar.
Future<void> showExportSheet(
  BuildContext context, {
  required String viewId,
  required String title,
}) {
  final body = ExportSheet(viewId: viewId, title: title);
  if (!coarsePointerPlatform(Theme.of(context).platform)) {
    return showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          // Wide enough for the two format segments side by side, narrow
          // enough that the switches' labels stay next to their switches.
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(padding: const EdgeInsets.only(top: 24), child: body),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => body,
  );
}

/// The sheet's body: format, options, live count, and the ways out.
class ExportSheet extends ConsumerStatefulWidget {
  const ExportSheet({required this.viewId, required this.title, super.key});

  /// The view (or list) being exported.
  final String viewId;

  /// Its human name — the heading, the share subject, the file stem.
  final String title;

  @override
  ConsumerState<ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends ConsumerState<ExportSheet> {
  ExportOptions _options = const ExportOptions();

  /// A delivery in flight (a save dialog is up, a share sheet is opening). The
  /// buttons go dead meanwhile so a double tap cannot open two dialogs.
  bool _busy = false;

  /// The document as the current options would produce it — rebuilt with the
  /// sheet, so the count the user reads is the count they will get.
  ExportDocument _document() {
    final all =
        ref.watch(allTasksProvider).asData?.value ?? const <StoredTask>[];
    final lists =
        ref.watch(listsProvider).asData?.value ?? const <StoredTaskList>[];
    final prefs = ref.watch(prefsControllerProvider);
    return buildExport(
      title: widget.title,
      topLevel: visibleTasksForView(
        allTasks: all,
        viewId: widget.viewId,
        excludedLists: prefs.excludedLists.toSet(),
        // The sheet's own switch decides this, not the screen's toggle.
        showCompleted: _options.includeCompleted,
        sort: SortMode.byId(prefs.sortPerView[widget.viewId]),
        window: dateWindowNow(),
      ),
      allTasks: all,
      listTitles: {for (final l in lists) l.list.id: l.list.title},
      options: _options,
    );
  }

  /// "3 tasks" / "1 task" / "No tasks" — the same phrase in the sheet and in
  /// the confirmation, so the number the user agreed to is the number reported.
  String _countPhrase(int n) => switch (n) {
    0 => 'No tasks',
    1 => '1 task',
    _ => '$n tasks',
  };

  /// Run [op] with the buttons held, reporting any failure as one calm toast.
  ///
  /// [op] answers `(delivered, confirmation)`: `delivered` false leaves the
  /// sheet exactly as it was (a dismissed save dialog — the user is still
  /// deciding), and a null confirmation means the platform surface speaks for
  /// itself (the share sheet is already in front of them).
  Future<void> _deliver(Future<(bool, String?)> Function() op) async {
    if (_busy) return;
    setState(() => _busy = true);
    final toasts = ref.read(toastControllerProvider);
    (bool, String?) result;
    try {
      result = await op();
    } catch (e) {
      toasts.showError(commandUserMessage('export_tasks', e));
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final (delivered, confirmation) = result;
    if (!delivered) return;
    if (confirmation != null) toasts.showInfo(confirmation);
    // The job is done; the sheet has nothing left to say.
    await Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final delivery = ref.watch(exportDeliveryProvider);
    final doc = _document();
    final count = _countPhrase(doc.taskCount);

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Export ${widget.title}',
                style: theme.textTheme.titleLarge,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                count,
                key: const Key('export-count'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              // Two formats, both visible: a segmented control says what the
              // alternative IS, where a dropdown would hide it behind a tap.
              SegmentedButton<ExportFormat>(
                key: const Key('export-format'),
                segments: [
                  for (final f in ExportFormat.values)
                    ButtonSegment<ExportFormat>(
                      value: f,
                      label: Text(f.label),
                      icon: Icon(
                        f == ExportFormat.markdown
                            ? Icons.checklist
                            : Icons.table_chart_outlined,
                      ),
                    ),
                ],
                selected: {_options.format},
                onSelectionChanged: (s) => setState(
                  () => _options = _options.copyWith(format: s.first),
                ),
              ),
              const SizedBox(height: 8),
              _option(
                'export-include-completed',
                'Include completed',
                _options.includeCompleted,
                (v) => _options = _options.copyWith(includeCompleted: v),
              ),
              _option(
                'export-include-notes',
                'Include notes',
                _options.includeNotes,
                (v) => _options = _options.copyWith(includeNotes: v),
              ),
              _option(
                'export-include-subtasks',
                'Include subtasks',
                _options.includeSubtasks,
                (v) => _options = _options.copyWith(includeSubtasks: v),
              ),
              const SizedBox(height: 16),
              // Wrap, not Row: at a large text scale the labels grow past one
              // line's worth of width and must flow rather than overflow.
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  // An explicit way out. The sheet can be swiped down and the
                  // dialog takes Esc, but neither is visible, and a dialog
                  // whose only exit is a keystroke strands a mouse.
                  TextButton(
                    key: const Key('export-cancel'),
                    onPressed: _busy
                        ? null
                        : () => Navigator.of(context).maybePop(),
                    child: const Text('Cancel'),
                  ),
                  TextButton.icon(
                    key: const Key('export-copy'),
                    onPressed: _busy ? null : () => _deliver(() => _copy(doc)),
                    icon: const Icon(Icons.copy_all_outlined),
                    label: const Text('Copy'),
                  ),
                  if (delivery.canSave)
                    FilledButton.icon(
                      key: const Key('export-save'),
                      onPressed: _busy
                          ? null
                          : () => _deliver(() => _save(doc)),
                      icon: const Icon(Icons.save_alt),
                      label: const Text('Save…'),
                    ),
                  if (delivery.canShare)
                    FilledButton.icon(
                      key: const Key('export-share'),
                      onPressed: _busy
                          ? null
                          : () => _deliver(() => _share(doc)),
                      icon: const Icon(Icons.share_outlined),
                      label: const Text('Share…'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<(bool, String?)> _copy(ExportDocument doc) async {
    await ref.read(exportDeliveryProvider).copy(doc);
    return (
      true,
      'Copied ${_countPhrase(doc.taskCount).toLowerCase()} '
          'to the clipboard',
    );
  }

  Future<(bool, String?)> _save(ExportDocument doc) async {
    final path = await ref.read(exportDeliveryProvider).save(doc);
    // Dismissed dialog: nothing was written, so nothing is claimed.
    if (path == null) return (false, null);
    return (
      true,
      'Saved ${_countPhrase(doc.taskCount).toLowerCase()} '
          'to ${p.basename(path)}',
    );
  }

  Future<(bool, String?)> _share(ExportDocument doc) async {
    await ref.read(exportDeliveryProvider).share(doc);
    // The system sheet is the feedback; a toast behind it would be noise.
    return (true, null);
  }

  /// One switch row. The whole row toggles — a coarse pointer gets the full
  /// width, not just the thumb.
  Widget _option(
    String key,
    String label,
    bool value,
    ExportOptions Function(bool) apply,
  ) => SwitchListTile(
    key: Key(key),
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    value: value,
    onChanged: (v) => setState(() => _options = apply(v)),
  );
}
