// Windowing: size-only persistence and the "no window work before restore is
// explicitly asked for" invariant (the geometry-freeze lesson). Tested against
// a fake WindowController — the real window_manager needs a live desktop window.

import 'dart:io';
import 'dart:ui';

import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/window_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Records every call so tests can assert what the window was (and was NOT)
/// asked to do. There is no position API to fake — size-only is structural.
class _FakeWindow implements WindowController {
  Size current = const Size(1280, 720);
  final List<Size> setSizes = [];

  @override
  Future<Size> getSize() async => current;

  @override
  Future<void> setSize(Size size) async {
    setSizes.add(size);
    current = size;
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('axiotask_win_test'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  PrefsStore prefs() => PrefsStore(File(p.join(tmp.path, 'prefs.json')));

  test(
    'constructing the service touches the window for NOTHING (rule 2)',
    () async {
      final win = _FakeWindow();
      WindowService(controller: win, prefs: prefs());
      // No restore, no read, no resize — geometry work happens only when the
      // bootstrap explicitly asks, after the first frame.
      expect(win.setSizes, isEmpty);
    },
  );

  test('restoreSize applies the persisted size', () async {
    final store = prefs()..saveWindowSize(const WindowSize(1100, 740));
    final win = _FakeWindow();
    await WindowService(controller: win, prefs: store).restoreSize();

    expect(win.setSizes, [const Size(1100, 740)]);
    expect(win.current, const Size(1100, 740));
  });

  test('restoreSize is a no-op when nothing was persisted', () async {
    final win = _FakeWindow();
    await WindowService(controller: win, prefs: prefs()).restoreSize();
    expect(win.setSizes, isEmpty, reason: 'runner default size stands');
  });

  test('persistSize writes the size to prefs (size-only)', () {
    final store = prefs();
    WindowService(
      controller: _FakeWindow(),
      prefs: store,
    ).persistSize(const Size(960, 640));
    expect(store.load().windowSize, const WindowSize(960, 640));
  });

  test('a degenerate resize (0×0 during minimize) is not persisted', () {
    final store = prefs()..saveWindowSize(const WindowSize(1000, 700));
    WindowService(
      controller: _FakeWindow(),
      prefs: store,
    ).persistSize(const Size(0, 0));
    // The last real size stands; a minimize-to-zero must not overwrite it.
    expect(store.load().windowSize, const WindowSize(1000, 700));
  });

  test('persistCurrentSize reads the live window size and stores it', () async {
    final store = prefs();
    final win = _FakeWindow()..current = const Size(880, 600);
    await WindowService(controller: win, prefs: store).persistCurrentSize();
    expect(store.load().windowSize, const WindowSize(880, 600));
  });
}
