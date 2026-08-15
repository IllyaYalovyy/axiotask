import 'dart:convert';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/randomness.dart';
import 'package:axiotask/src/data/auth/linux/dpop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jose/jose.dart';

void main() {
  group('DPoP', () {
    test(
      'creates verifiable ES256 claims without exposing the private key',
      () async {
        final key = DpopKeyPair.generate();
        final factory = DpopProofFactory(
          key: key,
          clock: ManualClock(DateTime.utc(2026, 8, 14, 12)),
          randomness: SequenceRandomSource(List<int>.generate(64, (i) => i)),
        );

        final proof = factory.create(
          endpoint: Uri.parse('https://oauth2.example.test/token?ignored=yes'),
          method: 'post',
          exchange: const DpopAuthorizationCodeExchange('synthetic-code'),
          nonce: 'nonce-one',
        );
        final signature = JsonWebSignature.fromCompactSerialization(proof);
        final header = signature.unverifiedPayload.protectedHeader!;
        final publicJwk = header['jwk'];
        expect(publicJwk, isA<Map<String, dynamic>>());
        expect((publicJwk as Map<String, dynamic>), isNot(contains('d')));
        expect(header['typ'], 'dpop+jwt');
        expect(header['alg'], 'ES256');

        final store = JsonWebKeyStore()..addKey(JsonWebKey.fromJson(publicJwk));
        expect(await signature.verify(store), isTrue);
        final claims = signature.unverifiedPayload.jsonContent;
        expect(claims['htm'], 'POST');
        expect(claims['htu'], 'https://oauth2.example.test/token');
        expect(claims['iat'], 1786708800);
        expect(claims['nonce'], 'nonce-one');
        expect(claims['jti'], authorizationCodeJti('synthetic-code'));
        expect(key.toString(), isNot(contains(key.privateJwkJson)));
      },
    );

    test('refresh proofs rotate unique jti values and nonce', () {
      final factory = DpopProofFactory(
        key: DpopKeyPair.generate(),
        clock: ManualClock(DateTime.utc(2026, 8, 14)),
        randomness: SequenceRandomSource(List<int>.generate(64, (i) => i)),
      );
      final first = decodeProof(
        factory.create(
          endpoint: Uri.parse('https://oauth2.example.test/token'),
          method: 'POST',
          exchange: const DpopRefreshExchange(),
          nonce: 'nonce-one',
        ),
      );
      final second = decodeProof(
        factory.create(
          endpoint: Uri.parse('https://oauth2.example.test/token'),
          method: 'POST',
          exchange: const DpopRefreshExchange(),
          nonce: 'nonce-two',
        ),
      );
      expect(first['jti'], isNot(second['jti']));
      expect(first['nonce'], 'nonce-one');
      expect(second['nonce'], 'nonce-two');
    });

    test('rejects missing, malformed, and non-P256 private keys', () {
      for (final encoded in <String>[
        '{}',
        jsonEncode(<String, Object>{'kty': 'EC', 'crv': 'P-256'}),
        jsonEncode(JsonWebKey.generate('ES384').toJson()),
      ]) {
        expect(
          () => DpopKeyPair.fromPrivateJwkJson(encoded),
          throwsFormatException,
        );
      }
    });

    test(
      'token client rotates nonce and retries use_dpop_nonce exactly once',
      () async {
        final seenClaims = <Map<String, dynamic>>[];
        var calls = 0;
        final client = DpopTokenClient(
          inner: MockClient((request) async {
            calls += 1;
            final proof = request.headers['dpop'];
            expect(proof, isNotNull);
            seenClaims.add(decodeProof(proof!));
            if (calls == 1) {
              return http.Response(
                '{"error":"use_dpop_nonce"}',
                400,
                headers: <String, String>{'dpop-nonce': 'nonce-rotated'},
              );
            }
            return http.Response(
              '{"access_token":"synthetic-access","token_type":"Bearer","expires_in":3600}',
              200,
              headers: <String, String>{'dpop-nonce': 'nonce-next'},
            );
          }),
          tokenEndpoint: Uri.parse('https://oauth2.example.test/token'),
          proofs: DpopProofFactory(
            key: DpopKeyPair.generate(),
            clock: ManualClock(DateTime.utc(2026, 8, 14)),
            randomness: SequenceRandomSource(List<int>.generate(64, (i) => i)),
          ),
        );

        final response = await client.post(
          Uri.parse('https://oauth2.example.test/token'),
          body: <String, String>{
            'grant_type': 'refresh_token',
            'refresh_token': 'credential-canary-refresh',
          },
        );

        expect(response.statusCode, 200);
        expect(calls, 2);
        expect(seenClaims.first, isNot(contains('nonce')));
        expect(seenClaims.last['nonce'], 'nonce-rotated');
        expect(client.currentNonce, 'nonce-next');
      },
    );

    test(
      'token client rejects a non-token request without forwarding secrets',
      () async {
        var forwarded = false;
        final client = DpopTokenClient(
          inner: MockClient((request) async {
            forwarded = true;
            return http.Response('', 500);
          }),
          tokenEndpoint: Uri.parse('https://oauth2.example.test/token'),
          proofs: DpopProofFactory(
            key: DpopKeyPair.generate(),
            clock: ManualClock(DateTime.utc(2026, 8, 14)),
            randomness: SequenceRandomSource(List<int>.filled(32, 1)),
          ),
        );

        await expectLater(
          client.get(Uri.parse('https://oauth2.example.test/token')),
          throwsA(isA<DpopProtocolException>()),
        );
        expect(forwarded, isFalse);
      },
    );

    test(
      'controlled endpoint rejects a missing or different bound key',
      () async {
        final endpoint = BoundDpopTokenEndpoint();
        final correctClient = DpopTokenClient(
          inner: endpoint,
          tokenEndpoint: Uri.parse('https://oauth2.example.test/token'),
          proofs: DpopProofFactory(
            key: DpopKeyPair.generate(),
            clock: ManualClock(DateTime.utc(2026, 8, 14)),
            randomness: SequenceRandomSource(List<int>.generate(64, (i) => i)),
          ),
        );
        final exchange = await correctClient.post(
          Uri.parse('https://oauth2.example.test/token'),
          body: <String, String>{
            'grant_type': 'authorization_code',
            'code': 'synthetic-code',
          },
        );
        expect(exchange.statusCode, 200);

        final missing = await endpoint.post(
          Uri.parse('https://oauth2.example.test/token'),
          body: <String, String>{
            'grant_type': 'refresh_token',
            'refresh_token': 'credential-canary-refresh',
          },
        );
        expect(missing.statusCode, 400);

        final wrongClient = DpopTokenClient(
          inner: endpoint,
          tokenEndpoint: Uri.parse('https://oauth2.example.test/token'),
          proofs: DpopProofFactory(
            key: DpopKeyPair.generate(),
            clock: ManualClock(DateTime.utc(2026, 8, 14)),
            randomness: SequenceRandomSource(
              List<int>.generate(64, (i) => 255 - i),
            ),
          ),
        );
        final wrong = await wrongClient.post(
          Uri.parse('https://oauth2.example.test/token'),
          body: <String, String>{
            'grant_type': 'refresh_token',
            'refresh_token': 'credential-canary-refresh',
          },
        );
        expect(wrong.statusCode, 400);
        expect(jsonDecode(wrong.body), <String, String>{
          'error': 'invalid_dpop_proof',
        });
      },
    );
  });
}

Map<String, dynamic> decodeProof(String encoded) {
  return JsonWebSignature.fromCompactSerialization(
        encoded,
      ).unverifiedPayload.jsonContent
      as Map<String, dynamic>;
}

final class BoundDpopTokenEndpoint extends http.BaseClient {
  Map<String, dynamic>? _boundPublicKey;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final encodedProof = request.headers['dpop'];
    if (encodedProof == null) {
      return _response('{"error":"invalid_dpop_proof"}', 400);
    }
    final signature = JsonWebSignature.fromCompactSerialization(encodedProof);
    final publicKey = signature.unverifiedPayload.protectedHeader!['jwk'];
    if (publicKey is! Map<String, dynamic>) {
      return _response('{"error":"invalid_dpop_proof"}', 400);
    }
    final store = JsonWebKeyStore()..addKey(JsonWebKey.fromJson(publicKey));
    if (!await signature.verify(store)) {
      return _response('{"error":"invalid_dpop_proof"}', 400);
    }
    final requestBody = request is http.Request ? request.body : '';
    final fields = Uri.splitQueryString(requestBody);
    if (fields['grant_type'] == 'authorization_code') {
      _boundPublicKey = publicKey;
      return _response('{"access_token":"synthetic"}', 200);
    }
    if (jsonEncode(publicKey) != jsonEncode(_boundPublicKey)) {
      return _response('{"error":"invalid_dpop_proof"}', 400);
    }
    return _response('{"access_token":"synthetic"}', 200);
  }

  http.StreamedResponse _response(String body, int statusCode) =>
      http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode(body)),
        statusCode,
        headers: const <String, String>{'content-type': 'application/json'},
      );
}
