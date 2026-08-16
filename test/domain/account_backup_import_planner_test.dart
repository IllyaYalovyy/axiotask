import 'package:axiotask/src/domain/backup/account_backup.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PAR-DATA-002 same-account authoritative identities win', () {
    const planner = AccountBackupImportPlanner();
    final plan = planner.plan(
      document: _document('target-subject'),
      target: const AccountBackupImportTarget(
        googleSubject: 'target-subject',
        lists: <AccountBackupTargetList>[
          AccountBackupTargetList(key: TaskListId(7), googleId: 'list-a'),
        ],
        tasks: <AccountBackupTargetTask>[
          AccountBackupTargetTask(
            key: TaskId(11),
            googleId: 'task-a',
            listKey: TaskListId(7),
            parentKey: null,
          ),
        ],
      ),
    );

    expect(plan.existingListCount, 1);
    expect(plan.listsToCreate, isEmpty);
    expect(plan.existingTaskCount, 1);
    expect(plan.tasksToCreate.map((task) => task.key), <String>['task-000002']);
  });

  test('cross-account planning never matches remote IDs or content', () {
    const planner = AccountBackupImportPlanner();
    final plan = planner.plan(
      document: _document('source-subject'),
      target: const AccountBackupImportTarget(
        googleSubject: 'target-subject',
        lists: <AccountBackupTargetList>[
          AccountBackupTargetList(key: TaskListId(7), googleId: 'list-a'),
        ],
        tasks: <AccountBackupTargetTask>[
          AccountBackupTargetTask(
            key: TaskId(11),
            googleId: 'task-a',
            listKey: TaskListId(7),
            parentKey: null,
          ),
        ],
      ),
    );

    expect(plan.sourceAccountMatches, isFalse);
    expect(plan.listsToCreate, hasLength(1));
    expect(plan.tasksToCreate, hasLength(2));
    expect(plan.existingListCount, 0);
    expect(plan.existingTaskCount, 0);
  });
}

AccountBackupDocument _document(String subject) => AccountBackupDocument(
  format: accountBackupFormat,
  version: accountBackupVersion,
  privateDataWarning: accountBackupPrivateDataWarning,
  exportedAt: DateTime.utc(2026, 8, 16),
  sourceGoogleSubject: subject,
  lists: const <AccountBackupList>[
    AccountBackupList(
      key: 'list-000001',
      googleId: 'list-a',
      title: 'Inbox',
      order: 0,
    ),
  ],
  tasks: const <AccountBackupTask>[
    AccountBackupTask(
      key: 'task-000001',
      googleId: 'task-a',
      listKey: 'list-000001',
      parentKey: null,
      title: 'Existing identity',
      notes: null,
      status: TaskStatus.needsAction,
      due: null,
      order: 0,
    ),
    AccountBackupTask(
      key: 'task-000002',
      googleId: 'task-b',
      listKey: 'list-000001',
      parentKey: null,
      title: 'Absent',
      notes: null,
      status: TaskStatus.needsAction,
      due: null,
      order: 1,
    ),
  ],
);
