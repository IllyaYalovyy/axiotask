import 'package:axiotask/src/domain/policy/delete_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final acknowledgedAt = DateTime.utc(2026, 8, 15, 12);

  test('task delete grace is exactly thirty seconds', () {
    const policy = TaskDeletePolicy();
    final notBefore = policy.notBefore(acknowledgedAt);

    expect(notBefore, acknowledgedAt.add(const Duration(seconds: 30)));
    expect(
      policy.isUndoAvailable(
        now: notBefore.subtract(const Duration(milliseconds: 1)),
        notBefore: notBefore,
      ),
      isTrue,
    );
    expect(
      policy.isDispatchEligible(
        now: notBefore.subtract(const Duration(milliseconds: 1)),
        notBefore: notBefore,
      ),
      isFalse,
    );
    expect(
      policy.isUndoAvailable(now: notBefore, notBefore: notBefore),
      isFalse,
    );
    expect(
      policy.isDispatchEligible(now: notBefore, notBefore: notBefore),
      isTrue,
    );
  });
}
