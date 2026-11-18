import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('task presentation uses domain commands rather than database or sync engines', () {
    final forbidden = RegExp(
      r'''(?:import|export)\s+['"][^'"]*(?:data/database/|sync/engine\.dart|sync/coordinator/|package:drift/|package:sqlite3/)''',
    );
    final files = Directory('lib/src/features/tasks')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    expect(files, isNotEmpty);
    for (final file in files) {
      expect(
        forbidden.hasMatch(file.readAsStringSync()),
        isFalse,
        reason: '${file.path} must route actions through the domain boundary',
      );
    }
  });
}
