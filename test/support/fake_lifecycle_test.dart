import 'package:axiotask/src/app/lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_lifecycle.dart';

void main() {
  group('FakeLifecycle qualification', () {
    test('drives foreground and background facts through the port', () {
      final LifecyclePort lifecycle = FakeLifecycle();
      final fake = lifecycle as FakeLifecycle;
      addTearDown(fake.close);
      final events = <LifecycleFact>[];
      lifecycle.facts.listen(events.add);

      fake.enterBackground();
      expect(lifecycle.currentEligibility, LifecycleEligibility.background);
      fake.acknowledgeCancellation();
      fake.enterForeground();
      expect(lifecycle.currentEligibility, LifecycleEligibility.foreground);
      expect(events, <LifecycleFact>[
        const LifecycleBackgrounded(),
        const LifecycleForegrounded(),
      ]);
    });

    test('Linux focus changes never change process eligibility', () {
      final fake = FakeLifecycle();
      addTearDown(fake.close);
      final events = <LifecycleFact>[];
      fake.facts.listen(events.add);

      fake.setWindowFocused(false);
      fake.setWindowFocused(true);

      expect(fake.currentEligibility, LifecycleEligibility.foreground);
      expect(events, <LifecycleFact>[
        const WindowFocusChanged(isFocused: false),
        const WindowFocusChanged(isFocused: true),
      ]);
    });

    test(
      'process exit can be requested or happen without a callback',
      () async {
        final requested = FakeLifecycle();
        addTearDown(requested.close);
        final requestedEvents = <LifecycleFact>[];
        requested.facts.listen(requestedEvents.add);

        expect(requested.requestProcessExit(), isTrue);
        expect(requested.requestProcessExit(), isFalse);
        expect(requested.exitRequested, isTrue);
        expect(requestedEvents, <LifecycleFact>[const ProcessExitRequested()]);
        requested.acknowledgeCancellation();
        await requested.whenCancellationAcknowledged;

        final abrupt = FakeLifecycle();
        final abruptEvents = <LifecycleFact>[];
        final done = abrupt.facts.listen(abruptEvents.add).asFuture<void>();
        abrupt.terminateWithoutExitFact();
        await done;
        expect(abrupt.exitRequested, isFalse);
        expect(abruptEvents, isEmpty);
      },
    );

    test('fails itself when driven after process termination', () {
      final fake = FakeLifecycle()..terminateWithoutExitFact();

      expect(fake.enterForeground, throwsStateError);
      expect(() => fake.setWindowFocused(false), throwsStateError);
      expect(fake.requestProcessExit, throwsStateError);
    });

    test(
      'fails itself on missing or overlapping cancellation acknowledgement',
      () {
        final fake = FakeLifecycle();
        addTearDown(fake.close);

        expect(() => fake.whenCancellationAcknowledged, throwsStateError);
        fake.enterBackground();
        expect(fake.requestProcessExit, throwsStateError);
        fake.acknowledgeCancellation();
        expect(fake.acknowledgeCancellation, throwsStateError);
      },
    );
  });
}
