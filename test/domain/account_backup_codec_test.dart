import 'dart:convert';

import 'package:axiotask/src/domain/backup/account_backup.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const codec = AccountBackupCodec();
  final exportedAt = DateTime.utc(2026, 8, 16, 12, 30);

  test('PAR-DATA-001 v1 supported fields round-trip with hierarchy/order', () {
    final source = _snapshot();

    final encoded = codec.encode(source, exportedAt: exportedAt);
    final decoded = codec.decode(encoded);

    expect(decoded.format, accountBackupFormat);
    expect(decoded.version, accountBackupVersion);
    expect(decoded.exportedAt, exportedAt);
    expect(decoded.sourceGoogleSubject, 'synthetic-backup-subject');
    expect(decoded.lists, source.lists);
    expect(decoded.tasks, source.tasks);
    expect(decoded.tasks.map((task) => task.order), <int>[0, 0, 1]);
    expect(decoded.tasks[1].parentKey, 'task-000001');
  });

  test('encoding is deterministic for the same snapshot and timestamp', () {
    expect(
      codec.encode(_snapshot(), exportedAt: exportedAt),
      codec.encode(_snapshot(), exportedAt: exportedAt),
    );
  });

  test(
    'validator rejects version, bounds, references, and deeper hierarchy',
    () {
      final valid =
          jsonDecode(codec.encode(_snapshot(), exportedAt: exportedAt))
              as Map<String, Object?>;

      expect(
        () =>
            codec.decode(jsonEncode(<String, Object?>{...valid, 'version': 2})),
        throwsA(isA<AccountBackupFormatException>()),
      );

      final lists = (valid['lists']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .map((value) => <String, Object?>{...value})
          .toList();
      lists[0]['key'] = 'task-000001';
      expect(
        () => codec.decode(
          jsonEncode(<String, Object?>{...valid, 'lists': lists}),
        ),
        throwsA(
          isA<AccountBackupFormatException>().having(
            (error) => error.code,
            'code',
            'invalid_list_key',
          ),
        ),
      );

      final tasks = (valid['tasks']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .map((value) => <String, Object?>{...value})
          .toList();
      tasks[0]['title'] = 'x' * (maxBackupTitleCharacters + 1);
      expect(
        () => codec.decode(
          jsonEncode(<String, Object?>{...valid, 'tasks': tasks}),
        ),
        throwsA(isA<AccountBackupFormatException>()),
      );

      tasks[0]['title'] = 'Parent';
      tasks[2]['parentKey'] = tasks[1]['key'];
      expect(
        () => codec.decode(
          jsonEncode(<String, Object?>{...valid, 'tasks': tasks}),
        ),
        throwsA(isA<AccountBackupFormatException>()),
      );

      final tooManyLists = List<AccountBackupList>.generate(
        maxBackupLists + 1,
        (index) => AccountBackupList(
          key: 'list-${(index + 1).toString().padLeft(6, '0')}',
          googleId: null,
          title: 'Synthetic list',
          order: index,
        ),
      );
      expect(
        () => codec.encode(
          AccountBackupSnapshot(
            sourceGoogleSubject: 'synthetic-subject',
            lists: tooManyLists,
            tasks: const <AccountBackupTask>[],
          ),
          exportedAt: exportedAt,
        ),
        throwsA(isA<AccountBackupFormatException>()),
      );
    },
  );

  test('encoder input cannot carry excluded product state', () {
    final encoded = codec.encode(_snapshot(), exportedAt: exportedAt);

    expect(encoded, isNot(contains('authorization-canary')));
    expect(encoded, isNot(contains('diagnostic-canary')));
    expect(encoded, isNot(contains('sync-attempt-canary')));
    expect(encoded, isNot(contains('device-preference-canary')));
    expect(encoded, isNot(contains('database-row-canary')));
    expect(encoded, contains(accountBackupPrivateDataWarning));
  });

  test('hostile credential and storage fields are rejected, not imported', () {
    final valid =
        jsonDecode(codec.encode(_snapshot(), exportedAt: exportedAt))
            as Map<String, Object?>;
    for (final field in const <String>[
      'authorization',
      'refreshToken',
      'syncRuns',
      'diagnostics',
      'databaseRows',
    ]) {
      expect(
        () => codec.decode(
          jsonEncode(<String, Object?>{...valid, field: 'private-canary'}),
        ),
        throwsA(
          isA<AccountBackupFormatException>().having(
            (error) => error.code,
            'code',
            'unexpected_field',
          ),
        ),
      );
    }
  });
}

AccountBackupSnapshot _snapshot() => AccountBackupSnapshot(
  sourceGoogleSubject: 'synthetic-backup-subject',
  lists: const <AccountBackupList>[
    AccountBackupList(
      key: 'list-000001',
      googleId: 'google-list-a',
      title: 'Synthetic inbox',
      order: 0,
    ),
    AccountBackupList(
      key: 'list-000002',
      googleId: null,
      title: 'Offline-created list',
      order: 1,
    ),
  ],
  tasks: <AccountBackupTask>[
    const AccountBackupTask(
      key: 'task-000001',
      googleId: 'google-task-parent',
      listKey: 'list-000001',
      parentKey: null,
      title: 'Parent',
      notes: 'Multiline\nUnicode ☕',
      status: TaskStatus.needsAction,
      due: null,
      order: 0,
    ),
    AccountBackupTask(
      key: 'task-000002',
      googleId: 'google-task-child',
      listKey: 'list-000001',
      parentKey: 'task-000001',
      title: 'Child',
      notes: null,
      status: TaskStatus.completed,
      due: TaskDate(2026, 8, 20),
      order: 0,
    ),
    const AccountBackupTask(
      key: 'task-000003',
      googleId: null,
      listKey: 'list-000001',
      parentKey: null,
      title: 'Acknowledged offline',
      notes: '',
      status: TaskStatus.needsAction,
      due: null,
      order: 1,
    ),
  ],
);
