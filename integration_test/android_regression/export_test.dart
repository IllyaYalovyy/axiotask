// Export subset of the Android behavior manifest (manifest.json).
//
// Case 15 failed the 2026-11-15 native audit of v1.5.6: the collection
// actions offered no export, while v1.5.3 exported the displayed list or view
// as Markdown or CSV. This contract keeps the audit's assertion (an
// hit-testable Export entry in the collection actions) and then proves real
// output: it exports by touch through the production Android destination,
// whose bytes are written by MainActivity through `ContentResolver`, and
// reads each file back with independent Markdown and CSV parsers.
//
// The system "Save to" picker is another app's activity that a Flutter
// integration test cannot drive, so only the CHOICE of location is scripted:
// a file URI inside the isolated fixture directory, `null` for a dismissed
// picker, or a URI of a provider that does not exist for a destination error.
// Everything after the choice (the native write, the display name, the
// discard of a failed document) is the production path.
//
// It covers a list in manual order without completed tasks, the same list by
// title with completed tasks and subtasks shown, the All smart view across
// lists, and an empty list; then a cancelled and a failing destination. No
// export may change a stored task or create a publication intent.
// Run through tool/android_regression/runner.dart.
import 'dart:io';

import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/data/export/android_document_export_destination.dart';
import 'package:axiotask/src/data/export/file_view_export_destination.dart';
import 'package:axiotask/src/domain/export/view_export.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/smart_views.dart';
import 'package:axiotask/src/domain/repository/view_export_destination.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../test/support/export_parsers.dart';
import 'support/regression_harness.dart';

const _eggs = 'Eggs, "free range" 🥚';
const _markup = r'*Bold* [link](https://example.com) <b>|x|';
const _doneNotes = 'Line one, with comma\n"Quoted" Привет 你好\n# not a heading';

/// Google's stored completion instant of `Audit done top`.
final _doneTopCompletedAt = DateTime.utc(2026, 11, 14, 9, 15);

late _ScriptedDestination _destination;

void main() {
  ensureRegressionBinding();

  regressionCase(
    '15_export_action',
    phoneOnHost: true,
    seed: const RegressionSeed(
      extraTopLevelTitles: <String>[_eggs, _markup],
      completedChildTitles: <String>['Audit done child'],
    ),
    exportDestination: (directory) =>
        _destination = _ScriptedDestination(directory),
    (t, f) async {
      final cache = CacheDao(f.database);
      final doneTop = await cache.putTask(
        accountId: f.account,
        taskListId: f.list,
        remoteId: const TaskRemoteId('audit-done-top'),
        title: 'Audit done top',
        notes: _doneNotes,
        position: '9',
        status: TaskStatus.completed,
      );
      // Its last observed Google state carries the completion instant; the
      // completed subtask has none, as after a local, unpublished completion.
      await cache.putTaskRemoteBase(
        accountId: f.account,
        taskId: doneTop,
        taskListId: f.list,
        remoteId: const TaskRemoteId('audit-done-top'),
        observedPublicationId: 'regression-base',
        deleted: false,
        title: 'Audit done top',
        notes: _doneNotes,
        status: TaskStatus.completed,
        position: '9',
        completedAt: _doneTopCompletedAt,
        etag: 'regression-etag',
      );
      final empty = await cache.putTaskList(
        accountId: f.account,
        remoteId: const TaskListRemoteId('audit-empty'),
        title: 'Audit empty',
      );
      await settleUntil(
        t,
        () =>
            f.model.state.tasks.any(
              (task) =>
                  task.id == doneTop && task.completedAt == _doneTopCompletedAt,
            ) &&
            f.model.state.taskLists.any((list) => list.id == empty),
        description: 'the extra fixture rows to reach the view model',
      );
      final seeded = await f.tasks();

      // The audit's assertion: the collection actions offer an export.
      await t.tap(find.byKey(const Key('collection-actions-menu')));
      await t.pumpAndSettle();
      expect(
        find.textContaining('Export').hitTestable(),
        findsWidgets,
        reason: 'v1.5.3 exports the displayed list/view to Markdown or CSV',
      );
      expect(find.text('Export…').hitTestable(), findsOneWidget);
      await f.capture(t, 'menu');

      // v1.5.3 opened an export sheet with a preview and Copy, Save and
      // Share; nothing is written until one is chosen.
      await t.tap(find.byKey(const Key('collection-export')));
      await t.pumpAndSettle();
      expect(_destination.written, isEmpty);
      expect(find.byKey(const Key('export-preview')), findsOneWidget);
      expect(find.text('Markdown').hitTestable(), findsOneWidget);
      expect(find.text('CSV').hitTestable(), findsOneWidget);
      expect(
        find.byKey(const Key('export-copy')).hitTestable(),
        findsOneWidget,
      );
      await f.capture(t, 'sheet');

      // 1. The list as shown: manual order, completed hidden, as Markdown.
      _destination.answers.add(_Answer.save);
      await t.tap(find.byKey(const Key('export-save')));
      final listMarkdown = await _awaitExport(t, f);
      expect(listMarkdown.suggestedName, endsWith('.md'));
      expect(listMarkdown.suggestedName, startsWith('axiotask-audit-tasks-'));
      final markdown = parseMarkdownExport(listMarkdown.text);
      expect(markdown.heading, 'Audit tasks');
      expect(
        markdown.items.map(
          (item) => (item.depth, item.checked, item.title, item.dueLabel),
        ),
        <(int, bool, String, String?)>[
          (0, false, 'Audit parent', 'Nov 15'),
          (1, false, 'Audit child', 'Nov 14'),
          (0, false, 'Audit second task', null),
          (0, false, _eggs, null),
          (0, false, _markup, null),
        ],
        reason: 'the export is the displayed rows, in order, with subtasks',
      );
      expect(markdown.items.first.notes, <String>[
        'Audit notes https://example.com',
      ]);
      for (final absent in <String>[
        'Audit done',
        'Audit destination',
        'audit-parent',
        'regression-synthetic',
        'regression-etag',
      ]) {
        expect(listMarkdown.text, isNot(contains(absent)), reason: absent);
      }
      expect(
        find.text(
          'Exported 5 tasks as Markdown to ${listMarkdown.writtenName}.',
        ),
        findsOneWidget,
      );
      await f.capture(t, 'markdown_saved');

      // 2. The same list by title with completed shown, as CSV.
      await t.tap(find.byKey(const Key('collection-sort')));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(CheckedPopupMenuItem<ViewSort>, 'Title'));
      await settleUntil(
        t,
        () => f.model.state.selectedViewPreferences.sort == ViewSort.title,
        description: 'title sorting to be selected',
      );
      await t.tap(find.byKey(const Key('collection-actions-menu')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('collection-show-completed')));
      await t.pumpAndSettle();
      expect(find.text('Audit done top'), findsOneWidget);
      _destination.answers.add(_Answer.save);
      await _chooseExport(t, 'collection-export-csv');
      final listCsv = await _awaitExport(t, f);
      expect(listCsv.suggestedName, endsWith('.csv'));
      final records = parseCsv(listCsv.text);
      expect(records.first, viewExportCsvHeader);
      expect(
        records.skip(1).map((r) => (r[0], r[1], r[2], r[3], r[4], r[5], r[6])),
        <(String, String, String, String, String, String, String)>[
          (_markup, 'Audit tasks', '', 'needsAction', '', '', ''),
          (
            'Audit parent',
            'Audit tasks',
            '2026-11-15',
            'needsAction',
            '',
            'Audit notes https://example.com',
            '',
          ),
          (
            'Audit child',
            'Audit tasks',
            '2026-11-14',
            'needsAction',
            '',
            '',
            'Audit parent',
          ),
          (
            'Audit done child',
            'Audit tasks',
            '',
            'completed',
            '',
            '',
            'Audit parent',
          ),
          ('Audit second task', 'Audit tasks', '', 'needsAction', '', '', ''),
          (_eggs, 'Audit tasks', '', 'needsAction', '', '', ''),
          (
            'Audit done top',
            'Audit tasks',
            '',
            'completed',
            '2026-11-14T09:15:00.000Z',
            _doneNotes,
            '',
          ),
        ],
        reason: 'title order, open before completed, with completed shown',
      );
      expect(listCsv.text, isNot(contains('Audit destination')));

      // 3. The All smart view spans both lists and names each one.
      f.model.selectSmartView(SmartView.all);
      await t.pumpAndSettle();
      _destination.answers.add(_Answer.save);
      await _chooseExport(t, 'collection-export-csv');
      final allCsv = await _awaitExport(t, f);
      expect(allCsv.suggestedName, startsWith('axiotask-all-'));
      final allRows = parseCsv(allCsv.text).skip(1).toList();
      expect(
        allRows.map((r) => r[0]).toList(),
        f.model.state.visibleTasks
            .expand(
              (task) => <String>[
                task.title,
                for (final child in f.model.state.tasks)
                  if (child.parentTaskId == task.id &&
                      child.status == TaskStatus.needsAction)
                    child.title,
              ],
            )
            .toList(),
      );
      expect(
        allRows.singleWhere((r) => r[0] == 'Audit destination task')[1],
        'Audit destination',
      );
      expect(allRows.map((r) => r[0]), isNot(contains('Audit done top')));

      // 4. An empty list says so.
      f.model.selectTaskList(empty);
      await t.pumpAndSettle();
      _destination.answers.add(_Answer.save);
      await _chooseExport(t, 'collection-export-markdown');
      final emptyMarkdown = await _awaitExport(t, f);
      expect(emptyMarkdown.text, '# Audit empty\n\n_No tasks._\n');
      expect(
        find.text(
          'Exported 0 tasks as Markdown to ${emptyMarkdown.writtenName}.',
        ),
        findsOneWidget,
      );

      // 5. A dismissed picker writes nothing and says so.
      f.model.selectTaskList(f.list);
      await t.pumpAndSettle();
      final filesBefore = _destination.files();
      _destination.answers.add(_Answer.cancel);
      await _chooseExport(t, 'collection-export-csv');
      await settleUntil(
        t,
        () => find
            .text('Export canceled. No file was written.')
            .evaluate()
            .isNotEmpty,
        description: 'the cancellation feedback',
      );
      expect(_destination.files(), filesBefore);

      // 6. A destination that cannot be written reports an error.
      _destination.answers.add(_Answer.broken);
      await _chooseExport(t, 'collection-export-markdown');
      const failure =
          'The export could not be written to the chosen location. Your '
          'tasks are unchanged.';
      await settleUntil(
        t,
        () => find.text(failure).evaluate().isNotEmpty,
        description: 'the destination error feedback',
      );
      expect(_destination.files(), filesBefore);
      expect(f.model.state.isExportPending, isFalse);
      expect(find.text('Audit parent'), findsOneWidget);
      await f.capture(t, 'destination_error');
      expect(_destination.answers, isEmpty);

      // Exporting stored nothing.
      final after = await f.tasks();
      expect(
        after.map(_stored).toList(),
        seeded.map(_stored).toList(),
        reason: 'export never changes a task',
      );
      final desired = DesiredStateDao(f.database);
      for (final task in after) {
        expect(
          await desired.readTask(f.account, task.id),
          isNull,
          reason: '${task.title} gained a publication intent',
        );
      }
    },
  );
}

enum _Answer { save, cancel, broken }

final class _Written {
  const _Written(this.suggestedName, this.writtenName, this.text);

  final String suggestedName;
  final String writtenName;
  final String text;
}

/// Scripts only the location choice; the write is the production path.
final class _ScriptedDestination implements ViewExportDestination {
  _ScriptedDestination(Directory fixture)
    : exports = Directory('${fixture.path}/exports')..createSync() {
    _delegate = Platform.isAndroid
        ? AndroidDocumentExportDestination(
            picker: ({required suggestedName, required mimeType}) async =>
                _choose(suggestedName, android: true),
          )
        : FileViewExportDestination(
            picker: (document) async =>
                _choose(document.fileName, android: false),
          );
  }

  final Directory exports;
  final answers = <_Answer>[];
  final written = <_Written>[];
  late final ViewExportDestination _delegate;
  String? _pendingPath;
  String? _pendingSuggestion;
  var _count = 0;

  String? _choose(String suggestedName, {required bool android}) {
    final answer = answers.removeAt(0);
    switch (answer) {
      case _Answer.cancel:
        return null;
      case _Answer.broken:
        return android
            ? 'content://dev.axiotask.integrationtest.missing/document/1'
            : '${exports.path}/missing/out';
      case _Answer.save:
        _count += 1;
        final path = '${exports.path}/$_count-$suggestedName';
        _pendingPath = path;
        _pendingSuggestion = suggestedName;
        return android ? Uri.file(path).toString() : path;
    }
  }

  @override
  Future<ViewExportResult> save(ViewExportDocument document) async {
    final result = await _delegate.save(document);
    if (result case ViewExportSaved(:final displayName)) {
      // Read back what the platform wrote, not what was handed to it.
      written.add(
        _Written(
          _pendingSuggestion!,
          displayName,
          await File(_pendingPath!).readAsString(),
        ),
      );
    }
    return result;
  }

  List<String> files() =>
      exports.listSync(recursive: true).map((entry) => entry.path).toList()
        ..sort();
}

/// Opens the export sheet, picks the format named by [key] and saves.
Future<void> _chooseExport(WidgetTester t, String key) async {
  await t.tap(find.byKey(const Key('collection-actions-menu')));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('collection-export')));
  await t.pumpAndSettle();
  await t.tap(find.text(key.endsWith('csv') ? 'CSV' : 'Markdown'));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('export-save')));
}

/// Waits for the next written export and its confirmation.
Future<_Written> _awaitExport(WidgetTester t, RegressionFixture f) async {
  final count = _destination.written.length;
  await settleUntil(
    t,
    () =>
        _destination.written.length > count &&
        !f.model.state.isExportPending &&
        find.textContaining('Exported ').evaluate().isNotEmpty,
    description: 'the export to be written and confirmed',
  );
  return _destination.written.last;
}

String _stored(CachedTask task) =>
    '${task.id}|${task.taskListId}|${task.parentTaskId}|${task.title}|'
    '${task.notes}|${task.status}|${task.due}';
