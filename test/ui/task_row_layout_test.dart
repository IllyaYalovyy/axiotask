// The task row's MEASURED geometry (#276) — the layout pass that made a row
// read as one object instead of two floating lines.
//
// The user's complaint was proximity: the title sat ~16dp from its own meta
// line and ~24dp from the next row's title, so the meta line belonged to
// neither, and the checkbox — centred on the whole two-line row — sat in the
// gap between them, attached to nothing. Every assertion here is a distance
// the user perceives (or a rect the user can hit), taken from the rendered
// tree, so a future spacing/padding edit that re-opens the gap fails loudly
// instead of drifting.
//
// Determinism: the clock is pinned wherever a due LABEL is rendered (its text
// is derived from `clock.now()`), the platform is pinned per test (the touch
// and mouse rows follow the same rules but not the same tap boxes), and no
// animation is running at rest.

import 'package:axiotask/src/ui/task_row.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _clock = Clock.fixed(DateTime(2026, 6, 15, 12));

Future<void> _pumpRow(
  WidgetTester tester, {
  required TargetPlatform platform,
  String title = 'buy milk',
  String? due = '2026-06-10',
  String? listTag,
  String? notes,
  int subtaskDone = 0,
  int subtaskTotal = 0,
  List<String>? picked,
  Size size = const Size(400, 600),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: Scaffold(
          // Unbounded height, exactly as the list gives a row.
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: size.width,
                child: TaskRow(
                  title: title,
                  notes: notes,
                  completed: false,
                  due: due,
                  listTag: listTag,
                  subtaskDone: subtaskDone,
                  subtaskTotal: subtaskTotal,
                  onOpen: () {},
                  onToggle: () {},
                  onRename: (_) {},
                  onPickDate: picked == null ? null : () => picked.add(title),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
}

/// The rendered rect of the row's due LABEL — found through the segment rather
/// than by its text, which is a function of the (pinned) clock.
Rect _dueLabel(WidgetTester tester) => tester.getRect(
  find
      .descendant(
        of: find.byKey(const Key('row-due-segment')),
        matching: find.byType(Text),
      )
      .first,
);

void main() {
  for (final platform in [TargetPlatform.linux, TargetPlatform.android]) {
    final touch = platform == TargetPlatform.android;
    final name = touch ? 'touch' : 'mouse';

    group('row geometry — $name (#276)', () {
      testWidgets('a two-line row is 72dp tall at text scale 1.0', (
        tester,
      ) async {
        await withClock(_clock, () async {
          await _pumpRow(tester, platform: platform, picked: []);
        });
        expect(tester.getSize(find.byType(TaskRow)).height, 72);
      });

      testWidgets('the title sits 4dp above its own meta line', (tester) async {
        // Measured on the "no date" row: the label is a fixed string, so the
        // gap is asserted without a clock in the picture at all.
        await _pumpRow(tester, platform: platform, due: null, picked: []);
        final title = tester.getRect(find.text('buy milk'));
        final meta = tester.getRect(find.text('no date'));
        expect(meta.top - title.bottom, 4);
      });

      testWidgets('the checkbox is centred on the TITLE line', (tester) async {
        await withClock(_clock, () async {
          await _pumpRow(tester, platform: platform, picked: []);
        });
        final title = tester.getRect(find.text('buy milk'));
        final box = tester.getRect(
          find.byKey(const Key('row-checkbox-target')),
        );
        expect((box.center.dy - title.center.dy).abs(), lessThanOrEqualTo(1));
        // The enlarged hit area is untouched by the re-centring (#167).
        expect(box.height, greaterThanOrEqualTo(touch ? 48 : 28));
        expect(box.width, greaterThanOrEqualTo(touch ? 48 : 28));
      });

      testWidgets('the meta line starts at the title glyph', (tester) async {
        await withClock(_clock, () async {
          await _pumpRow(tester, platform: platform, picked: []);
        });
        final title = tester.getRect(find.text('buy milk'));
        final icon = tester.getRect(find.byIcon(Icons.event));
        expect((icon.left - title.left).abs(), lessThanOrEqualTo(1));
        // ...and the date label follows its icon, on the same line.
        final label = _dueLabel(tester);
        expect(label.left - icon.right, 4);
        expect((label.center.dy - icon.center.dy).abs(), lessThanOrEqualTo(1));
      });

      testWidgets('the date segment stays a comfortable tap target', (
        tester,
      ) async {
        final picked = <String>[];
        await withClock(_clock, () async {
          await _pumpRow(tester, platform: platform, picked: picked);
        });
        final segment = tester.getRect(
          find.byKey(const Key('row-due-segment')),
        );
        expect(segment.height, greaterThanOrEqualTo(touch ? 32 : 20));
        expect(segment.width, greaterThanOrEqualTo(touch ? 48 : 20));
        // A tap on the target's lower edge — below the date text itself —
        // still reaches the date, not the row body.
        await tester.tapAt(Offset(segment.center.dx, segment.bottom - 2));
        await tester.pump(const Duration(milliseconds: 350));
        expect(picked, ['buy milk']);
      });
    });

    group('list label — $name (#276)', () {
      testWidgets('a smart view renders it trailing on the title line', (
        tester,
      ) async {
        await withClock(_clock, () async {
          await _pumpRow(tester, platform: platform, listTag: 'My Tasks');
        });
        final row = tester.getRect(find.byType(TaskRow));
        final title = tester.getRect(find.text('buy milk'));
        final label = tester.getRect(find.text('My Tasks'));
        expect((label.center.dy - title.center.dy).abs(), lessThanOrEqualTo(1));
        // Trailing: hard against the row's own gutter, not floating mid-row.
        expect(row.right - label.right, lessThanOrEqualTo(9));
        // ...and it is a LABEL, not a control: no tap target of its own.
        expect(
          find.descendant(
            of: find.text('My Tasks'),
            matching: find.byType(GestureDetector),
          ),
          findsNothing,
        );
      });

      testWidgets('a long name ellipsises instead of pushing the title', (
        tester,
      ) async {
        await withClock(_clock, () async {
          await _pumpRow(
            tester,
            platform: platform,
            listTag: 'Quarterly planning and everything else that came with it',
          );
        });
        final row = tester.getRect(find.byType(TaskRow));
        final title = tester.getRect(find.text('buy milk'));
        final label = tester.getRect(find.byKey(const Key('list-tag')));
        expect(tester.takeException(), isNull);
        expect(label.width, lessThan(row.width * 0.45));
        expect(title.left, lessThan(label.left));
        expect(row.height, 72);
      });

      testWidgets('a concrete list leaves the trailing slot empty', (
        tester,
      ) async {
        await withClock(_clock, () async {
          await _pumpRow(tester, platform: platform, listTag: null);
        });
        expect(find.byKey(const Key('list-tag')), findsNothing);
        // The title keeps its place — the empty slot changes nothing else.
        expect(tester.getRect(find.text('buy milk')).left, 56);
        expect(tester.getSize(find.byType(TaskRow)).height, 72);
      });
    });
  }

  testWidgets('a busy row (notes + subtasks + label) still measures 72dp', (
    tester,
  ) async {
    await withClock(_clock, () async {
      await _pumpRow(
        tester,
        platform: TargetPlatform.android,
        notes: 'remember the receipt',
        subtaskDone: 2,
        subtaskTotal: 5,
        listTag: 'Groceries',
        picked: [],
      );
    });
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(TaskRow)).height, 72);
    // Every meta item stayed on the ONE meta line, below the title.
    final title = tester.getRect(find.text('buy milk'));
    for (final finder in [
      find.byIcon(Icons.notes),
      find.byIcon(Icons.event),
      find.text('2/5'),
    ]) {
      expect(tester.getRect(finder).top, greaterThanOrEqualTo(title.bottom));
    }
  });

  testWidgets('at 1.3x text scale the row grows instead of overflowing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(400, 600),
            textScaler: TextScaler.linear(1.3),
          ),
          child: Scaffold(
            body: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 400,
                  child: TaskRow(
                    title: 'buy milk',
                    completed: false,
                    listTag: 'My Tasks',
                    onOpen: () {},
                    onToggle: () {},
                    onRename: (_) {},
                    onPickDate: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(TaskRow)).height,
      greaterThanOrEqualTo(72),
    );
    // The label is still on the title line, still inside the row.
    final row = tester.getRect(find.byType(TaskRow));
    final label = tester.getRect(find.text('My Tasks'));
    expect(row.contains(label.topLeft), isTrue);
    expect(row.contains(label.bottomRight - const Offset(1, 1)), isTrue);
  });
}
