// TEMPORARY — proves the shared gate can turn a pull request red (#275).
// This file exists only on the throwaway branch `gate-red-demo` and is never
// merged: the acceptance criterion asks for a run in which a deliberately
// failing test makes the GitHub check fail.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('deliberately failing so the gate check goes red (#275)', () {
    expect(1, 2, reason: 'this failure is the point of this branch');
  });
}
