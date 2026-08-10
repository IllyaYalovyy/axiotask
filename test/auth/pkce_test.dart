// PKCE tests — ported from `pkce.rs`. What they protect: the S256 challenge is
// computed correctly (RFC 7636 test vector), verifiers/state are unique and
// meet the RFC length floor, so the desktop consent request Google receives is
// a valid PKCE challenge and the CSRF guard has real entropy.

import 'dart:math';

import 'package:axiotask/src/auth/pkce.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('challenge matches the RFC 7636 §4.6 test vector', () {
    const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
    const expected = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
    expect(Pkce.challengeFor(verifier), expected);
  });

  test('generate produces unique verifiers with a matching challenge', () {
    final a = Pkce.generate();
    final b = Pkce.generate();
    expect(a.verifier, isNot(b.verifier));
    expect(Pkce.method, 'S256');
    expect(Pkce.challengeFor(a.verifier), a.challenge);
  });

  test('verifier meets the RFC length range (43..128)', () {
    final p = Pkce.generate();
    expect(p.verifier.length, greaterThanOrEqualTo(43));
    expect(p.verifier.length, lessThanOrEqualTo(128));
  });

  test('randomState is unique across calls', () {
    expect(randomState(), isNot(randomState()));
  });

  test('an injected seeded rng makes generation deterministic', () {
    // Determinism guard for any future test that needs a fixed challenge.
    final a = Pkce.generate(Random(42));
    final b = Pkce.generate(Random(42));
    expect(a.verifier, b.verifier);
    expect(a.challenge, b.challenge);
  });
}
