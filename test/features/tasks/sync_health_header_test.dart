import 'package:axiotask/src/features/tasks/widgets/sync_health_header.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
        'Last successful sync 2026-08-22 11:58 UTC (2 minutes ago). '
        'No unresolved changes. Open synchronization details.',
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
        expect(find.text(reason), findsOneWidget);
        expect(find.text('1 unresolved'), findsOneWidget);
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
    expect(find.text('Sync stopped'), findsOneWidget);
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
    expect(find.text('Cached data is stale'), findsOneWidget);
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
}

String _actionLabel(SyncHealthAction action) => switch (action) {
  SyncHealthAction.none => '',
  SyncHealthAction.connect => 'Connect',
  SyncHealthAction.reauthorize => 'Reauthorize',
  SyncHealthAction.resume => 'Resume',
  SyncHealthAction.retry => 'Retry',
};
