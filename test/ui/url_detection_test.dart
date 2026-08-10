// UrlDetection (MIGRATION-PLAN §5 T7.2) — the pure URL-extraction the task row
// uses to decide whether to show a link badge and what to open. Ports the
// reference's `extractUrls` regex (`/https?:\/\/[^\s)>\]]+/g`): http/https only,
// stops at whitespace and the closing punctuation `)`, `>`, `]`. The row reads
// BOTH the title and the notes, first-match-first, so the badge opens the URL a
// user would expect. These assertions pin the extracted list itself — the
// behavior a wrong regex would silently break.

import 'package:axiotask/src/ui/url_detect.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('finds a bare http/https URL', () {
    expect(extractUrls('see https://example.com/x now'), [
      'https://example.com/x',
    ]);
    expect(extractUrls('http://a.test'), ['http://a.test']);
  });

  test('no URL / null / plain text yields an empty list', () {
    expect(extractUrls(null), isEmpty);
    expect(extractUrls(''), isEmpty);
    expect(extractUrls('just a plain task title'), isEmpty);
    // A bare host without a scheme is NOT a URL (parity with the reference).
    expect(extractUrls('visit example.com'), isEmpty);
  });

  test('stops at whitespace and closing )/>/] punctuation', () {
    expect(extractUrls('(https://example.com/a) tail'), [
      'https://example.com/a',
    ]);
    expect(extractUrls('<https://example.com/b>'), ['https://example.com/b']);
    expect(extractUrls('[https://example.com/c]'), ['https://example.com/c']);
  });

  test('collects multiple URLs in order', () {
    expect(extractUrls('https://one.test and https://two.test/p'), [
      'https://one.test',
      'https://two.test/p',
    ]);
  });

  test('reads title first, then notes (combined, in that order)', () {
    expect(
      urlsForTask(title: 'a https://title.test', notes: 'b https://notes.test'),
      ['https://title.test', 'https://notes.test'],
    );
    // Notes-only still surfaces the badge.
    expect(urlsForTask(title: 'no link here', notes: 'https://notes.test'), [
      'https://notes.test',
    ]);
    // A null notes field is fine.
    expect(urlsForTask(title: 'https://title.test', notes: null), [
      'https://title.test',
    ]);
  });
}
