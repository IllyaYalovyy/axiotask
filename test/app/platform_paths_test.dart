// Desktop XDG resolution — the seam that makes dev/test data isolation work
// (XDG_DATA_HOME override → a throwaway data dir, never production).

import 'package:axiotask/src/app/platform_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('XDG_DATA_HOME, when set, is the data base (isolation)', () {
    final base = desktopDataBase(
      env: const {'XDG_DATA_HOME': '/tmp/iso/data', 'HOME': '/home/prod'},
    );
    expect(base.path, '/tmp/iso/data');
  });

  test('without XDG_DATA_HOME, falls back to HOME/.local/share', () {
    final base = desktopDataBase(env: const {}, home: '/home/u');
    expect(base.path, p.join('/home/u', '.local', 'share'));
  });

  test('XDG_CONFIG_HOME, when set, is the config base', () {
    final base = desktopConfigBase(
      env: const {'XDG_CONFIG_HOME': '/tmp/iso/config'},
    );
    expect(base.path, '/tmp/iso/config');
  });

  test('config falls back to HOME/.config', () {
    final base = desktopConfigBase(env: const {}, home: '/home/u');
    expect(base.path, p.join('/home/u', '.config'));
  });

  test('an empty XDG value is ignored (not treated as a real root)', () {
    final base = desktopDataBase(env: const {'XDG_DATA_HOME': ''}, home: '/h');
    expect(base.path, p.join('/h', '.local', 'share'));
  });
}
