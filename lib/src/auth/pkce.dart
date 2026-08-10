// PKCE (Proof Key for Code Exchange) primitives — the port of `auth/pkce.rs`.
// Pure, no IO. The desktop loopback flow consumes these; googleapis_auth does
// the token exchange, but the challenge/verifier and CSRF state stay ours so
// the flow keeps the exact shape the reference verified against Google.

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// A generated PKCE verifier and the derived S256 challenge.
class Pkce {
  const Pkce({required this.verifier, required this.challenge});

  /// High-entropy verifier the client keeps secret until the token exchange.
  final String verifier;

  /// `S256(verifier)`, base64url without padding.
  final String challenge;

  /// The challenge method literal — always `S256` here.
  static const String method = 'S256';

  /// Generate a fresh verifier (32 bytes of entropy → 43-char base64url) and its
  /// S256 challenge. Uses [Random.secure]; a caller may inject a seeded [rng]
  /// for deterministic tests.
  factory Pkce.generate([Random? rng]) {
    final random = rng ?? Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final verifier = base64UrlEncode(bytes).replaceAll('=', '');
    return Pkce(verifier: verifier, challenge: challengeFor(verifier));
  }

  /// Derive the challenge for a given verifier. Public so tests can pin the
  /// RFC 7636 §4.6 test vector.
  static String challengeFor(String verifier) {
    final digest = sha256.convert(ascii.encode(verifier));
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }
}

/// Generate a random CSRF `state` token (24 bytes → base64url without padding).
String randomState([Random? rng]) {
  final random = rng ?? Random.secure();
  final bytes = List<int>.generate(24, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}
