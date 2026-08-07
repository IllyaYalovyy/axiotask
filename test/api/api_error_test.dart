// Port of `api/error.rs`'s in-file tests. Protects the transient-vs-terminal
// classification the sync engine and scheduler branch on: mis-classifying a
// terminal error as transient would loop forever; mis-classifying a transient
// one as terminal would mass-reject pending changes during a burst.

import 'package:axiotask/src/api/api_error.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApiError.isTransient', () {
    test('exactly RateLimited / ServerError / Network are transient', () {
      // Transient — worth retrying after a short delay.
      expect(const ServerError(503).isTransient, isTrue);
      expect(const RateLimited().isTransient, isTrue);
      expect(const Network('connect refused').isTransient, isTrue);

      // Terminal — retrying cannot help.
      expect(const Unauthorized().isTransient, isFalse);
      expect(const AuthExpired('invalid_grant').isTransient, isFalse);
      expect(const NotFound().isTransient, isFalse);
      expect(const PreconditionFailed().isTransient, isFalse);
      expect(const OtherApiError('bad json').isTransient, isFalse);
    });

    test('variants carry their payloads and compare by value', () {
      expect(const AuthExpired('x'), const AuthExpired('x'));
      expect(const AuthExpired('x'), isNot(const AuthExpired('y')));
      expect(const ServerError(500), isNot(const ServerError(503)));
      expect(const Network('a'), const Network('a'));
    });
  });
}
