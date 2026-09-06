// The export sheet (#297) — the surface where the user decides WHAT leaves the
// app, and by which door.
//
// Every assertion here is about what the user ends up with: the document handed
// to the delivery (the bytes on their clipboard / in their share sheet / in the
// file), the live task count the sheet shows while they toggle options, and the
// confirmation they get afterwards. The failures these prevent:
//
//   • an option that renders but changes nothing in the exported document (the
//     classic "the checkbox is decorative" bug);
//   • a phone offering a Save dialog it cannot open, or a desktop offering a
//     share sheet it does not have — every affordance must do something real in
//     the pointer class it renders in;
//   • a cancelled save reporting success;
//   • an export mutating tasks (an export is READ-ONLY — nothing about it may
//     touch sync state).

import 'package:axiotask/src/app/export_delivery.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/app/task_export.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/export_sheet.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_commands.dart';
import 'toast_harness.dart' show wrapWithToast;

final _clock = Clock.fixed(DateTime.utc(2026, 6, 15, 12));

/// A delivery that records the documents it is handed instead of touching a
/// plugin channel, and answers whichever pair of capabilities the scenario is
/// about (a phone shares, a desktop saves).
class FakeDelivery extends ExportDelivery {
  FakeDelivery({
    bool share = false,
    bool save = true,
    this.savedPath = '/tmp/axiotask-groceries-20260615.md',
  }) : _canShare = share,
       _canSave = save;

  final bool _canShare;
  final bool _canSave;

  /// What [save] reports back — `null` stands for a dismissed dialog.
  final String? savedPath;

  final List<ExportDocument> shared = [];
  final List<ExportDocument> saved = [];
  final List<ExportDocument> copied = [];

  @override
  bool get canShare => _canShare;

  @override
  bool get canSave => _canSave;

  @override
  Future<void> share(ExportDocument doc) async => shared.add(doc);

  @override
  Future<String?> save(ExportDocument doc) async {
    saved.add(doc);
    return savedPath;
  }

  @override
  Future<void> copy(ExportDocument doc) async => copied.add(doc);
}

StoredTask _task(
  String id,
  String title, {
  String? due,
  String? notes,
  String? parent,
  bool completed = false,
}) => StoredTask(
  task: Task(
    id: id,
    parent: parent,
    position: '0000000000000$id',
    title: title,
    notes: notes,
    status: completed ? TaskStatus.completed : TaskStatus.needsAction,
    due: due,
    completed: completed ? '2026-06-14T10:00:00.000Z' : null,
    updated: '2026-06-01T00:00:00.000Z',
  ),
  listId: 'L1',
  syncState: SyncState.clean,
  localUpdated: '2026-06-01T00:00:00.000Z',
);

const _list = StoredTaskList(
  list: TaskList(id: 'L1', title: 'Groceries', updated: '2026-06-01T00:00:00Z'),
  syncState: SyncState.clean,
  localUpdated: '2026-06-01T00:00:00Z',
);

final _milk = _task(
  '1',
  'Buy milk',
  due: '2026-09-12T00:00:00.000Z',
  notes: 'Semi-skimmed',
);
final _bags = _task('2', 'Take the bags', parent: '1');
final _bob = _task('3', 'Call Bob', completed: true);
final _seed = [_milk, _bags, _bob];

/// Open the export sheet for list `L1` over [delivery], seeded with [tasks] —
/// through the REAL [showExportSheet], so the sheet is the modal route it is in
/// production (and closing it closes something).
Future<FakeCommands> pumpSheet(
  WidgetTester tester, {
  required FakeDelivery delivery,
  List<StoredTask>? tasks,
  TargetPlatform platform = TargetPlatform.android,
  double textScale = 1,
}) async {
  final fake = FakeCommands(tasks ?? _seed);
  addTearDown(fake.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(const Prefs()),
        commandsProvider.overrideWithValue(fake),
        allTasksProvider.overrideWith((ref) => fake.tasksStream),
        listsProvider.overrideWith((ref) => Stream.value(const [_list])),
        exportDeliveryProvider.overrideWithValue(delivery),
      ],
      child: MaterialApp(
        theme: ThemeData(platform: platform),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: wrapWithToast(context, child),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: const Key('open-export'),
              onPressed: () =>
                  showExportSheet(context, viewId: 'L1', title: 'Groceries'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tapAndSettle(tester, find.byKey(const Key('open-export')));
  return fake;
}

Future<void> tapAndSettle(WidgetTester tester, Finder f) async {
  await tester.tap(f);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// A widget test whose EVERY frame is built under the fixed clock — the due
/// labels in the exported document are read from it, and a build that escaped
/// the zone would date them against the wall clock.
void clockedTest(String name, Future<void> Function(WidgetTester) body) =>
    testWidgets(name, (tester) => withClock(_clock, () => body(tester)));

void main() {
  clockedTest('copies exactly what the checklist says it will', (tester) async {
    final delivery = FakeDelivery();
    await pumpSheet(tester, delivery: delivery);

    // The live summary is what the user reads before committing: two open
    // tasks (the completed one is out by default), and its subtask.
    expect(find.text('2 tasks'), findsOneWidget);

    await tapAndSettle(tester, find.byKey(const Key('export-copy')));

    expect(delivery.copied.single.text, '''
# Groceries

- [ ] Buy milk — Sep 12

  Semi-skimmed

  - [ ] Take the bags
''');
    expect(find.text('Copied 2 tasks to the clipboard'), findsOneWidget);
  });

  clockedTest('including completed tasks changes the count and the document', (
    tester,
  ) async {
    final delivery = FakeDelivery();
    await pumpSheet(tester, delivery: delivery);

    await tapAndSettle(
      tester,
      find.byKey(const Key('export-include-completed')),
    );

    expect(find.text('3 tasks'), findsOneWidget);

    await tapAndSettle(tester, find.byKey(const Key('export-copy')));

    expect(delivery.copied.single.text, contains('- [x] Call Bob'));
  });

  clockedTest('turning notes off drops them from the document', (tester) async {
    final delivery = FakeDelivery();
    await pumpSheet(tester, delivery: delivery);

    await tapAndSettle(tester, find.byKey(const Key('export-include-notes')));
    await tapAndSettle(tester, find.byKey(const Key('export-copy')));

    expect(delivery.copied.single.text, isNot(contains('Semi-skimmed')));
    expect(delivery.copied.single.text, contains('- [ ] Buy milk — Sep 12'));
  });

  clockedTest('turning subtasks off drops the nested rows', (tester) async {
    final delivery = FakeDelivery();
    await pumpSheet(tester, delivery: delivery);

    await tapAndSettle(
      tester,
      find.byKey(const Key('export-include-subtasks')),
    );

    expect(find.text('1 task'), findsOneWidget);

    await tapAndSettle(tester, find.byKey(const Key('export-copy')));

    expect(delivery.copied.single.text, isNot(contains('Take the bags')));
  });

  clockedTest('picking CSV exports the table, not the checklist', (
    tester,
  ) async {
    final delivery = FakeDelivery();
    await pumpSheet(tester, delivery: delivery);

    await tapAndSettle(tester, find.text('CSV'));
    await tapAndSettle(tester, find.byKey(const Key('export-copy')));

    final doc = delivery.copied.single;
    expect(
      doc.text,
      startsWith('title,list,due,status,completed_at,notes,parent_title\n'),
    );
    expect(doc.fileName, endsWith('.csv'));
  });

  clockedTest('a desktop saves the file and says where it went', (
    tester,
  ) async {
    final delivery = FakeDelivery();
    await pumpSheet(tester, delivery: delivery);

    expect(find.byKey(const Key('export-share')), findsNothing);

    await tapAndSettle(tester, find.byKey(const Key('export-save')));

    expect(delivery.saved.single.fileName, 'axiotask-groceries-20260615.md');
    expect(
      find.text('Saved 2 tasks to axiotask-groceries-20260615.md'),
      findsOneWidget,
    );
  });

  clockedTest(
    'a dismissed save dialog claims nothing and leaves the sheet up',
    (tester) async {
      final delivery = FakeDelivery(savedPath: null);
      await pumpSheet(tester, delivery: delivery);

      await tapAndSettle(tester, find.byKey(const Key('export-save')));

      expect(find.textContaining('Saved'), findsNothing);
      expect(find.byKey(const Key('export-save')), findsOneWidget);
    },
  );

  clockedTest('a phone shares instead of saving', (tester) async {
    final delivery = FakeDelivery(share: true, save: false);
    await pumpSheet(tester, delivery: delivery);

    expect(find.byKey(const Key('export-save')), findsNothing);

    await tapAndSettle(tester, find.byKey(const Key('export-share')));

    expect(delivery.shared.single.title, 'Groceries');
    expect(delivery.shared.single.text, contains('- [ ] Buy milk'));
  });

  clockedTest('an empty view exports an honest empty document', (tester) async {
    final delivery = FakeDelivery();
    await pumpSheet(tester, delivery: delivery, tasks: const []);

    expect(find.text('No tasks'), findsOneWidget);

    await tapAndSettle(tester, find.byKey(const Key('export-copy')));

    expect(delivery.copied.single.text, '''
# Groceries

_No tasks._
''');
  });

  // Touch and mouse are different surfaces, not the same one at two widths: a
  // full-width bottom sheet under a 1000dp desktop window is a phone control
  // that wandered onto a desktop (the app already splits the quick-date menu
  // exactly this way).
  clockedTest('a finger gets a bottom sheet', (tester) async {
    await pumpSheet(tester, delivery: FakeDelivery());

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
  });

  clockedTest('a mouse gets a dialog', (tester) async {
    await pumpSheet(
      tester,
      delivery: FakeDelivery(),
      platform: TargetPlatform.linux,
    );

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Export Groceries'), findsOneWidget);
  });

  // A phone with the system font at 2x is a real configuration, and the sheet
  // is mostly words: a Row of buttons would overflow (a red-and-yellow bar
  // where the actions should be).
  clockedTest('survives a 2.0x system font without overflowing', (
    tester,
  ) async {
    await pumpSheet(tester, delivery: FakeDelivery(), textScale: 2);

    expect(find.byKey(const Key('export-copy')), findsOneWidget);
    expect(find.text('Include completed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  clockedTest('Cancel closes the surface and exports nothing', (tester) async {
    final delivery = FakeDelivery();
    await pumpSheet(tester, delivery: delivery);

    await tapAndSettle(tester, find.byKey(const Key('export-cancel')));

    expect(find.byKey(const Key('export-copy')), findsNothing);
    expect(delivery.copied, isEmpty);
    expect(delivery.saved, isEmpty);
  });

  clockedTest('exporting never touches a task', (tester) async {
    final delivery = FakeDelivery();
    final fake = await pumpSheet(tester, delivery: delivery);
    final before = fake.tasks.map((t) => t.task).toList();

    await tapAndSettle(tester, find.byKey(const Key('export-copy')));

    expect(fake.tasks.map((t) => t.task).toList(), before);
    expect(fake.renamed, isEmpty);
    expect(fake.notesSet, isEmpty);
    expect(fake.setDueCalls, isEmpty);
    expect(fake.deleted, isEmpty);
    expect(fake.movedToList, isEmpty);
  });
}
