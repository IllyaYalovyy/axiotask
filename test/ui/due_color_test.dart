// #242 — one due-date urgency palette, spoken by every surface that shows a
// date. Protects three separate failures, all of them "the colour lies":
//
//   1. "today" and "overdue" reading as THE SAME colour. The old row mapped
//      today → `tertiary`, which the deepPurple seed generates as a rose that
//      sits ΔE ≈ 15 from `error` in the dark scheme — indistinguishable at a
//      glance, so an overdue task looked no more urgent than today's.
//   2. A date colour the user cannot READ on the surface behind it.
//   3. Three surfaces (row, Focus "Overdue (N)" heading, detail Due field)
//      inventing their own tone, so the same date means different things in
//      different places — the detail field used to carry no urgency colour at
//      all.
//
// The widget tests assert the colour that actually REACHES the glyph (the
// rendered RichText style), not that some helper was called.

import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/date_format.dart';
import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/color_metrics.dart';
import 'detail_harness.dart';

/// A fixed "today" every date fixture below is written against.
final _clock = Clock.fixed(DateTime(2026, 6, 15, 12));

/// The smallest ΔE the three urgency tones may sit apart. Far above the ~2.3
/// just-noticeable difference: these are 13px badges read in passing, and the
/// dark scheme's error/tertiary pair (ΔE 15) is exactly the failure this bars.
const _minSeparation = 25.0;

/// The colour that actually reaches the glyphs of [text] — the resolved style
/// on the rendered paragraph, so an inherited (DefaultTextStyle) colour counts
/// exactly like an explicit one.
Color _renderedColor(WidgetTester tester, String text) {
  final rich = tester.widget<RichText>(
    find.descendant(of: find.text(text), matching: find.byType(RichText)),
  );
  return rich.text.style!.color!;
}

Future<void> _pumpRow(
  WidgetTester tester, {
  required ThemeData theme,
  String? due,
}) async {
  await withClock(_clock, () async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.copyWith(platform: TargetPlatform.linux),
        home: Scaffold(
          body: TaskRow(
            title: 'buy milk',
            completed: false,
            due: due,
            onOpen: () {},
            onToggle: () {},
            onRename: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
  });
}

StoredTask _task(String id, String title, {String? due, String pos = '1'}) =>
    StoredTask(
      task: Task(
        id: id,
        position: pos,
        title: title,
        status: TaskStatus.needsAction,
        due: due == null ? null : '${due}T00:00:00.000Z',
        updated: 't',
      ),
      listId: 'L1',
      syncState: SyncState.clean,
      localUpdated: 't',
    );

void main() {
  final themes = {'light': buildLightTheme(), 'dark': buildDarkTheme()};

  group('the urgency palette', () {
    for (final entry in themes.entries) {
      final name = entry.key;
      final scheme = entry.value.colorScheme;

      test('$name: the three urgencies are three DIFFERENT colours', () {
        final overdue = dueColor(DueUrgency.overdue, scheme);
        final today = dueColor(DueUrgency.today, scheme);
        final muted = dueColor(DueUrgency.none, scheme);

        expect(
          perceptualDistance(today, overdue),
          greaterThanOrEqualTo(_minSeparation),
          reason:
              '$name: "due today" must not read as the alarm tone — '
              'attention, not alarm',
        );
        expect(
          perceptualDistance(muted, overdue),
          greaterThanOrEqualTo(_minSeparation),
          reason: '$name: a future/undated date must not read as overdue',
        );
        expect(
          perceptualDistance(muted, today),
          greaterThanOrEqualTo(_minSeparation),
          reason: '$name: "due today" must stand out from the muted default',
        );
      });

      test('$name: every urgency colour clears 4.5:1 on the surface', () {
        for (final urgency in DueUrgency.values) {
          expect(
            contrastRatio(dueColor(urgency, scheme), scheme.surface),
            greaterThanOrEqualTo(4.5),
            reason: '$name: $urgency is unreadable on the page',
          );
        }
      });
    }
  });

  group('the task row speaks it', () {
    for (final entry in themes.entries) {
      final name = entry.key;
      final theme = entry.value;
      final scheme = theme.colorScheme;

      testWidgets(
        '$name: overdue / today / future / none each get their tone',
        (tester) async {
          await _pumpRow(tester, theme: theme, due: '2026-06-10');
          final overdue = _renderedColor(tester, '5d overdue');
          expect(overdue, dueColor(DueUrgency.overdue, scheme));
          expect(
            tester.widget<Icon>(find.byIcon(Icons.event)).color,
            overdue,
            reason: 'the badge icon must carry the same tone as its label',
          );

          await _pumpRow(tester, theme: theme, due: '2026-06-15');
          final today = _renderedColor(tester, 'today');
          expect(today, dueColor(DueUrgency.today, scheme));

          await _pumpRow(tester, theme: theme, due: '2026-06-16');
          expect(
            _renderedColor(tester, 'tomorrow'),
            dueColor(DueUrgency.none, scheme),
            reason: 'nothing that is not overdue carries a warning tint',
          );

          // Non-happy path: no date at all — the muted default, never a tint.
          await _pumpRow(tester, theme: theme, due: null);
          expect(
            _renderedColor(tester, 'no date'),
            dueColor(DueUrgency.none, scheme),
          );

          expect(
            perceptualDistance(today, overdue),
            greaterThanOrEqualTo(_minSeparation),
            reason:
                '$name: a row due today must be tellable from an overdue row '
                'at a glance',
          );
        },
      );
    }
  });

  group('the Focus "Overdue (N)" heading speaks it', () {
    testWidgets('the heading wears the same tone as an overdue row', (
      tester,
    ) async {
      const myTasks = StoredTaskList(
        list: TaskList(id: 'L1', title: 'My Tasks', etag: 'e', updated: 't'),
        syncState: SyncState.clean,
        localUpdated: 't',
      );
      final theme = buildDarkTheme().copyWith(platform: TargetPlatform.linux);
      tester.view.physicalSize = const Size(900, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await withClock(_clock, () async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              allTasksProvider.overrideWith(
                (ref) => Stream.value([
                  _task('over1', 'Pay the invoice', due: '2026-06-10'),
                  _task('today', 'Stand-up notes', due: '2026-06-15', pos: '2'),
                ]),
              ),
              listsProvider.overrideWith(
                (ref) => Stream.value(const [myTasks]),
              ),
            ],
            child: MaterialApp(
              theme: theme,
              home: const Scaffold(
                body: TaskListView(
                  viewId: 'focus',
                  selectedTaskId: null,
                  onOpenTask: _noop,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
      });

      expect(find.byKey(const Key('overdue-heading')), findsOneWidget);
      expect(
        _renderedColor(tester, 'Overdue (1)'),
        dueColor(DueUrgency.overdue, theme.colorScheme),
      );
      expect(
        _renderedColor(tester, '5d overdue'),
        _renderedColor(tester, 'Overdue (1)'),
        reason: 'the heading and the rows it heads are one signal',
      );
    });
  });

  // Each case is its own pump: TaskDetail is stateful and tracks ONE task, so
  // re-pumping a second task into the same tree keeps the first one on screen.
  group('the detail panel\'s Due field speaks it', () {
    for (final entry in themes.entries) {
      final name = entry.key;
      final theme = entry.value;
      final scheme = theme.colorScheme;

      Future<void> pumpTask(WidgetTester tester, StoredTask task) => withClock(
        _clock,
        () async {
          await pumpDetail(tester, taskId: 't1', theme: theme, initial: [task]);
        },
      );

      testWidgets('$name: an overdue date wears the alarm tone', (
        tester,
      ) async {
        await pumpTask(tester, row('t1', 'Pay the invoice', due: '2026-06-10'));
        expect(
          _renderedColor(tester, '5d overdue'),
          dueColor(DueUrgency.overdue, scheme),
        );
      });

      testWidgets('$name: today wears the attention tone, not the alarm', (
        tester,
      ) async {
        await pumpTask(tester, row('t1', 'Stand-up notes', due: '2026-06-15'));
        final today = _renderedColor(tester, 'today');
        expect(today, dueColor(DueUrgency.today, scheme));
        expect(
          perceptualDistance(today, dueColor(DueUrgency.overdue, scheme)),
          greaterThanOrEqualTo(_minSeparation),
        );
      });

      // A subtask's inline date button is a DATE on the same panel: left on the
      // button default it would paint an OVERDUE subtask in the tone that now
      // means "due today".
      testWidgets('$name: a subtask\'s inline date carries its own urgency', (
        tester,
      ) async {
        await withClock(_clock, () async {
          await pumpDetail(
            tester,
            taskId: 't1',
            theme: theme,
            initial: [
              row('t1', 'Plan the offsite', due: '2026-06-15'),
              row('c1', 'Book a venue', parent: 't1', due: '2026-06-10'),
              row('c2', 'Send invites', parent: 't1', position: '2'),
            ],
          );
        });
        expect(
          _renderedColor(tester, '5d overdue'),
          dueColor(DueUrgency.overdue, scheme),
        );
        expect(
          _renderedColor(tester, 'no date'),
          dueColor(DueUrgency.none, scheme),
        );
      });

      // The overdue emphasis adds WEIGHT as well as colour, so it must still
      // fit where the panel is narrowest and the type largest — a bold
      // "Mar 10, 2027" that overflows its button is a broken screen, not a
      // signal (phone width, 1.3x text scale).
      testWidgets('$name: the overdue emphasis survives a narrow 1.3x panel', (
        tester,
      ) async {
        await withClock(_clock, () async {
          await pumpDetail(
            tester,
            taskId: 't1',
            theme: theme,
            size: const Size(360, 1600),
            textScale: 1.3,
            initial: [row('t1', 'Renew the domain', due: '2025-03-10')],
          );
        });
        expect(tester.takeException(), isNull);
        expect(find.text('462d overdue'), findsOneWidget);
        expect(
          _renderedColor(tester, '462d overdue'),
          dueColor(DueUrgency.overdue, scheme),
        );
      });

      // Non-happy path: an undated task — muted, and still an offered button.
      testWidgets(
        '$name: "No date" is muted and still the pick-a-date button',
        (tester) async {
          await pumpTask(tester, row('t1', 'Someday'));
          expect(
            _renderedColor(tester, 'No date'),
            dueColor(DueUrgency.none, scheme),
          );
          expect(
            tester
                .widget<OutlinedButton>(find.byKey(const Key('due-field')))
                .enabled,
            isTrue,
            reason: 'a muted "No date" must still open the calendar',
          );
        },
      );
    }
  });
}

void _noop(String _) {}
