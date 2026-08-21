import 'package:axiotask/src/data/links/url_launcher_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hands a URL to the external-application launcher', () async {
    final opened = <Uri>[];
    final launcher = UrlLauncherAdapter(
      starter: (uri) async {
        opened.add(uri);
        return true;
      },
    );
    final uri = Uri.parse('https://example.test/synthetic');

    expect(await launcher.launch(uri), isTrue);
    expect(opened, <Uri>[uri]);
  });

  test('reports false and platform exceptions as launch failures', () async {
    final denied = UrlLauncherAdapter(starter: (_) async => false);
    final failed = UrlLauncherAdapter(
      starter: (_) async => throw PlatformException(code: 'launch-failed'),
    );
    final uri = Uri.parse('https://example.test/synthetic');

    expect(await denied.launch(uri), isFalse);
    expect(await failed.launch(uri), isFalse);
  });
}
