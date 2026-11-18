import 'package:axiotask/src/features/tasks/widgets/sync_health_header.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../support/touch_targets.dart';

void main() {
  setUpAll(loadAndroidTextFont);
  final evaluatedAt = DateTime.utc(2026, 8, 22, 12);

  Widget buildHeader(
    SyncHealth health, {
    ValueChanged<SyncHealthAction>? onAction,
  }) => MaterialApp(
    home: Scaffold(
      body: SyncHealthHeader(health: health, onAction: onAction),
    ),
  );

  SyncHealth health({
    required SyncHealthOutcome outcome,
    SyncInactiveReason? inactiveReason,
    SyncFailureReason? failureReason,
    SyncPendingReason? pendingReason,
    SyncHealthAction action = SyncHealthAction.none,
    SyncWorkCounts counts = const SyncWorkCounts(),
    DateTime? lastSuccessfulSyncAt,
  }) => SyncHealth(
    outcome: outcome,
    inactiveReason: inactiveReason,
    failureReason: failureReason,
    pendingReason: pendingReason,
    action: action,
    counts: counts,
    lastSuccessfulSyncAt: lastSuccessfulSyncAt,
    evaluatedAt: evaluatedAt,
  );

  testWidgets('Good is calm, relative, and exposes exact details', (
    tester,
  ) async {
    final good = health(
      outcome: SyncHealthOutcome.good,
      lastSuccessfulSyncAt: evaluatedAt.subtract(const Duration(minutes: 2)),
    );
    await tester.pumpWidget(buildHeader(good, onAction: (_) {}));

    expect(find.text('Synced'), findsOneWidget);
    expect(find.text('2 minutes ago'), findsOneWidget);
    expect(find.text('Last successful sync:'), findsNothing);
    expect(find.text('0 unresolved'), findsNothing);
    expect(
      find.bySemanticsLabel(
        'Synchronization Synced. Synchronization completed. '
        'No unresolved changes. '
        'Last successful sync 2026-08-22 11:58 UTC (2 minutes ago). '
        'Open synchronization details.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Sync details'));
    await tester.pumpAndSettle();
    expect(find.text('Synchronization details'), findsOneWidget);
    expect(find.text('Last successful sync'), findsOneWidget);
    expect(find.text('2026-08-22 11:58 UTC'), findsOneWidget);
  });

  testWidgets(
    'problem states remain expanded and show nonzero unresolved work',
    (tester) async {
      final cases = <(SyncHealth, String)>[
        (
          health(
            outcome: SyncHealthOutcome.inactive,
            inactiveReason: SyncInactiveReason.noAuthorization,
            action: SyncHealthAction.reauthorize,
            counts: const SyncWorkCounts(pending: 1),
          ),
          'No authorization',
        ),
        (
          health(
            outcome: SyncHealthOutcome.failed,
            failureReason: SyncFailureReason.remoteFailure,
            action: SyncHealthAction.retry,
            counts: const SyncWorkCounts(failed: 1),
          ),
          'Google Tasks failed',
        ),
        (
          health(
            outcome: SyncHealthOutcome.pending,
            pendingReason: SyncPendingReason.localChanges,
            counts: const SyncWorkCounts(uncertain: 1),
          ),
          'Changes awaiting Google',
        ),
      ];

      for (final (state, reason) in cases) {
        await tester.pumpWidget(buildHeader(state));
        expect(find.byKey(const Key('sync-health-banner')), findsOneWidget);
        expect(find.text('${state.summary} · $reason'), findsOneWidget);
        expect(
          tester
              .widget<Text>(find.byKey(const Key('sync-health-explanation')))
              .data,
          startsWith('1 change '),
        );
      }
    },
  );

  testWidgets('stopped and stale qualifiers remain explicit', (tester) async {
    await tester.pumpWidget(
      buildHeader(
        health(
          outcome: SyncHealthOutcome.inactive,
          inactiveReason: SyncInactiveReason.syncStopped,
          action: SyncHealthAction.resume,
        ),
      ),
    );
    expect(find.text('Inactive · Sync stopped'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);

    await tester.pumpWidget(
      buildHeader(
        health(
          outcome: SyncHealthOutcome.failed,
          failureReason: SyncFailureReason.stale,
          action: SyncHealthAction.retry,
          lastSuccessfulSyncAt: evaluatedAt.subtract(
            const Duration(minutes: 5),
          ),
        ),
      ),
    );
    expect(find.text('Failed · Cached data is stale'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('every health action is reachable', (tester) async {
    final cases = <(SyncHealthAction, SyncHealth)>[
      (
        SyncHealthAction.connect,
        health(
          outcome: SyncHealthOutcome.inactive,
          inactiveReason: SyncInactiveReason.noAuthorization,
          action: SyncHealthAction.connect,
        ),
      ),
      (
        SyncHealthAction.reauthorize,
        health(
          outcome: SyncHealthOutcome.inactive,
          inactiveReason: SyncInactiveReason.noAuthorization,
          action: SyncHealthAction.reauthorize,
        ),
      ),
      (
        SyncHealthAction.resume,
        health(
          outcome: SyncHealthOutcome.inactive,
          inactiveReason: SyncInactiveReason.syncStopped,
          action: SyncHealthAction.resume,
        ),
      ),
      (
        SyncHealthAction.retry,
        health(
          outcome: SyncHealthOutcome.failed,
          failureReason: SyncFailureReason.noConnection,
          action: SyncHealthAction.retry,
        ),
      ),
    ];
    final received = <SyncHealthAction>[];

    for (final (action, state) in cases) {
      await tester.pumpWidget(buildHeader(state, onAction: received.add));
      await tester.tap(find.text(_actionLabel(action)));
      await tester.pump();
    }

    expect(received, cases.map((value) => value.$1));
  });

  testWidgets('Good remains usable at 200 percent text scale', (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: buildHeader(
          health(
            outcome: SyncHealthOutcome.good,
            lastSuccessfulSyncAt: evaluatedAt.subtract(
              const Duration(minutes: 1),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Sync details'), findsOneWidget);
  });
  group('routine pending status (Android audit 18)', () {
    SyncHealth queuedEdit({
      Duration age = const Duration(seconds: 30),
      SyncWorkCounts counts = const SyncWorkCounts(pending: 1),
    }) => SyncHealth(
      outcome: SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: counts,
      lastSuccessfulSyncAt: evaluatedAt.subtract(age),
      evaluatedAt: evaluatedAt,
    );

    for (final width in <double>[320, 360]) {
      for (final scale in <double>[1, 2]) {
        testWidgets('one queued edit stays compact at $width, ${scale}x', (
          tester,
        ) async {
          _useView(tester, width);
          // Phones and large text use the icon; the wide-window label is
          // covered by its own test below.
          await tester.pumpWidget(
            _phone(
              scale,
              SyncHealthHeader(health: queuedEdit(), iconOnly: true),
            ),
          );
          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('sync-health-banner')), findsNothing);
          expect(find.text('Pending'), findsNothing);
          expect(find.text('Synced'), findsNothing);
          expect(find.text('First task').hitTestable(), findsOneWidget);
          final status = find.byKey(const Key('sync-health-pending'));
          expect(tester.getSize(status).height, lessThanOrEqualTo(48 * 1.5));
          expect(
            find.descendant(of: status, matching: find.text('1')),
            findsOneWidget,
          );
          expectTouchTarget(
            tester,
            status,
            label: '1 change saved on this device, not yet on Google.',
          );
          final label = tester.getSemantics(status).getSemanticsData().label;
          expect(label, contains('Synchronization Pending'));
          expect(label, contains('not yet on Google'));
          expect(label, isNot(contains('Synced')));

          await tester.tap(find.byKey(const Key('sync-health-pending')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Pending: Changes awaiting Google'), findsOneWidget);
          expect(
            find.text('1 change saved on this device, not yet on Google.'),
            findsOneWidget,
          );
          expect(
            find.text(
              'Unresolved changes: 1 waiting to send, 0 sending, '
              '0 awaiting confirmation, 0 failed',
            ),
            findsOneWidget,
          );
        });
      }
    }

    testWidgets('wide windows label the queued edit without claiming sync', (
      tester,
    ) async {
      _useView(tester, 800);
      await tester.pumpWidget(
        _phone(1, SyncHealthHeader(health: queuedEdit())),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('sync-health-banner')), findsNothing);
      expect(find.text('Saved on device'), findsOneWidget);
      expect(find.text('1 waiting for Google'), findsOneWidget);
      expect(find.text('Synced'), findsNothing);
      expect(find.text('Pending'), findsNothing);
    });

    testWidgets('old, uncertain or failed local work stays expanded', (
      tester,
    ) async {
      _useView(tester, 360);
      final cases = <(SyncHealth, String)>[
        (
          queuedEdit(age: const Duration(minutes: 6)),
          'Last successful sync: 6 minutes ago',
        ),
        (
          queuedEdit(counts: const SyncWorkCounts(uncertain: 1)),
          'Last successful sync: less than a minute ago',
        ),
      ];
      for (final (state, age) in cases) {
        await tester.pumpWidget(_phone(1, SyncHealthHeader(health: state)));
        expect(find.byKey(const Key('sync-health-banner')), findsOneWidget);
        expect(find.text('Pending · Changes awaiting Google'), findsOneWidget);
        expect(find.text(age), findsOneWidget);
      }
      expect(
        tester
            .widget<Text>(find.byKey(const Key('sync-health-explanation')))
            .data,
        '1 change sent but not yet confirmed by Google. '
        'Axiotask is confirming with Google.',
      );
    });
  });

  group('failure feedback (failure-message-usability)', () {
    for (final width in <double>[320, 360]) {
      for (final scale in <double>[1, 2]) {
        testWidgets('every state is specific, bounded and actionable at '
            '$width, ${scale}x', (tester) async {
          _useView(tester, width);
          for (final state in _states(evaluatedAt)) {
            final received = <SyncHealthAction>[];
            await tester.pumpWidget(
              _phone(
                scale,
                SyncHealthHeader(
                  health: state.health,
                  onAction: received.add,
                  iconOnly: true,
                ),
              ),
            );
            final where = '${state.name} at $width, ${scale}x';
            expect(tester.takeException(), isNull, reason: where);
            expect(
              find.text('First task').hitTestable(),
              findsOneWidget,
              reason: '$where keeps the task list visible',
            );
            final banner = find.byKey(const Key('sync-health-banner'));
            if (state.compact) {
              expect(banner, findsNothing, reason: where);
              continue;
            }
            final rect = tester.getRect(banner);
            expect(
              rect.height,
              lessThanOrEqualTo(_viewHeight * (scale > 1 ? 0.4 : 0.2)),
              reason: '$where banner $rect is bounded',
            );
            expect(
              find.text(state.headlineText),
              findsOneWidget,
              reason: where,
            );
            expect(
              _whole(tester, find.byKey(const Key('sync-health-headline'))),
              isTrue,
              reason: '$where headline is whole',
            );
            expect(
              _whole(tester, find.byKey(const Key('sync-health-last-success'))),
              isTrue,
              reason: '$where last-success age is whole',
            );
            if (scale == 1) {
              expect(
                _whole(
                  tester,
                  find.byKey(const Key('sync-health-explanation')),
                ),
                isTrue,
                reason: '$where explanation is whole',
              );
            }
            expect(
              tester
                  .widget<Text>(
                    find.byKey(const Key('sync-health-explanation')),
                  )
                  .data,
              state.explanation,
              reason: where,
            );
            final announced = tester
                .getSemantics(find.text(state.headlineText))
                .getSemanticsData()
                .label;
            expect(announced, contains(state.headline), reason: where);
            expect(announced, contains(state.explanation), reason: where);
            expect(announced, contains('Last successful sync'));
            expectTouchTarget(
              tester,
              find.byKey(const Key('sync-health-details')),
              label: 'Sync details',
            );
            final action = find.byKey(const Key('sync-health-action'));
            if (state.action case final expected?) {
              expectTouchTarget(tester, action, label: _actionLabel(expected));
              expect(tester.getRect(action).right, lessThanOrEqualTo(width));
              await tester.tap(action);
              await tester.pump();
              expect(received, <SyncHealthAction>[expected], reason: where);
            } else {
              expect(action, findsNothing, reason: where);
            }
          }
        });
      }
    }

    testWidgets('visible text never carries credentials or raw errors', (
      tester,
    ) async {
      _useView(tester, 360);
      for (final state in _states(evaluatedAt)) {
        await tester.pumpWidget(
          _phone(1, SyncHealthHeader(health: state.health, iconOnly: true)),
        );
        final visible = <String>[
          for (final text in tester.widgetList<Text>(find.byType(Text)))
            ?text.data,
        ];
        final code = state.health.diagnosticCode;
        for (final text in visible) {
          expect(text, isNot(matches(_sensitive)), reason: state.name);
          if (code != null) expect(text, isNot(contains(code)));
        }
      }
    });

    testWidgets('recent failure feedback stays bounded on a 320 by 640 phone', (
      tester,
    ) async {
      _useView(tester, 320);
      tester.view.physicalSize = const Size(320, 640);
      final actions = <SyncHealthAction>[];
      final failure = SyncHealth(
        outcome: SyncHealthOutcome.failed,
        counts: const SyncWorkCounts(failed: 1),
        lastSuccessfulSyncAt: evaluatedAt,
        evaluatedAt: evaluatedAt,
        failureReason: SyncFailureReason.applicationFailure,
        diagnosticCode: 'regression.unspecified_failure',
        action: SyncHealthAction.retry,
      );
      await tester.pumpWidget(
        _phone(1, SyncHealthHeader(health: failure, onAction: actions.add)),
      );
      expect(
        tester.getSize(find.byKey(const Key('sync-health-banner'))).height,
        lessThanOrEqualTo(128),
      );
      for (final key in <String>[
        'sync-health-headline',
        'sync-health-explanation',
        'sync-health-last-success',
      ]) {
        expect(_whole(tester, find.byKey(Key(key))), isTrue, reason: key);
      }
      final retry = find.byKey(const Key('sync-health-action'));
      expectTouchTarget(tester, retry, label: 'Retry');
      await tester.tap(retry);
      expect(actions, <SyncHealthAction>[SyncHealthAction.retry]);
    });

    testWidgets('unknown failures state uncertainty and offer details', (
      tester,
    ) async {
      _useView(tester, 360);
      final unknown = _states(evaluatedAt)
          .singleWhere((state) => state.name == 'unknown');
      await tester.pumpWidget(
        _phone(1, SyncHealthHeader(health: unknown.health)),
      );
      await tester.tap(find.byKey(const Key('sync-health-details')));
      await tester.pumpAndSettle();
      expect(
        find.text('Failed: Sync could not finish. Cause unknown'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Axiotask could not identify the cause. Diagnostics list the '
          'events around this failure.',
        ),
        findsOneWidget,
      );
      expect(find.text('Reference: synthetic.unclassified'), findsOneWidget);
      expect(find.text('1 change could not be sent.'), findsOneWidget);
      expect(find.text('2026-08-22 10:00 UTC'), findsOneWidget);
    });

    testWidgets('the header follows each reported state change', (
      tester,
    ) async {
      _useView(tester, 360);
      final states = {
        for (final state in _states(evaluatedAt)) state.name: state,
      };
      Future<void> show(String name) => tester.pumpWidget(
        _phone(
          1,
          SyncHealthHeader(
            health: states[name]!.health,
            onAction: (_) {},
            iconOnly: true,
          ),
        ),
      );

      await show('offline');
      expect(find.text('Failed · No connection'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      await show('retrying');
      expect(find.text('Pending · Retrying synchronization'), findsOneWidget);
      expect(find.textContaining('No connection'), findsNothing);
      expect(find.byKey(const Key('sync-health-action')), findsNothing);
      await show('pending');
      expect(find.byKey(const Key('sync-health-banner')), findsNothing);
      expect(find.byKey(const Key('sync-health-pending')), findsOneWidget);
      expect(find.byKey(const Key('sync-health-good')), findsNothing);
      await show('healthy');
      expect(find.byKey(const Key('sync-health-good')), findsOneWidget);
      expect(find.byKey(const Key('sync-health-pending')), findsNothing);
      await show('exhausted');
      expect(find.text('Failed · Automatic retry exhausted'), findsOneWidget);
      expect(find.byKey(const Key('sync-health-good')), findsNothing);
    });
  });
}

const _viewHeight = 800.0;

final _sensitive = RegExp(
  r'token|bearer|secret|password|https?:|@|\{|stack',
  caseSensitive: false,
);

void _useView(WidgetTester tester, double width) {
  tester.view.physicalSize = Size(width, _viewHeight);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// A phone-shaped host: the header above a task list, as the shell lays out.
Widget _phone(double textScale, Widget header) => MaterialApp(
  theme: ThemeData(
    platform: TargetPlatform.android,
    fontFamily: androidTextFontFamily,
  ),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Align(alignment: Alignment.centerRight, child: header),
            Expanded(
              child: ListView(
                children: const <Widget>[ListTile(title: Text('First task'))],
              ),
            ),
          ],
        ),
      ),
    ),
  ),
);

final class _State {
  const _State(
    this.name,
    this.health, {
    this.compact = false,
    this.headline = '',
    this.explanation = '',
    this.action,
  });

  final String name;
  final SyncHealth health;
  final bool compact;
  final String headline;
  final String explanation;
  final SyncHealthAction? action;

  /// The banner headline: the outcome word, then the reason.
  String get headlineText => '${health.summary} · $headline';
}

List<_State> _states(DateTime now) {
  final lastSuccess = now.subtract(const Duration(hours: 2));
  SyncHealth make(
    SyncHealthOutcome outcome, {
    SyncInactiveReason? inactive,
    SyncFailureReason? failure,
    SyncPendingReason? pending,
    SyncHealthAction action = SyncHealthAction.none,
    SyncWorkCounts counts = const SyncWorkCounts(pending: 1),
    DateTime? success,
    String? code,
    DateTime? retryAt,
    bool exhausted = false,
  }) => SyncHealth(
    outcome: outcome,
    inactiveReason: inactive,
    failureReason: failure,
    pendingReason: pending,
    action: action,
    counts: counts,
    lastSuccessfulSyncAt: success ?? lastSuccess,
    evaluatedAt: now,
    diagnosticCode: code,
    retryNextAttemptAt: retryAt,
    retryAttemptCount: retryAt == null ? 0 : 2,
    automaticRetryExhausted: exhausted,
  );
  const saved = '1 change saved on this device, not yet on Google.';
  return <_State>[
    _State(
      'healthy',
      make(
        SyncHealthOutcome.good,
        counts: const SyncWorkCounts(),
        success: now.subtract(const Duration(minutes: 1)),
      ),
      compact: true,
    ),
    _State(
      'pending',
      make(
        SyncHealthOutcome.pending,
        pending: SyncPendingReason.localChanges,
        success: now.subtract(const Duration(seconds: 20)),
      ),
      compact: true,
    ),
    _State(
      'offline',
      make(
        SyncHealthOutcome.failed,
        failure: SyncFailureReason.noConnection,
        action: SyncHealthAction.retry,
      ),
      headline: 'No connection',
      explanation: '$saved Changes sync when this device is back online.',
      action: SyncHealthAction.retry,
    ),
    _State(
      'stale',
      make(
        SyncHealthOutcome.failed,
        failure: SyncFailureReason.stale,
        action: SyncHealthAction.retry,
        counts: const SyncWorkCounts(),
      ),
      headline: 'Cached data is stale',
      explanation: 'Refresh to check Google for changes.',
      action: SyncHealthAction.retry,
    ),
    _State(
      'retrying',
      make(SyncHealthOutcome.pending, pending: SyncPendingReason.retrying),
      headline: 'Retrying synchronization',
      explanation: '$saved Trying Google Tasks again now.',
    ),
    _State(
      'retry_waiting',
      make(
        SyncHealthOutcome.failed,
        failure: SyncFailureReason.remoteFailure,
        action: SyncHealthAction.retry,
        retryAt: now.add(const Duration(seconds: 30)),
      ),
      headline: 'Retry 3 after 12:00:30 UTC',
      explanation: '$saved Axiotask retries automatically, or retry now.',
      action: SyncHealthAction.retry,
    ),
    _State(
      'exhausted',
      make(
        SyncHealthOutcome.failed,
        failure: SyncFailureReason.remoteFailure,
        action: SyncHealthAction.retry,
        exhausted: true,
      ),
      headline: 'Automatic retry exhausted',
      explanation: '$saved Google Tasks kept failing. Retry when ready.',
      action: SyncHealthAction.retry,
    ),
    _State(
      'remote',
      make(
        SyncHealthOutcome.failed,
        failure: SyncFailureReason.remoteFailure,
        action: SyncHealthAction.retry,
        code: 'google_tasks.remote_unavailable',
      ),
      headline: 'Google Tasks is temporarily unavailable',
      explanation: '$saved Retry later.',
      action: SyncHealthAction.retry,
    ),
    _State(
      'paused',
      make(
        SyncHealthOutcome.inactive,
        inactive: SyncInactiveReason.syncStopped,
        action: SyncHealthAction.resume,
      ),
      headline: 'Sync stopped',
      explanation: '$saved Resume sync to send changes to Google.',
      action: SyncHealthAction.resume,
    ),
    _State(
      'reauthorize',
      make(
        SyncHealthOutcome.inactive,
        inactive: SyncInactiveReason.noAuthorization,
        action: SyncHealthAction.reauthorize,
      ),
      headline: 'No authorization',
      explanation:
          '$saved Google access ended. Reauthorize to continue syncing.',
      action: SyncHealthAction.reauthorize,
    ),
    _State(
      'connect',
      make(
        SyncHealthOutcome.inactive,
        inactive: SyncInactiveReason.noAuthorization,
        action: SyncHealthAction.connect,
        counts: const SyncWorkCounts(),
      ),
      headline: 'No authorization',
      explanation: 'Connect a Google account to sync.',
      action: SyncHealthAction.connect,
    ),
    _State(
      'configuration',
      make(
        SyncHealthOutcome.failed,
        failure: SyncFailureReason.applicationFailure,
        counts: const SyncWorkCounts(),
        code: 'auth.configuration',
      ),
      headline: 'Google connection configuration needs repair',
      explanation: 'Open diagnostics for the reference code.',
    ),
    _State(
      'hierarchy',
      make(
        SyncHealthOutcome.failed,
        failure: SyncFailureReason.applicationFailure,
        counts: const SyncWorkCounts(),
        code: 'sync.unsupported_task_depth',
      ),
      headline: 'A task has too many nested subtasks',
      explanation:
          'Move the deepest subtask up a level in Google Tasks, then retry.',
    ),
    _State(
      'unknown',
      make(
        SyncHealthOutcome.failed,
        failure: SyncFailureReason.applicationFailure,
        action: SyncHealthAction.retry,
        counts: const SyncWorkCounts(failed: 1),
        code: 'synthetic.unclassified',
      ),
      headline: 'Sync could not finish. Cause unknown',
      explanation:
          '1 change could not be sent. Retry, or open details for the '
          'reference code.',
      action: SyncHealthAction.retry,
    ),
  ];
}

String _actionLabel(SyncHealthAction action) => switch (action) {
  SyncHealthAction.none => '',
  SyncHealthAction.connect => 'Connect',
  SyncHealthAction.reauthorize => 'Reauthorize',
  SyncHealthAction.resume => 'Resume',
  SyncHealthAction.retry => 'Retry',
};

/// Whether the [Text] found by [finder] laid out without being cut off.
bool _whole(WidgetTester tester, Finder finder) => !tester
    .renderObject<RenderParagraph>(
      find.descendant(of: finder, matching: find.byType(RichText)),
    )
    .didExceedMaxLines;
