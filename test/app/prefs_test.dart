import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/app/prefs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('axiotask_prefs_test'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File prefsFile() => File(p.join(tmp.path, 'prefs.json'));

  test('missing file → defaults (default-dark theme, no window size)', () {
    // Default-dark ruling: a fresh install with no prefs file opens in dark.
    final store = PrefsStore(prefsFile());
    final prefs = store.load();
    expect(prefs.theme, 'dark');
    expect(prefs.showCompleted, isFalse);
    expect(prefs.windowSize, isNull);
  });

  test('malformed file → defaults, not a crash', () {
    prefsFile().writeAsStringSync('not json at all');
    expect(PrefsStore(prefsFile()).load().theme, 'dark');
  });

  test('round-trips full prefs through disk', () {
    final store = PrefsStore(prefsFile());
    final saved = const Prefs().copyWith(
      theme: 'dark',
      view: 'today',
      showCompleted: true,
      excludedLists: ['l1', 'l2'],
      listOrder: ['l2', 'l1'],
      onboardingSeen: true,
      hideCompletedSubtasks: true,
    );
    store.save(saved);

    final reloaded = PrefsStore(prefsFile()).load();
    expect(reloaded.theme, 'dark');
    expect(reloaded.view, 'today');
    expect(reloaded.showCompleted, isTrue);
    expect(reloaded.excludedLists, ['l1', 'l2']);
    expect(reloaded.listOrder, ['l2', 'l1']);
    expect(reloaded.onboardingSeen, isTrue);
    expect(reloaded.hideCompletedSubtasks, isTrue);
  });

  group('window size (size-only persistence)', () {
    test('saveWindowSize persists and reloads the size', () {
      final store = PrefsStore(prefsFile());
      store.saveWindowSize(const WindowSize(1100, 740));
      expect(
        PrefsStore(prefsFile()).load().windowSize,
        const WindowSize(1100, 740),
      );
    });

    test('saveWindowSize does not clobber unrelated prefs', () {
      final store = PrefsStore(prefsFile());
      store.save(const Prefs().copyWith(theme: 'dark', onboardingSeen: true));
      store.saveWindowSize(const WindowSize(900, 600));

      final reloaded = store.load();
      expect(reloaded.windowSize, const WindowSize(900, 600));
      expect(reloaded.theme, 'dark', reason: 'other prefs survive');
      expect(reloaded.onboardingSeen, isTrue);
    });

    test('no position field is ever written (size-only)', () {
      final store = PrefsStore(prefsFile());
      store.saveWindowSize(const WindowSize(800, 600));
      final raw = jsonDecode(prefsFile().readAsStringSync()) as Map;
      final win = raw['window_size'] as Map;
      expect(win.keys, containsAll(['width', 'height']));
      expect(win.containsKey('x'), isFalse);
      expect(win.containsKey('y'), isFalse);
    });

    test('a zero/negative persisted size is ignored on load', () {
      prefsFile().writeAsStringSync(
        jsonEncode({
          'window_size': {'width': 0, 'height': -5},
        }),
      );
      expect(PrefsStore(prefsFile()).load().windowSize, isNull);
    });
  });

  group('desktop pane widths (#210)', () {
    test('round-trips sidebar width and detail fraction through disk', () {
      final store = PrefsStore(prefsFile());
      store.save(
        const Prefs().copyWith(sidebarWidth: 320, detailFraction: 0.45),
      );
      final reloaded = PrefsStore(prefsFile()).load();
      expect(reloaded.sidebarWidth, 320);
      expect(reloaded.detailFraction, 0.45);
    });

    test('defaults are null when never dragged', () {
      final prefs = PrefsStore(prefsFile()).load();
      expect(prefs.sidebarWidth, isNull);
      expect(prefs.detailFraction, isNull);
    });

    test('a malformed sidebar width is ignored on load', () {
      prefsFile().writeAsStringSync(
        jsonEncode({'sidebar_width': 'wide', 'detail_fraction': 0.5}),
      );
      final prefs = PrefsStore(prefsFile()).load();
      expect(prefs.sidebarWidth, isNull, reason: 'non-numeric → default');
      expect(prefs.detailFraction, 0.5);
    });

    test('a non-positive width and an out-of-range fraction are ignored', () {
      prefsFile().writeAsStringSync(
        jsonEncode({'sidebar_width': 0, 'detail_fraction': 1.5}),
      );
      final prefs = PrefsStore(prefsFile()).load();
      expect(prefs.sidebarWidth, isNull);
      expect(
        prefs.detailFraction,
        isNull,
        reason: 'a ≥1 fraction crushes a pane',
      );
    });

    test('unset widths are omitted from the JSON (no null keys)', () {
      PrefsStore(prefsFile()).save(const Prefs());
      final raw = jsonDecode(prefsFile().readAsStringSync()) as Map;
      expect(raw.containsKey('sidebar_width'), isFalse);
      expect(raw.containsKey('detail_fraction'), isFalse);
    });
  });

  test('unknown keys on disk survive a save (forward-compat)', () {
    prefsFile().writeAsStringSync(
      jsonEncode({'theme': 'dark', 'future_pref_from_newer_build': 42}),
    );
    final store = PrefsStore(prefsFile());
    store.save(store.load().copyWith(theme: 'light'));

    final raw = jsonDecode(prefsFile().readAsStringSync()) as Map;
    expect(raw['theme'], 'light');
    expect(raw['future_pref_from_newer_build'], 42);
  });
}
