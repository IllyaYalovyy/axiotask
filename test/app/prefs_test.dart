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

  test('missing file → defaults (theme system, no window size)', () {
    final store = PrefsStore(prefsFile());
    final prefs = store.load();
    expect(prefs.theme, 'system');
    expect(prefs.showCompleted, isFalse);
    expect(prefs.windowSize, isNull);
  });

  test('malformed file → defaults, not a crash', () {
    prefsFile().writeAsStringSync('not json at all');
    expect(PrefsStore(prefsFile()).load().theme, 'system');
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
