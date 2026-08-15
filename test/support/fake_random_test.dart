import 'package:flutter_test/flutter_test.dart';

import 'fake_random.dart';

void main() {
  group('FakeRandom qualification', () {
    test('scripted full jitter selects exact replayable boundaries', () {
      final random = FakeRandom.scriptedJitter(<Duration>[
        Duration.zero,
        const Duration(seconds: 4),
        const Duration(milliseconds: 125),
      ]);

      expect(random.fullJitter(const Duration(seconds: 4)), Duration.zero);
      expect(
        random.fullJitter(const Duration(seconds: 4)),
        const Duration(seconds: 4),
      );
      expect(
        random.fullJitter(const Duration(seconds: 1)),
        const Duration(milliseconds: 125),
      );
      expect(
        () => random.fullJitter(const Duration(seconds: 1)),
        throwsStateError,
      );
    });

    test('fixed seeds replay bytes and jitter exactly', () {
      final first = FakeRandom.seeded(1907);
      final replay = FakeRandom.seeded(1907);

      final firstTrace = <Object>[
        first.nextBytes(7),
        first.fullJitter(const Duration(seconds: 2)),
        first.nextBytes(3),
      ];
      final replayTrace = <Object>[
        replay.nextBytes(7),
        replay.fullJitter(const Duration(seconds: 2)),
        replay.nextBytes(3),
      ];

      expect(replayTrace, firstTrace);
    });

    test('script rejects jitter outside the requested bound', () {
      final random = FakeRandom.scriptedJitter(<Duration>[
        const Duration(seconds: 2),
      ]);

      expect(
        () => random.fullJitter(const Duration(seconds: 1)),
        throwsArgumentError,
      );
    });
  });
}
