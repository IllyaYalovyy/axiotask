final class TaskLinkPolicy {
  const TaskLinkPolicy._();

  static final RegExp _candidate = RegExp(
    r'''https?://[^\s<>"']+''',
    caseSensitive: false,
  );

  static Uri? googleTaskLink(Uri? webViewLink) {
    if (webViewLink == null ||
        webViewLink.scheme.toLowerCase() != 'https' ||
        webViewLink.host.toLowerCase() != 'tasks.google.com' ||
        webViewLink.hasPort ||
        webViewLink.userInfo.isNotEmpty) {
      return null;
    }
    return _safeWebUri(webViewLink.toString());
  }

  static List<Uri> userAuthoredLinks({
    required String title,
    required String? notes,
  }) {
    final result = <Uri>[];
    final seen = <String>{};
    for (final match in _candidate.allMatches('$title\n${notes ?? ''}')) {
      final candidate = _trimPresentationPunctuation(match.group(0)!);
      final uri = _safeWebUri(candidate);
      if (uri != null && seen.add(uri.toString())) result.add(uri);
    }
    return List<Uri>.unmodifiable(result);
  }

  static Uri? safeUserAuthoredLink(Uri uri) => _safeWebUri(uri.toString());

  static Uri? _safeWebUri(String candidate) {
    if (!_hasValidPercentEncoding(candidate)) return null;
    final Uri? uri;
    try {
      uri = Uri.tryParse(candidate);
    } on FormatException {
      return null;
    }
    if (uri == null ||
        !uri.hasScheme ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.scheme.toLowerCase() != 'http' &&
            uri.scheme.toLowerCase() != 'https')) {
      return null;
    }
    return uri;
  }

  static bool _hasValidPercentEncoding(String value) {
    for (var index = 0; index < value.length; index += 1) {
      if (value.codeUnitAt(index) != 0x25) continue;
      if (index + 2 >= value.length ||
          !_isHex(value.codeUnitAt(index + 1)) ||
          !_isHex(value.codeUnitAt(index + 2))) {
        return false;
      }
      index += 2;
    }
    return true;
  }

  static bool _isHex(int codeUnit) =>
      (codeUnit >= 0x30 && codeUnit <= 0x39) ||
      (codeUnit >= 0x41 && codeUnit <= 0x46) ||
      (codeUnit >= 0x61 && codeUnit <= 0x66);

  static String _trimPresentationPunctuation(String value) {
    var result = value;
    while (result.isNotEmpty && '.,;:!?'.contains(result[result.length - 1])) {
      result = result.substring(0, result.length - 1);
    }
    for (final delimiters in const <(String, String)>[
      ('(', ')'),
      ('[', ']'),
      ('{', '}'),
    ]) {
      while (result.endsWith(delimiters.$2) &&
          _count(result, delimiters.$2) > _count(result, delimiters.$1)) {
        result = result.substring(0, result.length - 1);
      }
    }
    return result;
  }

  static int _count(String value, String character) =>
      character.allMatches(value).length;
}
