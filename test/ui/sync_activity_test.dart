// The Sync activity screen (#218) — reachable from Properties → Sync, never
// from the front page.
//
// What these protect: the per-run history renders what the store holds (newest
// first, counts and times as TEXT the user reads), an empty history says so
// intentionally instead of rendering a blank panel, a failed run shows its
// CLASSIFICATION and never the provider text behind it, absolute times are the
// LOCAL wall clock, and the Android back button walks the route ladder
// activity → Properties → shell one rung per press.

import 'dart:io';

import 'package:axiotask/src/app/app_settings.dart';
import 'package:axiotask/src/app/config.dart';
import 'package:axiotask/src/app/config_controller.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/app/sync_status.dart';
import 'package:axiotask/src/model/sync_run.dart';
import 'package:axiotask/src/ui/properties.dart';
import 'package:axiotask/src/ui/sync_activity.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A captive portal answers 200 with an HTML login page; the decode failure
/// carries the whole body, secret-bearing login URL and all. Nothing on this
/// screen may echo any of it (#131/#187, G6/#204).
const captivePortalHtml =
    '<!DOCTYPE html><html><head><title>Wi-Fi Login</title></head>'
    '<body>Please sign in at http://wifi.local/login?token=SECRET'
    '</body></html>';

/// Every string the screen actually renders — the surface a leak would show up
/// on. Reads the widget tree, not the source of the data.
List<String> renderedText(WidgetTester tester) => [
  for (final t in tester.widgetList<Text>(find.byType(Text)))
    t.data ?? t.textSpan?.toPlainText() ?? '',
];

AppSettingsView settingsView({
  SyncStatusView sync = const SyncStatusView.initial(),
  int pendingPushes = 0,
}) => AppSettingsView(
  version: '0.1.0',
  instance: null,
  pushEnabled: true,
  autoSyncOnStart: true,
  authenticated: true,
  needsReauth: false,
  scopes: const ['https://www.googleapis.com/auth/tasks'],
  dbPath: '/tmp/axiotask/axiotask.sqlite',
  configPath: '/tmp/axiotask/config.json',
  pendingPushes: pendingPushes,
  sync: sync,
);

SyncStatusView statusView({String? lastSynced, int totalSyncs = 0}) =>
    SyncStatusView(
      lastSynced: lastSynced,
      lastPulled: 0,
      lastPushed: 0,
      lastConflicts: 0,
      lastDeleted: 0,
      totalSyncs: totalSyncs,
      lastError: null,
      needsAttention: false,
      needsReauth: false,
    );

SyncRun run({
  required int id,
  required DateTime? ranAt,
  int pulled = 0,
  int pushed = 0,
  int conflicts = 0,
  int durationMs = 120,
  SyncFailureKind? failure,
}) => SyncRun(
  id: id,
  ranAt: ranAt,
  durationMs: durationMs,
  pulled: pulled,
  pushed: pushed,
  conflicts: conflicts,
  failure: failure,
);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('axiotask_sync_act'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });
  File configFile() => File('${tmp.path}/config.json');

  // A fixed "now" so every relative label ("3m ago") is deterministic — no wall
  // clock anywhere in this suite.
  final now = DateTime(2026, 6, 15, 14, 30);

  Future<void> pumpActivity(
    WidgetTester tester, {
    List<SyncRun> runs = const [],
    AppSettingsView? settings,
    Size size = const Size(1000, 1200),
    double textScale = 1.0,
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await withClock(Clock.fixed(now), () async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSettingsProvider.overrideWithValue(settings ?? settingsView()),
            syncRunsProvider.overrideWith((ref) async => runs),
          ],
          child: MaterialApp(
            theme: theme ?? buildLightTheme(),
            // copyWith, never a fresh MediaQueryData: the screen branches on
            // MediaQuery.sizeOf, and a replacement would hand it a zero size.
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: const Scaffold(body: SyncActivityScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    });
  }

  group('recent runs', () {
    testWidgets('renders each run\'s counts and time, newest first', (
      tester,
    ) async {
      await pumpActivity(
        tester,
        runs: [
          run(
            id: 2,
            ranAt: DateTime(2026, 6, 15, 14, 27).toUtc(),
            pulled: 7,
            pushed: 3,
            conflicts: 2,
            durationMs: 412,
          ),
          run(id: 1, ranAt: DateTime(2026, 6, 15, 11, 30).toUtc(), pulled: 1),
        ],
      );

      // The newer run's numbers, as the user reads them.
      expect(find.textContaining('↓7'), findsOneWidget);
      expect(find.textContaining('↑3'), findsOneWidget);
      expect(find.textContaining('2 conflicts'), findsOneWidget);
      expect(find.textContaining('412 ms'), findsOneWidget);

      // Both runs render, newest above oldest.
      final newer = tester.getTopLeft(find.byKey(const Key('sync-run-2'))).dy;
      final older = tester.getTopLeft(find.byKey(const Key('sync-run-1'))).dy;
      expect(newer, lessThan(older), reason: 'newest run first');

      // Relative AND absolute, both readable on the row.
      expect(find.textContaining('3m ago'), findsOneWidget);
      expect(find.textContaining('3h ago'), findsOneWidget);
      expect(find.textContaining('Jun 15 14:27'), findsOneWidget);
      expect(find.textContaining('Jun 15 11:30'), findsOneWidget);
    });

    testWidgets('absolute run times are the LOCAL wall clock, never UTC', (
      tester,
    ) async {
      // The instant is built from LOCAL calendar fields, so on any machine whose
      // zone is not UTC a UTC-rendering screen prints different digits here.
      final localMoment = DateTime(2026, 6, 15, 9, 5);
      await pumpActivity(
        tester,
        runs: [run(id: 1, ranAt: localMoment.toUtc())],
      );
      expect(find.textContaining('Jun 15 09:05'), findsOneWidget);
      expect(
        renderedText(tester).any((t) => t.contains('16:05')),
        isFalse,
        reason: 'no UTC wall clock leaks into the row',
      );
    });

    testWidgets('a run with no usable timestamp still lists its counts', (
      tester,
    ) async {
      // Non-happy path: a corrupted `ran_at` must not hide the run — the counts
      // and the outcome are still the truth about what happened.
      await pumpActivity(
        tester,
        runs: [run(id: 1, ranAt: null, pulled: 4, failure: null)],
      );
      expect(find.byKey(const Key('sync-run-1')), findsOneWidget);
      expect(find.textContaining('↓4'), findsOneWidget);
      expect(find.textContaining('Unknown time'), findsOneWidget);
    });
  });

  group('empty state', () {
    testWidgets('no runs renders "No syncs yet", not a blank panel', (
      tester,
    ) async {
      await pumpActivity(tester);
      expect(find.byKey(const Key('sync-activity-empty')), findsOneWidget);
      expect(find.text('No syncs yet'), findsOneWidget);
      expect(find.byKey(const Key('sync-run-1')), findsNothing);
    });
  });

  group('history unavailable', () {
    testWidgets('a failing history read says so, instead of a silent blank', (
      tester,
    ) async {
      // Non-happy path: the local database read throws. Rendering nothing would
      // read as "no syncs yet" — a lie about the sync history.
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await withClock(Clock.fixed(now), () async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appSettingsProvider.overrideWithValue(settingsView()),
              syncRunsProvider.overrideWith(
                (ref) async => throw StateError('db is gone'),
              ),
            ],
            child: MaterialApp(
              theme: buildLightTheme(),
              home: const Scaffold(body: SyncActivityScreen()),
            ),
          ),
        );
        await tester.pumpAndSettle();
      });

      expect(find.byKey(const Key('sync-activity-error')), findsOneWidget);
      expect(find.byKey(const Key('sync-activity-empty')), findsNothing);
      // The thrown detail is internal — it never reaches the screen.
      expect(renderedText(tester).join('\n'), isNot(contains('db is gone')));
    });
  });

  group('failure classification is sanitized', () {
    testWidgets('a failed run shows the classification, never the provider '
        'text behind it', (tester) async {
      // The failure is derived from the captive-portal body exactly as the store
      // derives it, so this drives the whole path the real data takes.
      final kind = SyncFailureKind.parse(captivePortalHtml);
      expect(
        kind,
        SyncFailureKind.unknown,
        reason: 'nothing is passed through',
      );

      await pumpActivity(
        tester,
        runs: [
          run(
            id: 1,
            ranAt: DateTime(2026, 6, 15, 14, 0).toUtc(),
            failure: kind,
          ),
        ],
      );

      expect(
        find.textContaining('Sync failed — the details are in the log'),
        findsOneWidget,
      );
      final texts = renderedText(tester).join('\n');
      expect(texts, isNot(contains('SECRET')));
      expect(texts, isNot(contains('wifi.local')));
      expect(texts, isNot(contains('<html')));
      expect(texts, isNot(contains('DOCTYPE')));
    });

    testWidgets('distinct failures read distinctly', (tester) async {
      await pumpActivity(
        tester,
        runs: [
          run(
            id: 2,
            ranAt: DateTime(2026, 6, 15, 14, 0).toUtc(),
            failure: SyncFailureKind.network,
          ),
          run(
            id: 1,
            ranAt: DateTime(2026, 6, 15, 13, 0).toUtc(),
            failure: SyncFailureKind.store,
          ),
        ],
      );
      expect(find.textContaining("Couldn't reach Google"), findsOneWidget);
      expect(find.textContaining('Local database problem'), findsOneWidget);
    });
  });

  group('summary', () {
    testWidgets('shows last sync relative AND absolute, session and pending '
        'counts', (tester) async {
      await pumpActivity(
        tester,
        settings: settingsView(
          pendingPushes: 5,
          sync: statusView(
            lastSynced: DateTime(2026, 6, 15, 14, 25).toUtc().toIso8601String(),
            totalSyncs: 12,
          ),
        ),
      );
      expect(find.textContaining('5m ago'), findsOneWidget);
      expect(find.textContaining('Jun 15 14:25'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
    });

    testWidgets('never synced reads "never", not a blank or an epoch', (
      tester,
    ) async {
      await pumpActivity(tester);
      expect(find.text('never'), findsOneWidget);
      expect(find.textContaining('1970'), findsNothing);
    });
  });

  group('adaptive surface', () {
    testWidgets('fills the screen on a phone', (tester) async {
      await pumpActivity(tester, size: const Size(400, 800));
      final surface = tester.getSize(
        find.byKey(const Key('sync-activity-surface')),
      );
      expect(surface.width, 400);
      expect(surface.height, 800);
    });

    testWidgets('stays a dialog-sized surface on the desktop', (tester) async {
      await pumpActivity(
        tester,
        size: const Size(1400, 1000),
        runs: [
          for (var i = 1; i <= 40; i++)
            run(id: i, ranAt: DateTime(2026, 6, 15, 10).toUtc()),
        ],
      );
      final surface = tester.getSize(
        find.byKey(const Key('sync-activity-surface')),
      );
      expect(surface.width, lessThan(700));
      expect(surface.height, lessThanOrEqualTo(620));
    });

    testWidgets('a short history gets a surface sized to it, not 620dp of '
        'empty dialog', (tester) async {
      await pumpActivity(tester, size: const Size(1400, 1000));
      final surface = tester.getSize(
        find.byKey(const Key('sync-activity-surface')),
      );
      expect(surface.height, lessThan(400));
    });

    testWidgets('the phone dismiss affordance is a full-size touch target', (
      tester,
    ) async {
      await pumpActivity(tester, size: const Size(430, 900));
      final hit = tester.getSize(find.byKey(const Key('sync-activity-close')));
      expect(hit.width, greaterThanOrEqualTo(48));
      expect(hit.height, greaterThanOrEqualTo(48));
      // Leading, per the platform's back convention — not stranded on the far
      // right where a thumb has to cross the screen.
      expect(
        tester.getTopLeft(find.byKey(const Key('sync-activity-close'))).dx,
        lessThan(100),
      );
    });
  });

  group('safe area on a phone (T8.2 contract)', () {
    testWidgets('the full-screen surface reaches the edges while its controls '
        'clear the status bar and gesture pill', (tester) async {
      // A device with a status bar and a bottom gesture pill. The page surface
      // must paint edge to edge — a surface inset by the system bars leaves the
      // scrim showing as a stripe — while nothing tappable or readable sits
      // under either bar.
      const phone = Size(430, 900);
      const padding = EdgeInsets.only(top: 50, bottom: 34);
      tester.view.physicalSize = phone;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await withClock(Clock.fixed(now), () async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appSettingsProvider.overrideWithValue(settingsView()),
              syncRunsProvider.overrideWith(
                (ref) async => [
                  run(id: 1, ranAt: DateTime(2026, 6, 15, 14, 27).toUtc()),
                ],
              ),
            ],
            child: MaterialApp(
              theme: buildLightTheme(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(padding: padding),
                child: child!,
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showSyncActivity(context),
                    child: const Text('open activity'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open activity'));
        await tester.pumpAndSettle();
      });

      final surface = tester.getRect(
        find.byKey(const Key('sync-activity-surface')),
      );
      expect(surface.top, 0, reason: 'the page paints under the status bar');
      expect(surface.bottom, phone.height);

      // …but its controls and content do not.
      expect(
        tester.getRect(find.byKey(const Key('sync-activity-close'))).top,
        greaterThanOrEqualTo(padding.top),
      );
      expect(
        tester.getRect(find.text('Sync activity')).top,
        greaterThanOrEqualTo(padding.top),
      );
      expect(
        tester.getRect(find.byKey(const Key('sync-run-1'))).bottom,
        lessThanOrEqualTo(phone.height - padding.bottom),
      );
    });
  });

  group('safe area on a landscape phone', () {
    testWidgets('the dialog surface clears a side cutout', (tester) async {
      // A phone in landscape is wide enough for the dialog branch, and its
      // cutout is on the side the dialog would otherwise reach.
      const landscape = Size(700, 430);
      const padding = EdgeInsets.only(left: 60, right: 60);
      tester.view.physicalSize = landscape;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await withClock(Clock.fixed(now), () async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appSettingsProvider.overrideWithValue(settingsView()),
              syncRunsProvider.overrideWith((ref) async => <SyncRun>[]),
            ],
            child: MaterialApp(
              theme: buildLightTheme(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(padding: padding),
                child: child!,
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showSyncActivity(context),
                    child: const Text('open activity'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open activity'));
        await tester.pumpAndSettle();
      });

      final surface = tester.getRect(
        find.byKey(const Key('sync-activity-surface')),
      );
      expect(surface.left, greaterThanOrEqualTo(padding.left));
      expect(surface.right, lessThanOrEqualTo(landscape.width - padding.right));
    });
  });

  group('legibility', () {
    for (final (name, theme) in [
      ('light', buildLightTheme()),
      ('dark', buildDarkTheme()),
    ]) {
      testWidgets('$name theme at text scale 1.3 renders without overflow', (
        tester,
      ) async {
        await pumpActivity(
          tester,
          theme: theme,
          textScale: 1.3,
          size: const Size(400, 800),
          settings: settingsView(
            pendingPushes: 3,
            sync: statusView(
              lastSynced: DateTime(
                2026,
                6,
                15,
                14,
                25,
              ).toUtc().toIso8601String(),
              totalSyncs: 12,
            ),
          ),
          runs: [
            run(
              id: 2,
              ranAt: DateTime(2026, 6, 15, 14, 27).toUtc(),
              pulled: 137,
              pushed: 42,
              conflicts: 9,
              durationMs: 12345,
              failure: SyncFailureKind.precondition,
            ),
            run(id: 1, ranAt: DateTime(2026, 6, 15, 11, 30).toUtc(), pulled: 1),
          ],
        );
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('sync-run-2')), findsOneWidget);
        expect(find.text('Sync activity'), findsOneWidget);
      });
    }
  });

  group('navigation from Properties (AndroidBackButton contract)', () {
    testWidgets('back closes activity → Properties survives → next back closes '
        'Properties', (tester) async {
      // A real phone width (Pixel-class, 430dp). Wide enough that the
      // Properties dialog's own header fits under the widget-test font, whose
      // glyphs are square 1em boxes and so measure far wider than production
      // type — the surface under test here is the ladder, not that header.
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await withClock(Clock.fixed(now), () async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appSettingsProvider.overrideWithValue(settingsView()),
              configControllerProvider.overrideWithValue(
                ConfigController(
                  path: configFile(),
                  initial: const AppConfig(),
                ),
              ),
              syncRunsProvider.overrideWith((ref) async => <SyncRun>[]),
            ],
            child: MaterialApp(
              theme: buildLightTheme(),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showProperties(context),
                    child: const Text('open props'),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('open props'));
        await tester.pumpAndSettle();
        expect(find.text('Properties'), findsOneWidget);

        // The affordance lives beside the Sync tab's Status block, and is a
        // full-size touch target — this is a phone.
        final trigger = tester.getSize(
          find.byKey(const Key('sync-activity-button')),
        );
        expect(trigger.height, greaterThanOrEqualTo(48));
        await tester.tap(find.byKey(const Key('sync-activity-button')));
        await tester.pumpAndSettle();
        expect(find.text('Sync activity'), findsOneWidget);

        // One back: the activity screen closes; Properties is still there.
        expect(await tester.binding.handlePopRoute(), isTrue);
        await tester.pumpAndSettle();
        expect(find.text('Sync activity'), findsNothing);
        expect(
          find.text('Properties'),
          findsOneWidget,
          reason: 'back returns to Properties — one rung per press',
        );

        // A second back closes Properties itself.
        expect(await tester.binding.handlePopRoute(), isTrue);
        await tester.pumpAndSettle();
        expect(find.text('Properties'), findsNothing);
        expect(find.text('open props'), findsOneWidget);

        // A third back has no app-owned rung left — the OS gets it.
        expect(await tester.binding.handlePopRoute(), isFalse);
      });
    });
  });
}
