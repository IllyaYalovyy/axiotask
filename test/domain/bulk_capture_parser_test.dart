import 'package:axiotask/src/domain/policy/bulk_capture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PAR-CAPTURE-003 bulk capture parsing', () {
    test('line mode trims and skips empty lines', () {
      final preview = parseBulkCapture(
        ' Alpha \r\n\r\n  Beta\nGamma  \n',
        mode: BulkCaptureMode.lines,
      );

      expect(preview.failure, isNull);
      expect(preview.entries, const <BulkCaptureEntry>[
        BulkCaptureEntry(title: 'Alpha'),
        BulkCaptureEntry(title: 'Beta'),
        BulkCaptureEntry(title: 'Gamma'),
      ]);
    });

    test('paragraph mode uses first line as title and remainder as notes', () {
      final preview = parseBulkCapture(
        'Plan trip\nBook flights\nReserve hotel\n\nCall team\nAgenda one\nAgenda two',
        mode: BulkCaptureMode.paragraphs,
      );

      expect(preview.failure, isNull);
      expect(preview.entries, const <BulkCaptureEntry>[
        BulkCaptureEntry(
          title: 'Plan trip',
          notes: 'Book flights\nReserve hotel',
        ),
        BulkCaptureEntry(title: 'Call team', notes: 'Agenda one\nAgenda two'),
      ]);
    });

    test('empty input is invalid', () {
      final preview = parseBulkCapture(' \n\r\n ', mode: BulkCaptureMode.lines);
      expect(preview.entries, isEmpty);
      expect(preview.failure?.code, 'bulk_capture.empty');
    });

    test('more than the bounded task count is invalid as a whole', () {
      final input = List<String>.generate(
        maxBulkCaptureTasks + 1,
        (index) => 'Task $index',
      ).join('\n');
      final preview = parseBulkCapture(input, mode: BulkCaptureMode.lines);

      expect(preview.entries, isEmpty);
      expect(preview.failure?.code, 'bulk_capture.too_many_tasks');
    });

    test('one oversized title invalidates the whole preview', () {
      final preview = parseBulkCapture(
        'Valid\n${'x' * 1025}',
        mode: BulkCaptureMode.lines,
      );

      expect(preview.entries, isEmpty);
      expect(preview.failure?.code, 'bulk_capture.title_too_long');
      expect(preview.failure?.entryNumber, 2);
    });

    test('oversized paragraph notes invalidate the whole preview', () {
      final preview = parseBulkCapture(
        'Title\n${'n' * 8193}',
        mode: BulkCaptureMode.paragraphs,
      );

      expect(preview.entries, isEmpty);
      expect(preview.failure?.code, 'bulk_capture.notes_too_long');
    });

    test('malformed control characters are rejected, not stripped', () {
      final preview = parseBulkCapture(
        'Valid\nBad\u0000title',
        mode: BulkCaptureMode.lines,
      );

      expect(preview.entries, isEmpty);
      expect(preview.failure?.code, 'bulk_capture.malformed_text');
      expect(preview.failure?.entryNumber, 2);
    });

    test('input character bound rejects before parsing', () {
      final preview = parseBulkCapture(
        'x' * (maxBulkCaptureInputCharacters + 1),
        mode: BulkCaptureMode.lines,
      );
      expect(preview.entries, isEmpty);
      expect(preview.failure?.code, 'bulk_capture.input_too_large');
    });
  });
}
