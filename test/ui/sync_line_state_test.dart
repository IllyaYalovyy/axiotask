// The sync line's two standing states: amber while local changes wait to be
// sent, red while sync needs the user. Driven through [LiveSyncLine] over the
// four live signals it reads, mounted where the app mounts it: the compact app
// bar and the expanded layout's list toolbar.

import 'dart:async';

import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/app/sync_status.dart';
import 'package:axiotask/src/auth/auth_controller.dart';
import 'package:axiotask/src/ui/list_detail_scaffold.dart';
import 'package:axiotask/src/ui/motion.dart';
import 'package:axiotask/src/ui/sync_feedback.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/color_metrics.dart';
import '../support/pump_motion.dart';
import 'composed_list.dart';
import 'detail_harness.dart' show FakeCommands, list, row;

final _progress = find.byKey(const Key('sync-progress-line'));
final _solid = find.byKey(const Key('sync-state-line'));

const _healthy = SyncStatusView.initial();

SyncStatusView _status({
  bool needsAttention = false,
  bool needsReauth = false,
  String? lastError,
}) => SyncStatusView(
  lastSynced: null,
  lastPulled: 0,
  lastPushed: 0,
  lastConflicts: 0,
  lastDeleted: 0,
  totalSyncs: 0,
  lastError: lastError,
  needsAttention: needsAttention,
  needsReauth: needsReauth,
);

/// The live signals, each hand-driven.
class _Signals {
  final status = StreamController<SyncStatusView>();
  final auth = StreamController<AuthSnapshot>();
  final pending = StreamController<int>();
  final runs = StreamController<SyncRunEvent>();

  void close() {
    // Not awaited: a close future never completes under fake async.
    unawaited(status.close());
    unawaited(auth.close());
    unawaited(pending.close());
    unawaited(runs.close());
  }
}

void _noop(String _) {}

Future<_Signals> _pump(
  WidgetTester tester, {
  required Size size,
  ThemeData? theme,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final signals = _Signals();
  addTearDown(signals.close);
  final fake = FakeCommands([row('T1', 'first'), row('T2', 'second')]);
  addTearDown(fake.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(
          const Prefs(sortPerView: {'all': 'alpha'}),
        ),
        commandsProvider.overrideWithValue(fake),
        allTasksProvider.overrideWith((ref) => fake.tasksStream),
        listsProvider.overrideWith((ref) => Stream.value([list('L1', 'L')])),
        syncStatusStreamProvider.overrideWith((ref) => signals.status.stream),
        authSnapshotProvider.overrideWith((ref) => signals.auth.stream),
        pendingPushCountProvider.overrideWith((ref) => signals.pending.stream),
        syncRunEventsProvider.overrideWith((ref) => signals.runs.stream),
      ],
      child: MaterialApp(
        theme: theme ?? buildLightTheme(),
        home: ListDetailScaffold(
          sidebar: const Text('SIDEBAR'),
          destinations: const [
            ShellDestination(
              icon: Icons.bolt_outlined,
              selectedIcon: Icons.bolt,
              label: 'Focus',
            ),
          ],
          selectedIndex: 0,
          onDestinationSelected: (_) {},
          title: 'All Tasks',
          syncLine: const LiveSyncLine(),
          list: composedList(viewId: 'all', onOpenTask: _noop),
        ),
      ),
    ),
  );
  await _deliver(tester);
  return signals;
}

/// Two frames carry a stream event to the widget; the third settles the rebuild
/// without `pumpAndSettle`, which an indeterminate line never lets finish.
Future<void> _deliver(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

Color _solidColor(WidgetTester tester) =>
    tester.widget<ColoredBox>(_solid).color;

/// The colour of the held line, asserting there is exactly one line and that it
/// stays put as time passes.
Future<Color> _held(WidgetTester tester) async {
  expect(_solid, findsOneWidget);
  expect(_progress, findsNothing);
  final color = _solidColor(tester);
  await tester.pump(const Duration(minutes: 5));
  expect(_solid, findsOneWidget);
  expect(_solidColor(tester), color);
  return color;
}

void _expectInvisible() {
  expect(_solid, findsNothing);
  expect(_progress, findsNothing);
}

const _phone = Size(400, 800);
const _desktop = Size(1200, 800);

void main() {
  final scheme = buildLightTheme().colorScheme;
  final amber = syncPendingColor(Brightness.light);

  testWidgets('idle and healthy: no line', (tester) async {
    final signals = await _pump(tester, size: _phone);
    _expectInvisible();
    signals.status.add(_healthy);
    signals.pending.add(0);
    await _deliver(tester);
    _expectInvisible();
  });

  testWidgets('pending changes hold amber until a run takes over', (
    tester,
  ) async {
    final signals = await _pump(tester, size: _phone);
    signals.pending.add(2);
    await _deliver(tester);
    expect(await _held(tester), amber);

    signals.runs.add(const SyncRunEvent.started());
    await _deliver(tester);
    expect(_solid, findsNothing);
    expect(tester.widget<LinearProgressIndicator>(_progress).value, isNull);
    expect(
      tester.widget<LinearProgressIndicator>(_progress).color,
      scheme.primary,
    );

    signals.pending.add(0);
    signals.runs.add(const SyncRunEvent.finished(changed: true, failed: false));
    await _deliver(tester);
    expect(
      tester.widget<LinearProgressIndicator>(_progress).value,
      isNotNull,
      reason: 'the usual fill and fade',
    );
    await pumpMotion(tester, MotionDurations.syncLineFinish);
    _expectInvisible();
  });

  testWidgets('changes still pending when a run ends bring amber back', (
    tester,
  ) async {
    final signals = await _pump(tester, size: _phone);
    signals.pending.add(1);
    signals.runs.add(const SyncRunEvent.started());
    await _deliver(tester);
    signals.runs.add(const SyncRunEvent.finished(changed: false, failed: true));
    await _deliver(tester);
    expect(await _held(tester), amber);
  });

  for (final (name, failure) in [
    ('a permanent failure', _status(needsAttention: true)),
    ('a dead session in the sync status', _status(needsReauth: true)),
  ]) {
    testWidgets('$name holds red over amber and running, until cleared', (
      tester,
    ) async {
      final signals = await _pump(tester, size: _phone);
      signals.status.add(failure);
      await _deliver(tester);
      expect(await _held(tester), scheme.error);

      signals.pending.add(3);
      await _deliver(tester);
      expect(await _held(tester), scheme.error);

      signals.runs.add(const SyncRunEvent.started());
      await _deliver(tester);
      expect(await _held(tester), scheme.error);

      signals.runs.add(
        const SyncRunEvent.finished(changed: false, failed: true),
      );
      await _deliver(tester);
      expect(await _held(tester), scheme.error);

      signals.status.add(_healthy);
      await _deliver(tester);
      expect(await _held(tester), amber);

      signals.pending.add(0);
      await _deliver(tester);
      _expectInvisible();
    });
  }

  testWidgets('a dead session in the auth snapshot holds red', (tester) async {
    final signals = await _pump(tester, size: _phone);
    signals.auth.add(
      const AuthSnapshot(isAuthenticated: true, needsReauth: true),
    );
    await _deliver(tester);
    expect(await _held(tester), scheme.error);

    signals.auth.add(
      const AuthSnapshot(isAuthenticated: true, needsReauth: false),
    );
    await _deliver(tester);
    _expectInvisible();
  });

  testWidgets('a transient failure never turns the line red', (tester) async {
    final signals = await _pump(tester, size: _phone);
    signals.runs.add(const SyncRunEvent.started());
    await _deliver(tester);
    signals.status.add(_status(lastError: 'offline'));
    signals.runs.add(const SyncRunEvent.finished(changed: false, failed: true));
    await _deliver(tester);
    expect(_solid, findsNothing);
    await pumpMotion(tester, MotionDurations.syncLineFinish);
    _expectInvisible();
  });

  for (final (layout, size) in [('compact', _phone), ('expanded', _desktop)]) {
    testWidgets('$layout: 2dp in every state, and nothing else moves', (
      tester,
    ) async {
      final signals = await _pump(tester, size: size);

      List<Rect> layoutRects() => [
        for (final text in ['first', 'second']) tester.getRect(find.text(text)),
        if (size == _phone) tester.getRect(find.byType(AppBar)),
      ];

      void expectLineGeometry(Finder line) {
        expect(line, findsOneWidget);
        final rect = tester.getRect(line);
        expect(rect.height, kSyncLineHeight);
        final host = tester.getRect(find.byType(LiveSyncLine));
        expect(rect, host);
        expect(rect.width, greaterThan(size.width / 3));
        if (size == _phone) {
          final bar = tester.getRect(find.byType(AppBar));
          expect(rect.bottom, bar.bottom);
          expect(rect.width, bar.width);
        }
      }

      final atRest = layoutRects();

      signals.pending.add(1);
      await _deliver(tester);
      expectLineGeometry(_solid);
      expect(layoutRects(), atRest);

      signals.status.add(_status(needsAttention: true));
      await _deliver(tester);
      expectLineGeometry(_solid);
      expect(layoutRects(), atRest);

      signals.status.add(_healthy);
      signals.pending.add(0);
      await _deliver(tester);
      _expectInvisible();
      expect(layoutRects(), atRest);

      signals.runs.add(const SyncRunEvent.started());
      await _deliver(tester);
      expectLineGeometry(_progress);
      expect(layoutRects(), atRest);
    });
  }

  testWidgets('each standing state is named to a screen reader', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final signals = await _pump(tester, size: _phone);
    final waiting = find.bySemanticsLabel('Changes waiting to sync');
    final attention = find.bySemanticsLabel('Sync needs attention');
    expect(waiting, findsNothing);
    expect(attention, findsNothing);

    signals.pending.add(1);
    await _deliver(tester);
    expect(waiting, findsOneWidget);
    expect(attention, findsNothing);
    expect(tester.getSemantics(waiting).value, isEmpty);

    signals.status.add(_status(needsAttention: true));
    await _deliver(tester);
    expect(attention, findsOneWidget);
    expect(waiting, findsNothing);

    signals.status.add(_healthy);
    signals.pending.add(0);
    await _deliver(tester);
    expect(waiting, findsNothing);
    expect(attention, findsNothing);
    handle.dispose();
  });

  for (final (name, theme) in [
    ('light', buildLightTheme()),
    ('dark', buildDarkTheme()),
  ]) {
    testWidgets('$name: both colours are 3:1 against the app bar', (
      tester,
    ) async {
      final signals = await _pump(tester, size: _phone, theme: theme);
      final backgrounds = [
        // At rest, as painted…
        tester
            .widget<Material>(
              find
                  .descendant(
                    of: find.byType(AppBar),
                    matching: find.byType(Material),
                  )
                  .first,
            )
            .color!,
        // …and the tint Material 3 gives a bar with rows scrolled under it.
        theme.colorScheme.surfaceContainer,
      ];

      Future<void> expectContrast() async {
        final color = _solidColor(tester);
        for (final background in backgrounds) {
          expect(contrastRatio(color, background), greaterThanOrEqualTo(3));
        }
      }

      signals.pending.add(1);
      await _deliver(tester);
      expect(_solidColor(tester), syncPendingColor(theme.brightness));
      await expectContrast();

      signals.status.add(_status(needsAttention: true));
      await _deliver(tester);
      expect(_solidColor(tester), theme.colorScheme.error);
      await expectContrast();
    });
  }
}
