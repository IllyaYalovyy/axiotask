// Sync-status subset of the Android behavior manifest (manifest.json).
//
// Audit case 18 found that one ordinary local edit right after a successful
// sync replaced the compact header status with a large "Pending" banner. The
// tracked finding `failure-message-usability` found that a failure showed a
// large panel reading "Sync could not finish" without saying what failed.
//
// Case 18 drives a real edit by touch over the isolated SQLite fixture and
// lets the production health projection read the fixture's durable facts.
// The status must stay one compact header control that never claims
// synchronization while the change awaits Google, both while the edit is
// queued and while the run that publishes it verifies with Google, keep the
// task list where it was, and open details that separate local persistence
// from Google confirmation. `failure-message-usability` renders every failure, retry,
// pause and authorization state at phone widths and 2x text, and requires a
// specific explanation (or a stated unknown cause), a bounded banner, and a
// recovery action that reaches the matching coordinator port by touch and is
// followed by the state the coordinator reports.
// Run through tool/android_regression/runner.dart.
import 'dart:async';

import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/data/database/sync_health_dao.dart';
import 'package:axiotask/src/data/database/sync_health_repository.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../test/support/touch_targets.dart';
import 'support/regression_harness.dart';

void main() {
  ensureRegressionBinding();

  regressionCase('18_routine_local_edit_feedback', phoneOnHost: true, (
    t,
    f,
  ) async {
    final dao = SyncHealthDao(f.database);
    await dao.writeFacts(
      f.account,
      PersistedSyncFacts(
        lastSuccessfulSyncAt: regressionNow.subtract(
          const Duration(seconds: 30),
        ),
      ),
    );
    // Stands in for the coordinator's runtime facts: idle, then the routine
    // run that publishes the edit.
    final runtime = _ControlledRuntimeFacts(
      const SyncRuntimeFacts(authorization: SyncAuthorization.usable),
    );
    addTearDown(runtime.close);
    await f.health.follow(
      DatabaseSyncHealthRepository(
        dao: dao,
        clock: f.clock,
        runtime: runtime,
      ).watchHealth(f.account),
    );
    await settleUntil(
      t,
      () => f.model.state.health.outcome == SyncHealthOutcome.good,
      description: 'the verified sync to project Good',
    );
    expect(find.byKey(const Key('sync-health-good')).hitTestable(), findsOne);
    final rowTop = t.getTopLeft(f.row(f.parent));
    final header = t.getRect(
      find.byKey(const Key('desktop-application-header')),
    );
    await f.capture(t, 'normal');

    // One ordinary local edit, by touch.
    await t.tap(
      find.descendant(
        of: f.row(f.second),
        matching: find.byTooltip('Complete task'),
      ),
    );
    await settleUntil(
      t,
      () async => (await f.task(f.second)).status == TaskStatus.completed,
      description: 'the completion to persist in SQLite',
    );
    await settleUntil(
      t,
      () => f.model.state.health.counts.pendingConfirmation == 1,
      description: 'one change to await Google',
    );
    expect(
      await DesiredStateDao(f.database).readTask(f.account, f.second),
      isNotNull,
      reason: 'The edit is stored locally for publication',
    );
    final health = f.model.state.health;
    expect(health.outcome, SyncHealthOutcome.pending);
    expect(health.pendingReason, SyncPendingReason.localChanges);
    expect(health.counts, const SyncWorkCounts(pending: 1));

    expect(
      find.textContaining('Pending').hitTestable(),
      findsNothing,
      reason:
          'Ordinary edits must not replace the compact sync status with a '
          'large banner',
    );
    expect(find.byKey(const Key('sync-health-banner')), findsNothing);
    expect(
      find.text('Synced'),
      findsNothing,
      reason: 'Never claim synchronization while work remains',
    );
    final status = find.byKey(const Key('sync-health-pending'));
    expect(status.hitTestable(), findsOneWidget);
    expect(find.byKey(const Key('sync-health-good')), findsNothing);
    expect(
      find.descendant(of: status, matching: find.text('1')),
      findsOneWidget,
      reason: 'The compact status shows the unconfirmed count',
    );
    expectTouchTarget(
      t,
      status,
      label: '1 change saved on this device, not yet on Google.',
    );
    final announced = t.getSemantics(status).getSemanticsData().label;
    expect(announced, contains('Synchronization Pending'));
    expect(announced, contains('Last successful sync 2026-11-15 11:59 UTC'));
    expect(announced, isNot(contains('Synced')));
    // The only thing above the list that the edit added is its own
    // completion Undo bar; sync status took no room.
    expect(
      t.getRect(find.byKey(const Key('desktop-application-header'))),
      header,
    );
    expect(
      t.getTopLeft(f.row(f.parent)).dy - rowTop.dy,
      t.getSize(find.byKey(const Key('task-completion-undo'))).height,
      reason: 'The task list keeps its place',
    );
    await f.capture(t, 'pending');

    // Detail access separates local persistence from Google confirmation.
    await t.tap(status);
    await t.pumpAndSettle();
    expect(find.text('Synchronization details'), findsOneWidget);
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
    expect(find.text('2026-11-15 11:59 UTC'), findsOneWidget);
    await f.capture(t, 'pending_details');
    await t.tap(find.text('Close'));
    await t.pumpAndSettle();

    // The routine run that publishes the edit verifies with Google while the
    // change is still unconfirmed; the status stays compact and truthful.
    runtime.emit(
      const SyncRuntimeFacts(
        authorization: SyncAuthorization.usable,
        activity: SyncActivity.verifying,
        verificationRequired: true,
      ),
    );
    await settleUntil(
      t,
      () => f.model.state.health.pendingReason == SyncPendingReason.verifying,
      description: 'the publishing run to verify with Google',
    );
    expect(f.model.state.health.counts, const SyncWorkCounts(pending: 1));
    expect(find.textContaining('Pending').hitTestable(), findsNothing);
    expect(find.byKey(const Key('sync-health-banner')), findsNothing);
    expect(find.text('Synced'), findsNothing);
    expect(
      find.descendant(of: status, matching: find.text('1')),
      findsOneWidget,
      reason: 'The compact status keeps the unconfirmed count',
    );
    expectTouchTarget(
      t,
      status,
      label: '1 change saved on this device, not yet on Google.',
    );
    expect(
      t.getSemantics(status).getSemanticsData().label,
      isNot(contains('Synced')),
    );
    expect(
      t.getRect(find.byKey(const Key('desktop-application-header'))),
      header,
    );
    expect(
      t.getTopLeft(f.row(f.parent)).dy - rowTop.dy,
      t.getSize(find.byKey(const Key('task-completion-undo'))).height,
      reason: 'The task list keeps its place while the edit is sent',
    );
    await f.capture(t, 'verifying');

    // Compact and reachable at every phone size.
    for (final viewport in selectionViewports) {
      await usePhoneViewport(t, viewport);
      expect(t.takeException(), isNull, reason: '$viewport layout');
      expect(find.byKey(const Key('sync-health-banner')), findsNothing);
      expect(find.textContaining('Pending').hitTestable(), findsNothing);
      expectTouchTarget(
        t,
        status,
        label: '1 change saved on this device, not yet on Google.',
      );
      expect(find.text('Audit parent').hitTestable(), findsOneWidget);
    }
    expect(f.syncControls, isEmpty);
  });

  regressionCase('failure-message-usability', phoneOnHost: true, (t, f) async {
    final cases = _failureCases();
    for (final viewport in <PhoneViewport>[
      const PhoneViewport(320, PhoneOrientation.portrait, 1),
      const PhoneViewport(360, PhoneOrientation.portrait, 1),
      const PhoneViewport(320, PhoneOrientation.portrait, 2),
      const PhoneViewport(443, PhoneOrientation.portrait, 2),
      const PhoneViewport(360, PhoneOrientation.landscape, 1),
      const PhoneViewport(443, PhoneOrientation.landscape, 2),
    ]) {
      await usePhoneViewport(t, viewport);
      for (final state in cases) {
        f.health.set(state.health);
        await t.pumpAndSettle();
        final where = '${state.name} at $viewport';
        expect(t.takeException(), isNull, reason: where);
        await _expectBanner(t, f, state, viewport, where);
      }
    }

    // Each recovery action reaches its own coordinator port by touch, and
    // the banner follows what the coordinator then reports.
    await usePhoneViewport(
      t,
      const PhoneViewport(360, PhoneOrientation.portrait, 1),
    );
    for (final state in cases.where((state) => state.control != null)) {
      f.syncControls.clear();
      f.health.set(state.health);
      await t.pumpAndSettle();
      f.onSyncControl = (_) async => f.health.set(_retrying);
      await t.tap(find.byKey(const Key('sync-health-action')));
      await t.pumpAndSettle();
      expect(f.syncControls, <SyncControl>[state.control!], reason: state.name);
      expect(
        find.text('Pending · Retrying synchronization').hitTestable(),
        findsOneWidget,
        reason: '${state.name} reports the coordinator state',
      );
      expect(
        find.textContaining(state.headline),
        findsNothing,
        reason: state.name,
      );
      f.onSyncControl = null;
    }

    // Recovery that succeeds returns to the compact healthy status.
    f.health.set(_good);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('sync-health-banner')), findsNothing);
    expect(find.byKey(const Key('sync-health-good')).hitTestable(), findsOne);

    // Unknown failures state the uncertainty and point to useful details.
    f.health.set(cases.singleWhere((state) => state.name == 'unknown').health);
    await t.pumpAndSettle();
    await f.capture(t, 'failure');
    await t.tap(find.byKey(const Key('sync-health-details')));
    await t.pumpAndSettle();
    expect(
      find.text('Failed: Sync could not finish. Cause unknown'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Axiotask could not identify the cause'),
      findsOneWidget,
    );
    expect(find.text('Reference: regression.unspecified_failure'), findsOne);
    expect(find.text('1 change could not be sent.'), findsOneWidget);
    await f.capture(t, 'failure_details');
    await t.tap(find.text('Close'));
    await t.pumpAndSettle();
    for (final task in await f.tasks()) {
      expect(
        await DesiredStateDao(f.database).readTask(f.account, task.id),
        isNull,
        reason: 'Health actions never change stored tasks',
      );
    }
  });
}

final _lastSuccess = regressionNow.subtract(const Duration(hours: 2));

final _good = SyncHealth(
  outcome: SyncHealthOutcome.good,
  counts: const SyncWorkCounts(),
  lastSuccessfulSyncAt: regressionNow,
  evaluatedAt: regressionNow,
);

final _retrying = SyncHealth(
  outcome: SyncHealthOutcome.pending,
  pendingReason: SyncPendingReason.retrying,
  counts: const SyncWorkCounts(pending: 1),
  lastSuccessfulSyncAt: _lastSuccess,
  evaluatedAt: regressionNow,
);

final class _FailureCase {
  const _FailureCase(
    this.name,
    this.health, {
    required this.headline,
    required this.explanation,
    this.action,
    this.control,
  });

  final String name;
  final SyncHealth health;
  final String headline;
  final String explanation;
  final String? action;
  final SyncControl? control;

  /// The banner headline: the outcome word, then the reason.
  String get headlineText => '${health.summary} · $headline';
}

List<_FailureCase> _failureCases() {
  SyncHealth failed(
    SyncFailureReason reason, {
    SyncHealthAction action = SyncHealthAction.retry,
    SyncWorkCounts counts = const SyncWorkCounts(pending: 1),
    String? code,
    DateTime? retryAt,
    bool exhausted = false,
  }) => SyncHealth(
    outcome: SyncHealthOutcome.failed,
    failureReason: reason,
    action: action,
    counts: counts,
    lastSuccessfulSyncAt: _lastSuccess,
    evaluatedAt: regressionNow,
    diagnosticCode: code,
    retryNextAttemptAt: retryAt,
    retryAttemptCount: retryAt == null ? 0 : 2,
    automaticRetryExhausted: exhausted,
  );
  const saved = '1 change saved on this device, not yet on Google.';
  return <_FailureCase>[
    _FailureCase(
      'offline',
      failed(SyncFailureReason.noConnection),
      headline: 'No connection',
      explanation: '$saved Changes sync when this device is back online.',
      action: 'Retry',
      control: SyncControl.retry,
    ),
    _FailureCase(
      'stale',
      failed(SyncFailureReason.stale, counts: const SyncWorkCounts()),
      headline: 'Cached data is stale',
      explanation: 'Refresh to check Google for changes.',
      action: 'Retry',
      control: SyncControl.retry,
    ),
    _FailureCase(
      'retry_waiting',
      failed(
        SyncFailureReason.remoteFailure,
        code: 'google_tasks.rate_limited',
        retryAt: regressionNow.add(const Duration(seconds: 30)),
      ),
      headline: 'Retry 3 after 12:00:30 UTC',
      explanation: '$saved Axiotask retries automatically, or retry now.',
      action: 'Retry',
      control: SyncControl.retry,
    ),
    _FailureCase(
      'retry_exhausted',
      failed(SyncFailureReason.remoteFailure, exhausted: true),
      headline: 'Automatic retry exhausted',
      explanation: '$saved Google Tasks kept failing. Retry when ready.',
      action: 'Retry',
      control: SyncControl.retry,
    ),
    _FailureCase(
      'rate_limited',
      failed(
        SyncFailureReason.remoteFailure,
        code: 'google_tasks.rate_limited',
      ),
      headline: 'Google Tasks is limiting requests',
      explanation: '$saved Retry in a few minutes.',
      action: 'Retry',
      control: SyncControl.retry,
    ),
    _FailureCase(
      'hierarchy',
      failed(
        SyncFailureReason.applicationFailure,
        action: SyncHealthAction.none,
        counts: const SyncWorkCounts(),
        code: 'sync.unsupported_task_depth',
      ),
      headline: 'A task has too many nested subtasks',
      explanation:
          'Move the deepest subtask up a level in Google Tasks, then retry.',
    ),
    _FailureCase(
      'unknown',
      failed(
        SyncFailureReason.applicationFailure,
        counts: const SyncWorkCounts(failed: 1),
        code: 'regression.unspecified_failure',
      ),
      headline: 'Sync could not finish. Cause unknown',
      explanation:
          '1 change could not be sent. Retry, or open details for the '
          'reference code.',
      action: 'Retry',
      control: SyncControl.retry,
    ),
    _FailureCase(
      'paused',
      SyncHealth(
        outcome: SyncHealthOutcome.inactive,
        inactiveReason: SyncInactiveReason.syncStopped,
        action: SyncHealthAction.resume,
        counts: const SyncWorkCounts(pending: 1),
        lastSuccessfulSyncAt: _lastSuccess,
        evaluatedAt: regressionNow,
      ),
      headline: 'Sync stopped',
      explanation: '$saved Resume sync to send changes to Google.',
      action: 'Resume',
      control: SyncControl.resume,
    ),
    _FailureCase(
      'reauthorize',
      SyncHealth(
        outcome: SyncHealthOutcome.inactive,
        inactiveReason: SyncInactiveReason.noAuthorization,
        action: SyncHealthAction.reauthorize,
        counts: const SyncWorkCounts(pending: 1),
        lastSuccessfulSyncAt: _lastSuccess,
        evaluatedAt: regressionNow,
      ),
      headline: 'No authorization',
      explanation:
          '$saved Google access ended. Reauthorize to continue syncing.',
      action: 'Reauthorize',
      control: SyncControl.reauthorize,
    ),
    _FailureCase(
      'retrying',
      _retrying,
      headline: 'Retrying synchronization',
      explanation: '$saved Trying Google Tasks again now.',
    ),
  ];
}

Future<void> _expectBanner(
  WidgetTester t,
  RegressionFixture f,
  _FailureCase state,
  PhoneViewport viewport,
  String where,
) async {
  final banner = find.byKey(const Key('sync-health-banner'));
  expect(banner, findsOneWidget, reason: where);
  final headline = find.byKey(const Key('sync-health-headline'));
  await t.ensureVisible(headline);
  await t.pumpAndSettle();
  expect(
    find.text(state.headlineText).hitTestable(),
    findsOneWidget,
    reason: where,
  );
  final explanation = find.byKey(const Key('sync-health-explanation'));
  expect(t.widget<Text>(explanation).data, state.explanation, reason: where);
  expect(_whole(t, headline), isTrue, reason: '$where headline is whole');
  expect(
    _whole(t, find.byKey(const Key('sync-health-last-success'))),
    isTrue,
    reason: '$where last-success age is whole',
  );
  if (viewport.textScale == 1) {
    expect(_whole(t, explanation), isTrue, reason: '$where explanation');
  }
  final screen = t.view.physicalSize / t.view.devicePixelRatio;
  final rect = t.getRect(banner);
  // At most a quarter of a 1x phone and 40% at 2x text (where the text
  // scrolls inside the banner), and never more than a headline, the
  // explanation, the age and one control row.
  expect(
    rect.height,
    lessThanOrEqualTo(screen.height * (viewport.textScale > 1 ? 0.4 : 0.25)),
    reason: '$where banner $rect stays bounded',
  );
  expect(
    rect.height,
    lessThanOrEqualTo(160 * viewport.textScale),
    reason: '$where banner $rect stays bounded',
  );
  expect(rect.width, lessThanOrEqualTo(screen.width), reason: where);
  expect(
    find.text('Audit parent').hitTestable(),
    findsOneWidget,
    reason: '$where keeps the task list visible',
  );
  final announced = t
      .getSemantics(find.text(state.headlineText))
      .getSemanticsData()
      .label;
  expect(announced, contains(state.headline), reason: where);
  expect(announced, contains(state.explanation), reason: where);
  // The complete feedback region also contains application controls and
  // other banners. At 2x/landscape it scrolls while keeping tasks visible.
  final details = find.byKey(const Key('sync-health-details'));
  await t.ensureVisible(details);
  await t.pumpAndSettle();
  expectTouchTarget(t, details, label: 'Sync details');
  final action = find.byKey(const Key('sync-health-action'));
  if (state.action case final label?) {
    await t.ensureVisible(action);
    await t.pumpAndSettle();
    expectTouchTarget(t, action, label: label);
    expect(
      t.getRect(action).right,
      lessThanOrEqualTo(screen.width),
      reason: where,
    );
  } else {
    expect(action, findsNothing, reason: where);
  }

  // The age is reachable, scrolling the banner's text where it is capped.
  // Wide layouts (landscape) add the exact time.
  final age = find.byKey(const Key('sync-health-last-success'));
  expect(t.widget<Text>(age).data, switch ((
    viewport.textScale > 1,
    screen.width >= 600,
  )) {
    (true, _) => 'Last sync: 2 hours ago',
    (false, true) => 'Last successful sync: 2026-11-15 10:00 UTC (2 hours ago)',
    (false, false) => 'Last successful sync: 2 hours ago',
  }, reason: where);
  await t.ensureVisible(age);
  await t.pumpAndSettle();
  expect(age.hitTestable(), findsOneWidget, reason: where);
}

/// Whether the [Text] found by [finder] laid out without being cut off.
bool _whole(WidgetTester tester, Finder finder) => !tester
    .renderObject<RenderParagraph>(
      find.descendant(of: finder, matching: find.byType(RichText)),
    )
    .didExceedMaxLines;

/// Runtime facts the case drives explicitly, as the coordinator would.
final class _ControlledRuntimeFacts implements SyncRuntimeFactsSource {
  _ControlledRuntimeFacts(this.currentFacts);

  final _changes = StreamController<SyncRuntimeFacts>.broadcast();

  @override
  SyncRuntimeFacts currentFacts;

  @override
  Stream<SyncRuntimeFacts> get facts => _changes.stream;

  void emit(SyncRuntimeFacts next) {
    currentFacts = next;
    _changes.add(next);
  }

  Future<void> close() => _changes.close();
}
