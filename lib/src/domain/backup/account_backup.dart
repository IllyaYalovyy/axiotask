import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../model/tasks.dart';

const String accountBackupFormat = 'axiotask.accountBackup';
const int accountBackupVersion = 1;
const int maxBackupLists = 1000;
const int maxBackupTasks = 100000;
const int maxBackupTitleCharacters = 1024;
const int maxBackupNotesCharacters = 8192;
const int maxBackupGoogleIdentityCharacters = 1024;
const int maxAccountBackupBytes = 64 * 1024 * 1024;
const String accountBackupPrivateDataWarning =
    'This file contains private Google Tasks data. Store and share it carefully.';

final class AccountBackupSnapshot {
  AccountBackupSnapshot({
    required this.sourceGoogleSubject,
    required List<AccountBackupList> lists,
    required List<AccountBackupTask> tasks,
  }) : lists = List<AccountBackupList>.unmodifiable(lists),
       tasks = List<AccountBackupTask>.unmodifiable(tasks);

  final String sourceGoogleSubject;
  final List<AccountBackupList> lists;
  final List<AccountBackupTask> tasks;
}

final class AccountBackupDocument extends AccountBackupSnapshot {
  AccountBackupDocument({
    required this.format,
    required this.version,
    required this.privateDataWarning,
    required this.exportedAt,
    required super.sourceGoogleSubject,
    required super.lists,
    required super.tasks,
  });

  final String format;
  final int version;
  final String privateDataWarning;
  final DateTime exportedAt;
}

final class AccountBackupList {
  const AccountBackupList({
    required this.key,
    required this.googleId,
    required this.title,
    required this.order,
  });

  final String key;
  final String? googleId;
  final String title;
  final int order;

  @override
  bool operator ==(Object other) =>
      other is AccountBackupList &&
      key == other.key &&
      googleId == other.googleId &&
      title == other.title &&
      order == other.order;

  @override
  int get hashCode => Object.hash(key, googleId, title, order);
}

final class AccountBackupTask {
  const AccountBackupTask({
    required this.key,
    required this.googleId,
    required this.listKey,
    required this.parentKey,
    required this.title,
    required this.notes,
    required this.status,
    required this.due,
    required this.order,
  });

  final String key;
  final String? googleId;
  final String listKey;
  final String? parentKey;
  final String title;
  final String? notes;
  final TaskStatus status;
  final TaskDate? due;
  final int order;

  @override
  bool operator ==(Object other) =>
      other is AccountBackupTask &&
      key == other.key &&
      googleId == other.googleId &&
      listKey == other.listKey &&
      parentKey == other.parentKey &&
      title == other.title &&
      notes == other.notes &&
      status == other.status &&
      due == other.due &&
      order == other.order;

  @override
  int get hashCode => Object.hash(
    key,
    googleId,
    listKey,
    parentKey,
    title,
    notes,
    status,
    due,
    order,
  );
}

final class AccountBackupFormatException implements Exception {
  const AccountBackupFormatException(this.code);

  final String code;

  @override
  String toString() => 'AccountBackupFormatException($code)';
}

final class AccountBackupTargetList {
  const AccountBackupTargetList({required this.key, required this.googleId});

  final TaskListId key;
  final String? googleId;
}

final class AccountBackupTargetTask {
  const AccountBackupTargetTask({
    required this.key,
    required this.googleId,
    required this.listKey,
    required this.parentKey,
  });

  final TaskId key;
  final String? googleId;
  final TaskListId listKey;
  final TaskId? parentKey;
}

final class AccountBackupImportTarget {
  const AccountBackupImportTarget({
    required this.googleSubject,
    required this.lists,
    required this.tasks,
  });

  final String googleSubject;
  final List<AccountBackupTargetList> lists;
  final List<AccountBackupTargetTask> tasks;
}

final class AccountBackupImportPlan {
  AccountBackupImportPlan({
    required this.sourceAccountMatches,
    required Map<String, TaskListId> existingLists,
    required Map<String, TaskId> existingTasks,
    required List<AccountBackupList> listsToCreate,
    required List<AccountBackupTask> tasksToCreate,
  }) : existingLists = Map<String, TaskListId>.unmodifiable(existingLists),
       existingTasks = Map<String, TaskId>.unmodifiable(existingTasks),
       listsToCreate = List<AccountBackupList>.unmodifiable(listsToCreate),
       tasksToCreate = List<AccountBackupTask>.unmodifiable(tasksToCreate);

  final bool sourceAccountMatches;
  final Map<String, TaskListId> existingLists;
  final Map<String, TaskId> existingTasks;
  final List<AccountBackupList> listsToCreate;
  final List<AccountBackupTask> tasksToCreate;

  int get existingListCount => existingLists.length;
  int get existingTaskCount => existingTasks.length;
}

enum AccountBackupImportReadiness {
  ready,
  syncStopped,
  noAuthorization,
  offline,
  stale,
  pending,
}

final class AccountBackupImportPreview {
  const AccountBackupImportPreview({
    required this.documentDigest,
    required this.sourceAccountMatches,
    required this.listCount,
    required this.taskCount,
    required this.listsToCreate,
    required this.tasksToCreate,
    required this.existingListCount,
    required this.existingTaskCount,
    required this.alreadyImported,
  });

  final String documentDigest;
  final bool sourceAccountMatches;
  final int listCount;
  final int taskCount;
  final int listsToCreate;
  final int tasksToCreate;
  final int existingListCount;
  final int existingTaskCount;
  final bool alreadyImported;
}

final class AccountBackupImportResult {
  const AccountBackupImportResult({
    required this.createdListCount,
    required this.existingListCount,
    required this.createdTaskCount,
    required this.existingTaskCount,
    required this.alreadyImported,
  });

  final int createdListCount;
  final int existingListCount;
  final int createdTaskCount;
  final int existingTaskCount;
  final bool alreadyImported;
}

final class AccountBackupImportException implements Exception {
  const AccountBackupImportException(this.code);

  final String code;

  @override
  String toString() => 'AccountBackupImportException($code)';
}

/// Matches only authoritative Google identity within the same Google subject.
/// Content deliberately has no role in planning.
final class AccountBackupImportPlanner {
  const AccountBackupImportPlanner();

  AccountBackupImportPlan plan({
    required AccountBackupDocument document,
    required AccountBackupImportTarget target,
  }) {
    final sameAccount = document.sourceGoogleSubject == target.googleSubject;
    final targetListsByGoogleId = <String, TaskListId>{};
    final targetTasksByGoogleId = <String, TaskId>{};
    if (sameAccount) {
      for (final list in target.lists) {
        final googleId = list.googleId;
        if (googleId != null) targetListsByGoogleId[googleId] = list.key;
      }
      for (final task in target.tasks) {
        final googleId = task.googleId;
        if (googleId != null) targetTasksByGoogleId[googleId] = task.key;
      }
    }
    final existingLists = <String, TaskListId>{};
    final listsToCreate = <AccountBackupList>[];
    for (final list in document.lists) {
      final existing = list.googleId == null
          ? null
          : targetListsByGoogleId[list.googleId!];
      if (existing == null) {
        listsToCreate.add(list);
      } else {
        existingLists[list.key] = existing;
      }
    }
    final existingTasks = <String, TaskId>{};
    final tasksToCreate = <AccountBackupTask>[];
    for (final task in document.tasks) {
      final existing = task.googleId == null
          ? null
          : targetTasksByGoogleId[task.googleId!];
      if (existing == null) {
        tasksToCreate.add(task);
      } else {
        existingTasks[task.key] = existing;
      }
    }
    return AccountBackupImportPlan(
      sourceAccountMatches: sameAccount,
      existingLists: existingLists,
      existingTasks: existingTasks,
      listsToCreate: listsToCreate,
      tasksToCreate: tasksToCreate,
    );
  }
}

final class AccountBackupCodec {
  const AccountBackupCodec();

  String encode(
    AccountBackupSnapshot snapshot, {
    required DateTime exportedAt,
  }) {
    final document = AccountBackupDocument(
      format: accountBackupFormat,
      version: accountBackupVersion,
      privateDataWarning: accountBackupPrivateDataWarning,
      exportedAt: exportedAt.toUtc(),
      sourceGoogleSubject: snapshot.sourceGoogleSubject,
      lists: snapshot.lists,
      tasks: snapshot.tasks,
    );
    _validate(document);
    final encoded = jsonEncode(_toJson(document));
    if (utf8.encode(encoded).length > maxAccountBackupBytes) {
      throw const AccountBackupFormatException('document_too_large');
    }
    decode(encoded);
    return encoded;
  }

  AccountBackupDocument decode(String encoded) {
    if (utf8.encode(encoded).length > maxAccountBackupBytes) {
      throw const AccountBackupFormatException('document_too_large');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } on FormatException {
      throw const AccountBackupFormatException('invalid_json');
    }
    final root = _map(decoded, 'document');
    _exactKeys(root, const <String>{
      'format',
      'version',
      'privateDataWarning',
      'exportedAt',
      'sourceAccount',
      'lists',
      'tasks',
    });
    final account = _map(root['sourceAccount'], 'source_account');
    _exactKeys(account, const <String>{'googleSubject'});
    final lists = _list(
      root['lists'],
      'lists',
    ).map(_decodeList).toList(growable: false);
    final tasks = _list(
      root['tasks'],
      'tasks',
    ).map(_decodeTask).toList(growable: false);
    final document = AccountBackupDocument(
      format: _string(root['format'], 'format'),
      version: _integer(root['version'], 'version'),
      privateDataWarning: _string(
        root['privateDataWarning'],
        'private_data_warning',
      ),
      exportedAt: _dateTime(root['exportedAt'], 'exported_at'),
      sourceGoogleSubject: _string(account['googleSubject'], 'google_subject'),
      lists: lists,
      tasks: tasks,
    );
    _validate(document);
    return document;
  }

  String fingerprint(AccountBackupDocument document) => sha256
      .convert(utf8.encode(encode(document, exportedAt: document.exportedAt)))
      .toString();
}

Map<String, Object?> _toJson(AccountBackupDocument document) =>
    <String, Object?>{
      'format': document.format,
      'version': document.version,
      'privateDataWarning': document.privateDataWarning,
      'exportedAt': document.exportedAt.toUtc().toIso8601String(),
      'sourceAccount': <String, Object?>{
        'googleSubject': document.sourceGoogleSubject,
      },
      'lists': document.lists
          .map(
            (list) => <String, Object?>{
              'key': list.key,
              'googleId': list.googleId,
              'title': list.title,
              'order': list.order,
            },
          )
          .toList(growable: false),
      'tasks': document.tasks
          .map(
            (task) => <String, Object?>{
              'key': task.key,
              'googleId': task.googleId,
              'listKey': task.listKey,
              'parentKey': task.parentKey,
              'title': task.title,
              'notes': task.notes,
              'status': task.status.name,
              'due': task.due?.toString(),
              'order': task.order,
            },
          )
          .toList(growable: false),
    };

AccountBackupList _decodeList(Object? value) {
  final item = _map(value, 'list');
  _exactKeys(item, const <String>{'key', 'googleId', 'title', 'order'});
  return AccountBackupList(
    key: _string(item['key'], 'list_key'),
    googleId: _nullableString(item['googleId'], 'list_google_id'),
    title: _string(item['title'], 'list_title'),
    order: _integer(item['order'], 'list_order'),
  );
}

AccountBackupTask _decodeTask(Object? value) {
  final item = _map(value, 'task');
  _exactKeys(item, const <String>{
    'key',
    'googleId',
    'listKey',
    'parentKey',
    'title',
    'notes',
    'status',
    'due',
    'order',
  });
  final status = switch (_string(item['status'], 'task_status')) {
    'needsAction' => TaskStatus.needsAction,
    'completed' => TaskStatus.completed,
    _ => throw const AccountBackupFormatException('unsupported_task_status'),
  };
  return AccountBackupTask(
    key: _string(item['key'], 'task_key'),
    googleId: _nullableString(item['googleId'], 'task_google_id'),
    listKey: _string(item['listKey'], 'task_list_key'),
    parentKey: _nullableString(item['parentKey'], 'task_parent_key'),
    title: _string(item['title'], 'task_title'),
    notes: _nullableString(item['notes'], 'task_notes'),
    status: status,
    due: _taskDate(item['due']),
    order: _integer(item['order'], 'task_order'),
  );
}

void _validate(AccountBackupDocument document) {
  if (document.format != accountBackupFormat) {
    throw const AccountBackupFormatException('unsupported_format');
  }
  if (document.version != accountBackupVersion) {
    throw const AccountBackupFormatException('unsupported_version');
  }
  if (document.privateDataWarning != accountBackupPrivateDataWarning) {
    throw const AccountBackupFormatException('privacy_warning_mismatch');
  }
  if (!document.exportedAt.isUtc) {
    throw const AccountBackupFormatException('export_time_not_utc');
  }
  _boundedIdentity(document.sourceGoogleSubject, 'google_subject');
  if (document.lists.length > maxBackupLists) {
    throw const AccountBackupFormatException('too_many_lists');
  }
  if (document.tasks.length > maxBackupTasks) {
    throw const AccountBackupFormatException('too_many_tasks');
  }

  final listKeys = <String>{};
  final listGoogleIds = <String>{};
  for (var index = 0; index < document.lists.length; index += 1) {
    final list = document.lists[index];
    _key(list.key, 'list_key', prefix: 'list');
    _title(list.title, 'list_title');
    _optionalIdentity(list.googleId, listGoogleIds, 'list_google_id');
    if (!listKeys.add(list.key)) {
      throw const AccountBackupFormatException('duplicate_list_key');
    }
    if (list.order != index) {
      throw const AccountBackupFormatException('invalid_list_order');
    }
  }

  final tasksByKey = <String, AccountBackupTask>{};
  final taskGoogleIds = <String>{};
  final siblingOrders = <String, Set<int>>{};
  for (final task in document.tasks) {
    _key(task.key, 'task_key', prefix: 'task');
    _key(task.listKey, 'task_list_key', prefix: 'list');
    if (task.parentKey case final parentKey?) {
      _key(parentKey, 'task_parent_key', prefix: 'task');
    }
    _title(task.title, 'task_title');
    if ((task.notes?.length ?? 0) > maxBackupNotesCharacters) {
      throw const AccountBackupFormatException('task_notes_too_long');
    }
    _optionalIdentity(task.googleId, taskGoogleIds, 'task_google_id');
    if (!listKeys.contains(task.listKey)) {
      throw const AccountBackupFormatException('task_list_missing');
    }
    if (task.order < 0) {
      throw const AccountBackupFormatException('invalid_task_order');
    }
    if (tasksByKey.containsKey(task.key)) {
      throw const AccountBackupFormatException('duplicate_task_key');
    }
    tasksByKey[task.key] = task;
    final siblingKey = '${task.listKey}\u0000${task.parentKey ?? ''}';
    if (!(siblingOrders[siblingKey] ??= <int>{}).add(task.order)) {
      throw const AccountBackupFormatException('duplicate_task_order');
    }
  }
  for (final task in document.tasks) {
    final parentKey = task.parentKey;
    if (parentKey == null) continue;
    final parent = tasksByKey[parentKey];
    if (parent == null || parent.listKey != task.listKey) {
      throw const AccountBackupFormatException('task_parent_missing');
    }
    if (parent.parentKey != null) {
      throw const AccountBackupFormatException('unsupported_task_depth');
    }
  }
  for (final orders in siblingOrders.values) {
    final expected = List<int>.generate(
      orders.length,
      (index) => index,
    ).toSet();
    if (orders.length != expected.length || !orders.containsAll(expected)) {
      throw const AccountBackupFormatException('non_contiguous_task_order');
    }
  }
}

void _title(String value, String field) {
  if (value.length > maxBackupTitleCharacters) {
    throw AccountBackupFormatException('${field}_too_long');
  }
}

void _key(String value, String field, {required String prefix}) {
  if (!RegExp('^$prefix-[0-9]{6}\$').hasMatch(value)) {
    throw AccountBackupFormatException('invalid_$field');
  }
}

void _boundedIdentity(String value, String field) {
  if (value.isEmpty || value.length > maxBackupGoogleIdentityCharacters) {
    throw AccountBackupFormatException('invalid_$field');
  }
}

void _optionalIdentity(String? value, Set<String> seen, String field) {
  if (value == null) return;
  _boundedIdentity(value, field);
  if (!seen.add(value)) {
    throw AccountBackupFormatException('duplicate_$field');
  }
}

Map<String, Object?> _map(Object? value, String field) {
  if (value is Map<String, Object?>) return value;
  throw AccountBackupFormatException('invalid_$field');
}

List<Object?> _list(Object? value, String field) {
  if (value is List<Object?>) return value;
  throw AccountBackupFormatException('invalid_$field');
}

String _string(Object? value, String field) {
  if (value is String) return value;
  throw AccountBackupFormatException('invalid_$field');
}

String? _nullableString(Object? value, String field) {
  if (value == null || value is String) return value as String?;
  throw AccountBackupFormatException('invalid_$field');
}

int _integer(Object? value, String field) {
  if (value is int) return value;
  throw AccountBackupFormatException('invalid_$field');
}

DateTime _dateTime(Object? value, String field) {
  final text = _string(value, field);
  final parsed = DateTime.tryParse(text);
  if (parsed == null || !parsed.isUtc || parsed.toIso8601String() != text) {
    throw AccountBackupFormatException('invalid_$field');
  }
  return parsed;
}

TaskDate? _taskDate(Object? value) {
  if (value == null) return null;
  final text = _string(value, 'task_due');
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(text);
  if (match == null) {
    throw const AccountBackupFormatException('invalid_task_due');
  }
  try {
    final date = TaskDate(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
    if (date.toString() != text) {
      throw const AccountBackupFormatException('invalid_task_due');
    }
    return date;
  } on ArgumentError {
    throw const AccountBackupFormatException('invalid_task_due');
  }
}

void _exactKeys(Map<String, Object?> value, Set<String> expected) {
  if (value.length != expected.length ||
      !value.keys.toSet().containsAll(expected)) {
    throw const AccountBackupFormatException('unexpected_field');
  }
}
