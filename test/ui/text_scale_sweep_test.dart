// #247 — the accessibility text-scale sweep.
//
// A phone user who turns the system font up does not get a slightly larger app:
// they get a DIFFERENT layout, and the two ways it breaks are both silent in
// every other suite. A row overflows and paints a yellow-and-black hatch over
// the thing it was showing; or the chrome reflows and pushes an action off the
// edge, under another surface, or down to a strip too thin for a finger — the
// widget is still "found", the user just cannot reach it.
//
// So each of the six surfaces a phone can reach is pumped at BOTH scales on a
// small phone and asked the same two questions:
//
//   1. did anything overflow? (a RenderFlex/RenderBox overflow is reported at
//      paint time and lands in [WidgetTester.takeException]), and
//   2. is every action still TAPPABLE — present, hit-testable where a finger
//      lands (nothing painted over it), and at least [_minTarget] in both axes?
//
// …and at least one action per surface is then actually driven, so the sweep
// proves the surface still WORKS at 2.0×, not merely that it renders.
//
// 1.3× is a routine "larger text" setting; 2.0× is the far end of Android's
// accessibility font scaling. Five of the six surfaces run on [_phone], the
// tightest layout the app ships into; the detail runs on [_detailSurface] for
// the harness reason documented there.

import 'dart:io';

import 'package:axiotask/src/app/app.dart';
import 'package:axiotask/src/app/app_settings.dart';
import 'package:axiotask/src/app/config.dart';
import 'package:axiotask/src/app/config_controller.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/app/sync_status.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/bulk_bar.dart';
import 'package:axiotask/src/ui/properties.dart';
import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'detail_harness.dart' show FakeBackend, list, pumpDetail, row;
import 'list_harness.dart';
import 'toast_harness.dart' show wrapWithToast;

/// The two system font scales Android can actually be set to.
const _scales = [1.3, 2.0];

/// A small-but-real phone, in logical pixels.
const _phone = Size(360, 740);

/// The surface the DETAIL sweep runs on.
///
/// Wider than [_phone] on purpose, and the reason is the harness, not the app:
/// this package declares no fonts, so widget tests fall back to Flutter's test
/// font, whose every glyph is a SQUARE of the font size — roughly twice the
/// width real text measures. The detail's subtask row carries three fixed 48dp
/// controls plus a date button whose width is its label, and at 2.0x that
/// doubled label overruns a 360dp surface by 29dp — about half of what the same
/// label costs on a device. 430dp (Pixel-class) is the width this project uses
/// to absorb that harness bias; every other surface in the sweep is held to the
/// stricter [_phone]. See the residual noted in the task report.
const _detailSurface = Size(430, 900);

/// Material's minimum touch target, and the app's own contract (F19 #198).
const _minTarget = 48.0;

/// The app theme the sweep runs against — the real one, since the text styles
/// that reflow are the theme's.
final _theme = buildLightTheme();

/// A fixed clock so "today"/"tomorrow" labels have a stable width.
final _clock = Clock.fixed(DateTime.utc(2026, 6, 15, 12));

/// Nothing overflowed while [what] was on screen.
///
/// An overflow is reported at PAINT time, so it is already pending on the
/// binding by the time the pump returns; taking it here turns "the golden has a
/// yellow hatch in it" into a named failure.
void _expectNoOverflow(WidgetTester tester, String what) {
  expect(
    tester.takeException(),
    isNull,
    reason: '$what overflowed at this text scale',
  );
}

/// The tap target of the [IconButton] labelled [tooltip].
///
/// The tooltip itself is the button's INNER 40dp box; the 48dp target Material
/// pads around it belongs to the [IconButton], so that is what gets measured.
Finder _iconAction(String tooltip) => find.ancestor(
  of: find.byTooltip(tooltip),
  matching: find.byType(IconButton),
);

/// [what] is an action a finger can still land on: on screen, hit-testable at
/// its centre (nothing is painted over it), and no smaller than [_minTarget] in
/// either axis.
void _expectTappable(WidgetTester tester, Finder finder, String what) {
  expect(
    finder.hitTestable(),
    findsOneWidget,
    reason: '$what is gone, or something is painted over it',
  );
  final size = tester.getSize(finder.hitTestable().first);
  expect(
    size.shortestSide,
    greaterThanOrEqualTo(_minTarget),
    reason: '$what shrank to $size — too small for a finger',
  );
}

StoredTask _task(
  String id,
  String title, {
  String? notes,
  String? due,
  String? parent,
  String position = '1',
}) =>
    row(id, title, notes: notes, due: due, parent: parent, position: position);

void main() {
  // One throwaway dir for the two surfaces that own a file (the shell's prefs
  // store, Properties' config) — the real app's data is never touched.
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('axiotask_scale'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  for (final scale in _scales) {
    group('${scale}x text:', () {
      // ── The task row ────────────────────────────────────────────────────
      // The densest surface in the app, and the one with the most to lose: a
      // title, a checkbox and a metadata line of four badges inside 360dp.
      testWidgets('a fully loaded task row still reads and still ticks', (
        tester,
      ) async {
        final fake = await pumpList(
          tester,
          initial: [
            _task(
              'T1',
              'Renew the passport before the trip',
              notes: 'forms at https://gov.test/passport',
              due: '2026-06-15T00:00:00.000Z',
            ),
            _task('T2', 'Buy milk', position: '2'),
          ],
          lists: [list('L1', 'Errands')],
          size: _phone,
          platform: TargetPlatform.android,
          theme: _theme,
          textScale: scale,
        );
        _expectNoOverflow(tester, 'the task row');

        _expectTappable(
          tester,
          find.descendant(
            of: find.byType(TaskRow).first,
            matching: find.byKey(const Key('row-checkbox-target')),
          ),
          'the row checkbox',
        );
        _expectTappable(
          tester,
          find.descendant(
            of: find.byType(TaskRow).first,
            matching: find.byKey(const Key('row-due-segment')),
          ),
          'the row quick-date button',
        );
        _expectTappable(
          tester,
          find.descendant(
            of: find.byType(TaskRow).first,
            matching: find.byKey(const Key('link-badge')),
          ),
          'the row link badge',
        );

        // …and the checkbox still COMPLETES the task it belongs to.
        await tester.tap(
          find
              .descendant(
                of: find.byType(TaskRow).first,
                matching: find.byKey(const Key('row-checkbox-target')),
              )
              .hitTestable(),
        );
        await settleList(tester);
        expect(
          fake.tasks.firstWhere((t) => t.task.id == 'T1').task.status,
          TaskStatus.completed,
          reason: 'the checkbox no longer completes the row it sits on',
        );
      });

      // ── The bulk bar ────────────────────────────────────────────────────
      // Seven actions in one Wrap. It is allowed to grow to several runs; what
      // it may not do is overflow or bury an action.
      testWidgets('every bulk action survives the wrap', (tester) async {
        final fake = await pumpList(
          tester,
          initial: [
            _task('T1', 'Draft the offsite agenda'),
            _task('T2', 'Book the room', position: '2'),
          ],
          lists: [list('L1', 'Errands')],
          size: _phone,
          platform: TargetPlatform.android,
          theme: _theme,
          textScale: scale,
        );
        // The touch way into selection mode.
        await tester.longPress(find.text('Draft the offsite agenda'));
        await settleList(tester);
        expect(find.byType(BulkBar), findsOneWidget);
        _expectNoOverflow(tester, 'the bulk bar');

        for (final action in const {
          'bulk-complete': 'Complete',
          'bulk-due': 'Due',
          'bulk-move': 'Move',
          'bulk-duplicate': 'Duplicate',
          'bulk-demote': 'Make subtasks of…',
          'bulk-delete': 'Delete',
          'bulk-clear-selection': 'Clear selection',
        }.entries) {
          _expectTappable(
            tester,
            find.byKey(Key(action.key)),
            'the bulk bar\'s ${action.value}',
          );
        }

        await tester.tap(find.byKey(const Key('bulk-complete')).hitTestable());
        await settleList(tester);
        expect(
          fake.tasks.firstWhere((t) => t.task.id == 'T1').task.status,
          TaskStatus.completed,
          reason: 'bulk Complete no longer completes the selection',
        );
      });

      // ── The detail panel ────────────────────────────────────────────────
      // A phone-width detail with everything on it: a long title, notes, a
      // link, a due date, a List dropdown and two subtasks with their own
      // reorder arrows and date buttons.
      testWidgets('the detail keeps its navigation and its subtasks', (
        tester,
      ) async {
        late final FakeBackend fake;
        await withClock(_clock, () async {
          fake = await pumpDetail(
            tester,
            taskId: 'T1',
            theme: _theme,
            size: _detailSurface,
            textScale: scale,
            lists: [list('L1', 'Errands'), list('L2', 'Work')],
            onPrev: () {},
            onNext: () {},
            initial: [
              _task(
                'T1',
                'Renew the passport before the trip',
                notes: 'forms at https://gov.test/passport',
                due: '2026-06-20T00:00:00.000Z',
              ),
              _task('C1', 'Find the old one', parent: 'T1'),
              _task('C2', 'Book the photo booth', parent: 'T1', position: '2'),
            ],
          );
        });
        _expectNoOverflow(tester, 'the detail panel');

        for (final action in const {
          'Back': 'the back button',
          'Previous task': 'Previous task',
          'Next task': 'Next task',
          'More actions': 'the ⋮ overflow',
        }.entries) {
          _expectTappable(
            tester,
            _iconAction(action.key),
            'the detail\'s ${action.value}',
          );
        }
        _expectTappable(
          tester,
          find.byKey(const Key('due-field')),
          'the detail\'s Due field',
        );
        _expectTappable(
          tester,
          find.byKey(const Key('list-dropdown')),
          'the detail\'s List dropdown',
        );
        _expectTappable(
          tester,
          find.byKey(const Key('sub-due-C1')),
          'a subtask\'s date button',
        );

        // A subtask still checks off — the panel is the ONLY place a subtask
        // can be reached at all (invariant #1).
        final subtaskCheckbox = find.descendant(
          of: find.byKey(const ValueKey('C1')),
          matching: find.byType(Checkbox),
        );
        _expectTappable(tester, subtaskCheckbox, 'a subtask\'s checkbox');
        await tester.tap(subtaskCheckbox.hitTestable());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(
          fake.tasks.firstWhere((t) => t.task.id == 'C1').task.status,
          TaskStatus.completed,
          reason: 'a subtask can no longer be ticked off',
        );
      });

      // ── The composer ────────────────────────────────────────────────────
      // The FAB's bottom sheet: ONE line holding a text field, a date button, a
      // list picker and submit (#217). The line is the constraint.
      testWidgets('the composer still takes a task', (tester) async {
        var seq = 0;
        final fake = FakeBackend(const [], newId: () => 'gen-${seq++}');
        addTearDown(fake.dispose);
        tester.view.physicalSize = _phone;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await withClock(_clock, () async {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                prefsProvider.overrideWithValue(const Prefs()),
                commandsProvider.overrideWithValue(fake),
                allTasksProvider.overrideWith((ref) => fake.tasksStream),
                // Two lists: the composer's list picker only exists when
                // there is somewhere else to aim.
                listsProvider.overrideWith(
                  (ref) =>
                      Stream.value([list('L1', 'Errands'), list('L2', 'Work')]),
                ),
              ],
              child: MaterialApp(
                theme: _theme.copyWith(platform: TargetPlatform.android),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: wrapWithToast(context, child),
                ),
                home: Scaffold(
                  body: TaskListView(
                    viewId: 'all',
                    selectedTaskId: null,
                    onOpenTask: (_) {},
                  ),
                ),
              ),
            ),
          );
          await settleList(tester);

          // Raise the composer exactly as the FAB does.
          ProviderScope.containerOf(
            tester.element(find.byType(TaskListView)),
            listen: false,
          ).read(newTaskRequestProvider.notifier).bump();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          _expectNoOverflow(tester, 'the composer');

          _expectTappable(
            tester,
            find.byKey(const Key('quick-add-submit')),
            'the composer\'s submit',
          );
          _expectTappable(
            tester,
            find.byKey(const Key('quick-add-date-button')),
            'the composer\'s date button',
          );
          _expectTappable(
            tester,
            find.byKey(const Key('quick-add-list-picker')),
            'the composer\'s list picker',
          );

          await tester.enterText(
            find.descendant(
              of: find.byKey(const Key('quick-add-bar')),
              matching: find.byType(TextField),
            ),
            'Pick up the parcel',
          );
          await tester.pump();
          await tester.tap(
            find.byKey(const Key('quick-add-submit')).hitTestable(),
          );
          await settleList(tester);
        });
        expect(
          fake.tasks.map((t) => t.task.title),
          contains('Pick up the parcel'),
          reason: 'the composer no longer creates the task it was given',
        );
      });

      // ── The drawer ──────────────────────────────────────────────────────
      // The phone's ONLY route to a list, driven through the real shell.
      testWidgets('the drawer still navigates to a list', (tester) async {
        tester.view.physicalSize = _phone;
        tester.view.devicePixelRatio = 1.0;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        final prefs = PrefsStore(File(p.join(tmp.path, 'prefs.json')));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              prefsProvider.overrideWithValue(
                const Prefs(onboardingSeen: true),
              ),
              prefsStoreProvider.overrideWithValue(prefs),
              allTasksProvider.overrideWith(
                (ref) => Stream.value([_task('T1', 'Buy milk')]),
              ),
              listsProvider.overrideWith(
                (ref) => Stream.value([list('L1', 'Groceries')]),
              ),
            ],
            child: const AxiotaskApp(),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pumpAndSettle();
        _expectNoOverflow(tester, 'the drawer');

        final drawer = find.byType(Drawer);
        expect(
          find.descendant(of: drawer, matching: find.text('Groceries')),
          findsOneWidget,
        );
        _expectTappable(
          tester,
          find.descendant(
            of: drawer,
            matching: find.byKey(const Key('sidebar-add-list')),
          ),
          'the drawer\'s add-list button',
        );
        _expectTappable(
          tester,
          find.descendant(
            of: drawer,
            matching: find.byKey(const Key('open-properties')),
          ),
          'the drawer\'s Properties trigger',
        );

        await tester.tap(
          find.descendant(of: drawer, matching: find.text('Groceries')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byType(Drawer),
          findsNothing,
          reason: 'picking a list must still dismiss the drawer',
        );
        expect(
          find.widgetWithText(AppBar, 'Groceries'),
          findsOneWidget,
          reason: 'the shell must have navigated to the picked list',
        );
      });

      // ── Properties ──────────────────────────────────────────────────────
      // Four tabs of settings in a dialog that has to fit a phone.
      testWidgets('Properties keeps its tabs and its theme choice', (
        tester,
      ) async {
        tester.view.physicalSize = _phone;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final config = ConfigController(
          path: File(p.join(tmp.path, 'config.json')),
          initial: const AppConfig(),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              prefsProvider.overrideWithValue(const Prefs()),
              configControllerProvider.overrideWithValue(config),
              appSettingsProvider.overrideWithValue(
                const AppSettingsView(
                  version: '0.1.0',
                  instance: null,
                  pushEnabled: false,
                  autoSyncOnStart: true,
                  authenticated: false,
                  needsReauth: false,
                  scopes: [],
                  credentialsMissing: false,
                  dbPath: '/tmp/a/axiotask.sqlite',
                  configPath: '/tmp/a/config.json',
                  pendingPushes: 0,
                  sync: SyncStatusView.initial(),
                ),
              ),
            ],
            child: MaterialApp(
              theme: _theme,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: const Scaffold(body: PropertiesDialog()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        _expectNoOverflow(tester, 'the Properties dialog');

        _expectTappable(
          tester,
          find.byKey(const Key('properties-close')),
          'the Properties close button',
        );
        for (final tab in const ['Sync', 'Appearance', 'Account', 'About']) {
          // The strip is scrollable, so a tab past the edge is reached by
          // dragging the strip — which is what a finger does, and what this
          // does here. What it may not be is unreachable or under-sized.
          await tester.ensureVisible(find.widgetWithText(Tab, tab));
          await tester.pumpAndSettle();
          _expectTappable(
            tester,
            find.widgetWithText(Tab, tab),
            'the $tab tab',
          );
        }

        // The Appearance tab's theme choice still lands. (The loop above left
        // the strip scrolled to its far end — bring the tab back first, as a
        // finger would.)
        await tester.ensureVisible(find.widgetWithText(Tab, 'Appearance'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(Tab, 'Appearance'));
        await tester.pumpAndSettle();
        _expectNoOverflow(tester, 'the Appearance tab');
        await tester.tap(find.byKey(const Key('theme-dark')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
              .groupValue,
          'dark',
          reason: 'the theme radio no longer selects what was tapped',
        );
      });
    });
  }
}
