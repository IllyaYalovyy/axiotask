import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../flutter_test_config.dart';

/// The golden comparator must ignore rendering noise and still fail on a
/// real change, or goldens either cry wolf or protect nothing.
void main() {
  late Directory directory;
  late TolerantGoldenFileComparator comparator;

  Future<Uint8List> image({int changedPixels = 0, int size = 100}) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    for (var index = 0; index < changedPixels; index += 1) {
      canvas.drawRect(
        ui.Rect.fromLTWH(
          (index % size).toDouble(),
          (index ~/ size).toDouble(),
          1,
          1,
        ),
        ui.Paint()..color = const ui.Color(0xFF000000),
      );
    }
    final rendered = await recorder.endRecording().toImage(size, size);
    final bytes = await rendered.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('axiotask-golden-');
    comparator = TolerantGoldenFileComparator(
      Uri.file('${directory.path}/placeholder_test.dart'),
      tolerance: 0.01,
    );
    File('${directory.path}/golden.png').writeAsBytesSync(await image());
  });

  tearDown(() => directory.deleteSync(recursive: true));

  test('an identical image passes', () async {
    expect(
      await comparator.compare(await image(), Uri.parse('golden.png')),
      isTrue,
    );
  });

  test('rendering noise within the tolerance passes', () async {
    // 50 of 10,000 pixels: 0.5%.
    expect(
      await comparator.compare(
        await image(changedPixels: 50),
        Uri.parse('golden.png'),
      ),
      isTrue,
    );
  });

  test('a real visual change fails', () async {
    // 500 of 10,000 pixels: 5%.
    await expectLater(
      comparator.compare(
        await image(changedPixels: 500),
        Uri.parse('golden.png'),
      ),
      throwsA(isA<FlutterError>()),
    );
  });

  test('a size change is never treated as noise', () async {
    await expectLater(
      comparator.compare(await image(size: 101), Uri.parse('golden.png')),
      throwsA(isA<FlutterError>()),
    );
  });

  test('the default tolerance is a small fraction', () {
    expect(defaultGoldenTolerance, greaterThan(0));
    expect(defaultGoldenTolerance, lessThanOrEqualTo(0.02));
  });
}
