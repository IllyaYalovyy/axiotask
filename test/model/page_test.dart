// Unit layer — Page<T> holds a page of items plus an optional continuation
// token. Trivial by design; the test guards the shape the API pagination loop
// (Step 3) depends on: a present token means "more pages", a null token means
// the last page.

import 'package:axiotask/src/model/page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('carries items and a continuation token', () {
    const p = Page<int>(items: [1, 2, 3], nextPageToken: 'tok');
    expect(p.items, [1, 2, 3]);
    expect(p.nextPageToken, 'tok');
  });

  test('a null token marks the last page', () {
    const p = Page<String>(items: ['a']);
    expect(p.nextPageToken, isNull);
  });
}
