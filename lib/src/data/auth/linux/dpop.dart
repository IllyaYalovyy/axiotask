import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:jose/jose.dart';

import '../../../core/clock.dart';
import '../../../core/randomness.dart';

final class DpopProtocolException implements Exception {
  const DpopProtocolException(this.code);

  final String code;

  @override
  String toString() => 'DpopProtocolException($code)';
}

final class DpopKeyPair {
  DpopKeyPair._(this._key);

  factory DpopKeyPair.generate() {
    final key = JsonWebKey.generate('ES256');
    return DpopKeyPair.fromPrivateJwkJson(jsonEncode(key.toJson()));
  }

  factory DpopKeyPair.fromPrivateJwkJson(String encoded) {
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, dynamic> ||
          decoded['kty'] != 'EC' ||
          decoded['crv'] != 'P-256' ||
          decoded['x'] is! String ||
          decoded['y'] is! String ||
          decoded['d'] is! String ||
          (decoded['x'] as String).isEmpty ||
          (decoded['y'] as String).isEmpty ||
          (decoded['d'] as String).isEmpty ||
          (decoded['alg'] != null && decoded['alg'] != 'ES256')) {
        throw const FormatException('Invalid DPoP private key.');
      }
      final key = JsonWebKey.fromJson(decoded);
      if (!key.usableForAlgorithm('ES256') || !key.usableForOperation('sign')) {
        throw const FormatException('Invalid DPoP private key.');
      }
      return DpopKeyPair._(key);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid DPoP private key.');
    }
  }

  final JsonWebKey _key;

  String get privateJwkJson => jsonEncode(_key.toJson());

  Map<String, dynamic> get publicJwk => <String, dynamic>{
    'kty': _key['kty'] as String,
    'crv': _key['crv'] as String,
    'x': _key['x'] as String,
    'y': _key['y'] as String,
  };

  JsonWebKey get signingKey => _key;

  @override
  String toString() => 'DpopKeyPair(<redacted>)';
}

sealed class DpopExchange {
  const DpopExchange();
}

final class DpopAuthorizationCodeExchange extends DpopExchange {
  const DpopAuthorizationCodeExchange(this.authorizationCode);

  final String authorizationCode;
}

final class DpopRefreshExchange extends DpopExchange {
  const DpopRefreshExchange();
}

String authorizationCodeJti(String authorizationCode) =>
    _base64UrlNoPadding(sha256.convert(utf8.encode(authorizationCode)).bytes);

final class DpopProofFactory {
  factory DpopProofFactory({
    required DpopKeyPair key,
    required Clock clock,
    required RandomSource randomness,
  }) => DpopProofFactory._(key, clock, randomness);

  const DpopProofFactory._(this._key, this._clock, this._randomness);

  final DpopKeyPair _key;
  final Clock _clock;
  final RandomSource _randomness;

  String create({
    required Uri endpoint,
    required String method,
    required DpopExchange exchange,
    String? nonce,
  }) {
    if (endpoint.scheme != 'https' || endpoint.host.isEmpty) {
      throw const DpopProtocolException('dpop.endpoint_invalid');
    }
    final normalizedEndpoint = Uri(
      scheme: endpoint.scheme,
      userInfo: endpoint.userInfo,
      host: endpoint.host,
      port: endpoint.hasPort ? endpoint.port : null,
      path: endpoint.path,
    );
    final jti = switch (exchange) {
      DpopAuthorizationCodeExchange(:final authorizationCode) =>
        authorizationCodeJti(authorizationCode),
      DpopRefreshExchange() => _base64UrlNoPadding(_randomness.nextBytes(16)),
    };
    final claims = <String, Object>{
      'jti': jti,
      'htm': method.toUpperCase(),
      'htu': normalizedEndpoint.toString(),
      'iat': _clock.now().toUtc().millisecondsSinceEpoch ~/ 1000,
      'nonce': ?nonce,
    };
    final builder = JsonWebSignatureBuilder()
      ..jsonContent = claims
      ..setProtectedHeader('typ', 'dpop+jwt')
      ..setProtectedHeader('jwk', _key.publicJwk)
      ..addRecipient(_key.signingKey, algorithm: 'ES256');
    return builder.build().toCompactSerialization();
  }
}

final class DpopTokenClient extends http.BaseClient {
  factory DpopTokenClient({
    required http.Client inner,
    required Uri tokenEndpoint,
    required DpopProofFactory proofs,
  }) => DpopTokenClient._(inner, tokenEndpoint, proofs);

  DpopTokenClient._(this._inner, this._tokenEndpoint, this._proofs);

  final http.Client _inner;
  final Uri _tokenEndpoint;
  final DpopProofFactory _proofs;
  String? _nonce;

  String? get currentNonce => _nonce;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url != _tokenEndpoint) {
      return _inner.send(request);
    }
    if (request is! http.Request || request.method != 'POST') {
      throw const DpopProtocolException('dpop.token_request_invalid');
    }
    final bodyBytes = request.bodyBytes;
    final fields = Uri.splitQueryString(utf8.decode(bodyBytes));
    final exchange = switch (fields['grant_type']) {
      'authorization_code' when fields['code'] != null =>
        DpopAuthorizationCodeExchange(fields['code']!),
      'refresh_token' => const DpopRefreshExchange(),
      _ => throw const DpopProtocolException('dpop.grant_type_invalid'),
    };

    var response = await _sendOnce(request, bodyBytes, exchange);
    if (_isNonceChallenge(response) && _nonce != null) {
      response = await _sendOnce(request, bodyBytes, exchange);
    }
    return _toStreamedResponse(response);
  }

  Future<http.Response> _sendOnce(
    http.Request source,
    List<int> bodyBytes,
    DpopExchange exchange,
  ) async {
    final attempt = http.Request(source.method, source.url)
      ..followRedirects = source.followRedirects
      ..maxRedirects = source.maxRedirects
      ..persistentConnection = source.persistentConnection
      ..headers.addAll(source.headers)
      ..headers['dpop'] = _proofs.create(
        endpoint: source.url,
        method: source.method,
        exchange: exchange,
        nonce: _nonce,
      )
      ..bodyBytes = bodyBytes;
    final response = await http.Response.fromStream(await _inner.send(attempt));
    final nextNonce = response.headers['dpop-nonce'];
    if (nextNonce != null && nextNonce.isNotEmpty && nextNonce.length <= 4096) {
      _nonce = nextNonce;
    }
    return response;
  }

  bool _isNonceChallenge(http.Response response) {
    if (response.statusCode != 400 || response.headers['dpop-nonce'] == null) {
      return false;
    }
    try {
      final body = jsonDecode(response.body);
      return body is Map<String, dynamic> && body['error'] == 'use_dpop_nonce';
    } on FormatException {
      return false;
    }
  }

  http.StreamedResponse _toStreamedResponse(http.Response response) =>
      http.StreamedResponse(
        http.ByteStream.fromBytes(response.bodyBytes),
        response.statusCode,
        contentLength: response.contentLength,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
        request: response.request,
      );

  @override
  void close() {
    _inner.close();
  }
}

String _base64UrlNoPadding(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');
