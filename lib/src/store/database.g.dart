// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class TaskLists extends Table with TableInfo<TaskLists, TaskList> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  TaskLists(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'PRIMARY KEY',
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _etagMeta = const VerificationMeta('etag');
  late final GeneratedColumn<String> etag = GeneratedColumn<String>(
    'etag',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _updatedMeta = const VerificationMeta(
    'updated',
  );
  late final GeneratedColumn<String> updated = GeneratedColumn<String>(
    'updated',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _localUpdatedMeta = const VerificationMeta(
    'localUpdated',
  );
  late final GeneratedColumn<String> localUpdated = GeneratedColumn<String>(
    'local_updated',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _syncStateMeta = const VerificationMeta(
    'syncState',
  );
  late final GeneratedColumn<String> syncState = GeneratedColumn<String>(
    'sync_state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints:
        'NOT NULL CHECK (sync_state IN (\'clean\', \'dirty\', \'deleted\'))',
  );
  static const VerificationMeta _pendingOpMeta = const VerificationMeta(
    'pendingOp',
  );
  late final GeneratedColumn<String> pendingOp = GeneratedColumn<String>(
    'pending_op',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints:
        'CHECK (pending_op IN (\'create\', \'update\', \'delete\') OR pending_op IS NULL)',
  );
  static const VerificationMeta _localOnlyMeta = const VerificationMeta(
    'localOnly',
  );
  late final GeneratedColumn<int> localOnly = GeneratedColumn<int>(
    'local_only',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT 0',
    defaultValue: const CustomExpression('0'),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    etag,
    updated,
    localUpdated,
    syncState,
    pendingOp,
    localOnly,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'task_lists';
  @override
  VerificationContext validateIntegrity(
    Insertable<TaskList> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('etag')) {
      context.handle(
        _etagMeta,
        etag.isAcceptableOrUnknown(data['etag']!, _etagMeta),
      );
    }
    if (data.containsKey('updated')) {
      context.handle(
        _updatedMeta,
        updated.isAcceptableOrUnknown(data['updated']!, _updatedMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedMeta);
    }
    if (data.containsKey('local_updated')) {
      context.handle(
        _localUpdatedMeta,
        localUpdated.isAcceptableOrUnknown(
          data['local_updated']!,
          _localUpdatedMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_localUpdatedMeta);
    }
    if (data.containsKey('sync_state')) {
      context.handle(
        _syncStateMeta,
        syncState.isAcceptableOrUnknown(data['sync_state']!, _syncStateMeta),
      );
    } else if (isInserting) {
      context.missing(_syncStateMeta);
    }
    if (data.containsKey('pending_op')) {
      context.handle(
        _pendingOpMeta,
        pendingOp.isAcceptableOrUnknown(data['pending_op']!, _pendingOpMeta),
      );
    }
    if (data.containsKey('local_only')) {
      context.handle(
        _localOnlyMeta,
        localOnly.isAcceptableOrUnknown(data['local_only']!, _localOnlyMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TaskList map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TaskList(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      ),
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      etag: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}etag'],
      ),
      updated: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated'],
      )!,
      localUpdated: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_updated'],
      )!,
      syncState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sync_state'],
      )!,
      pendingOp: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}pending_op'],
      ),
      localOnly: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}local_only'],
      )!,
    );
  }

  @override
  TaskLists createAlias(String alias) {
    return TaskLists(attachedDatabase, alias);
  }

  @override
  bool get dontWriteConstraints => true;
}

class TaskList extends DataClass implements Insertable<TaskList> {
  final String? id;
  final String title;
  final String? etag;
  final String updated;
  final String localUpdated;
  final String syncState;
  final String? pendingOp;
  final int localOnly;
  const TaskList({
    this.id,
    required this.title,
    this.etag,
    required this.updated,
    required this.localUpdated,
    required this.syncState,
    this.pendingOp,
    required this.localOnly,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (!nullToAbsent || id != null) {
      map['id'] = Variable<String>(id);
    }
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || etag != null) {
      map['etag'] = Variable<String>(etag);
    }
    map['updated'] = Variable<String>(updated);
    map['local_updated'] = Variable<String>(localUpdated);
    map['sync_state'] = Variable<String>(syncState);
    if (!nullToAbsent || pendingOp != null) {
      map['pending_op'] = Variable<String>(pendingOp);
    }
    map['local_only'] = Variable<int>(localOnly);
    return map;
  }

  TaskListsCompanion toCompanion(bool nullToAbsent) {
    return TaskListsCompanion(
      id: id == null && nullToAbsent ? const Value.absent() : Value(id),
      title: Value(title),
      etag: etag == null && nullToAbsent ? const Value.absent() : Value(etag),
      updated: Value(updated),
      localUpdated: Value(localUpdated),
      syncState: Value(syncState),
      pendingOp: pendingOp == null && nullToAbsent
          ? const Value.absent()
          : Value(pendingOp),
      localOnly: Value(localOnly),
    );
  }

  factory TaskList.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TaskList(
      id: serializer.fromJson<String?>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      etag: serializer.fromJson<String?>(json['etag']),
      updated: serializer.fromJson<String>(json['updated']),
      localUpdated: serializer.fromJson<String>(json['local_updated']),
      syncState: serializer.fromJson<String>(json['sync_state']),
      pendingOp: serializer.fromJson<String?>(json['pending_op']),
      localOnly: serializer.fromJson<int>(json['local_only']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String?>(id),
      'title': serializer.toJson<String>(title),
      'etag': serializer.toJson<String?>(etag),
      'updated': serializer.toJson<String>(updated),
      'local_updated': serializer.toJson<String>(localUpdated),
      'sync_state': serializer.toJson<String>(syncState),
      'pending_op': serializer.toJson<String?>(pendingOp),
      'local_only': serializer.toJson<int>(localOnly),
    };
  }

  TaskList copyWith({
    Value<String?> id = const Value.absent(),
    String? title,
    Value<String?> etag = const Value.absent(),
    String? updated,
    String? localUpdated,
    String? syncState,
    Value<String?> pendingOp = const Value.absent(),
    int? localOnly,
  }) => TaskList(
    id: id.present ? id.value : this.id,
    title: title ?? this.title,
    etag: etag.present ? etag.value : this.etag,
    updated: updated ?? this.updated,
    localUpdated: localUpdated ?? this.localUpdated,
    syncState: syncState ?? this.syncState,
    pendingOp: pendingOp.present ? pendingOp.value : this.pendingOp,
    localOnly: localOnly ?? this.localOnly,
  );
  TaskList copyWithCompanion(TaskListsCompanion data) {
    return TaskList(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      etag: data.etag.present ? data.etag.value : this.etag,
      updated: data.updated.present ? data.updated.value : this.updated,
      localUpdated: data.localUpdated.present
          ? data.localUpdated.value
          : this.localUpdated,
      syncState: data.syncState.present ? data.syncState.value : this.syncState,
      pendingOp: data.pendingOp.present ? data.pendingOp.value : this.pendingOp,
      localOnly: data.localOnly.present ? data.localOnly.value : this.localOnly,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TaskList(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('etag: $etag, ')
          ..write('updated: $updated, ')
          ..write('localUpdated: $localUpdated, ')
          ..write('syncState: $syncState, ')
          ..write('pendingOp: $pendingOp, ')
          ..write('localOnly: $localOnly')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    etag,
    updated,
    localUpdated,
    syncState,
    pendingOp,
    localOnly,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TaskList &&
          other.id == this.id &&
          other.title == this.title &&
          other.etag == this.etag &&
          other.updated == this.updated &&
          other.localUpdated == this.localUpdated &&
          other.syncState == this.syncState &&
          other.pendingOp == this.pendingOp &&
          other.localOnly == this.localOnly);
}

class TaskListsCompanion extends UpdateCompanion<TaskList> {
  final Value<String?> id;
  final Value<String> title;
  final Value<String?> etag;
  final Value<String> updated;
  final Value<String> localUpdated;
  final Value<String> syncState;
  final Value<String?> pendingOp;
  final Value<int> localOnly;
  final Value<int> rowid;
  const TaskListsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.etag = const Value.absent(),
    this.updated = const Value.absent(),
    this.localUpdated = const Value.absent(),
    this.syncState = const Value.absent(),
    this.pendingOp = const Value.absent(),
    this.localOnly = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TaskListsCompanion.insert({
    this.id = const Value.absent(),
    required String title,
    this.etag = const Value.absent(),
    required String updated,
    required String localUpdated,
    required String syncState,
    this.pendingOp = const Value.absent(),
    this.localOnly = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : title = Value(title),
       updated = Value(updated),
       localUpdated = Value(localUpdated),
       syncState = Value(syncState);
  static Insertable<TaskList> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<String>? etag,
    Expression<String>? updated,
    Expression<String>? localUpdated,
    Expression<String>? syncState,
    Expression<String>? pendingOp,
    Expression<int>? localOnly,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (etag != null) 'etag': etag,
      if (updated != null) 'updated': updated,
      if (localUpdated != null) 'local_updated': localUpdated,
      if (syncState != null) 'sync_state': syncState,
      if (pendingOp != null) 'pending_op': pendingOp,
      if (localOnly != null) 'local_only': localOnly,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TaskListsCompanion copyWith({
    Value<String?>? id,
    Value<String>? title,
    Value<String?>? etag,
    Value<String>? updated,
    Value<String>? localUpdated,
    Value<String>? syncState,
    Value<String?>? pendingOp,
    Value<int>? localOnly,
    Value<int>? rowid,
  }) {
    return TaskListsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      etag: etag ?? this.etag,
      updated: updated ?? this.updated,
      localUpdated: localUpdated ?? this.localUpdated,
      syncState: syncState ?? this.syncState,
      pendingOp: pendingOp ?? this.pendingOp,
      localOnly: localOnly ?? this.localOnly,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (etag.present) {
      map['etag'] = Variable<String>(etag.value);
    }
    if (updated.present) {
      map['updated'] = Variable<String>(updated.value);
    }
    if (localUpdated.present) {
      map['local_updated'] = Variable<String>(localUpdated.value);
    }
    if (syncState.present) {
      map['sync_state'] = Variable<String>(syncState.value);
    }
    if (pendingOp.present) {
      map['pending_op'] = Variable<String>(pendingOp.value);
    }
    if (localOnly.present) {
      map['local_only'] = Variable<int>(localOnly.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TaskListsCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('etag: $etag, ')
          ..write('updated: $updated, ')
          ..write('localUpdated: $localUpdated, ')
          ..write('syncState: $syncState, ')
          ..write('pendingOp: $pendingOp, ')
          ..write('localOnly: $localOnly, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class Tasks extends Table with TableInfo<Tasks, Task> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  Tasks(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'PRIMARY KEY',
  );
  static const VerificationMeta _listIdMeta = const VerificationMeta('listId');
  late final GeneratedColumn<String> listId = GeneratedColumn<String>(
    'list_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL REFERENCES task_lists(id)ON DELETE CASCADE',
  );
  static const VerificationMeta _parentIdMeta = const VerificationMeta(
    'parentId',
  );
  late final GeneratedColumn<String> parentId = GeneratedColumn<String>(
    'parent_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'REFERENCES tasks(id)ON DELETE CASCADE',
  );
  static const VerificationMeta _positionMeta = const VerificationMeta(
    'position',
  );
  late final GeneratedColumn<String> position = GeneratedColumn<String>(
    'position',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
    'notes',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints:
        'NOT NULL CHECK (status IN (\'needsAction\', \'completed\'))',
  );
  static const VerificationMeta _dueMeta = const VerificationMeta('due');
  late final GeneratedColumn<String> due = GeneratedColumn<String>(
    'due',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _completedAtMeta = const VerificationMeta(
    'completedAt',
  );
  late final GeneratedColumn<String> completedAt = GeneratedColumn<String>(
    'completed_at',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _etagMeta = const VerificationMeta('etag');
  late final GeneratedColumn<String> etag = GeneratedColumn<String>(
    'etag',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _updatedMeta = const VerificationMeta(
    'updated',
  );
  late final GeneratedColumn<String> updated = GeneratedColumn<String>(
    'updated',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _localUpdatedMeta = const VerificationMeta(
    'localUpdated',
  );
  late final GeneratedColumn<String> localUpdated = GeneratedColumn<String>(
    'local_updated',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _syncStateMeta = const VerificationMeta(
    'syncState',
  );
  late final GeneratedColumn<String> syncState = GeneratedColumn<String>(
    'sync_state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints:
        'NOT NULL CHECK (sync_state IN (\'clean\', \'dirty\', \'deleted\'))',
  );
  static const VerificationMeta _pendingOpMeta = const VerificationMeta(
    'pendingOp',
  );
  late final GeneratedColumn<String> pendingOp = GeneratedColumn<String>(
    'pending_op',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints:
        'CHECK (pending_op IN (\'create\', \'update\', \'delete\') OR pending_op IS NULL)',
  );
  static const VerificationMeta _baseTitleMeta = const VerificationMeta(
    'baseTitle',
  );
  late final GeneratedColumn<String> baseTitle = GeneratedColumn<String>(
    'base_title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _baseNotesMeta = const VerificationMeta(
    'baseNotes',
  );
  late final GeneratedColumn<String> baseNotes = GeneratedColumn<String>(
    'base_notes',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _baseDueMeta = const VerificationMeta(
    'baseDue',
  );
  late final GeneratedColumn<String> baseDue = GeneratedColumn<String>(
    'base_due',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _baseStatusMeta = const VerificationMeta(
    'baseStatus',
  );
  late final GeneratedColumn<String> baseStatus = GeneratedColumn<String>(
    'base_status',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints:
        'CHECK (base_status IN (\'needsAction\', \'completed\') OR base_status IS NULL)',
  );
  static const VerificationMeta _webViewLinkMeta = const VerificationMeta(
    'webViewLink',
  );
  late final GeneratedColumn<String> webViewLink = GeneratedColumn<String>(
    'web_view_link',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    listId,
    parentId,
    position,
    title,
    notes,
    status,
    due,
    completedAt,
    etag,
    updated,
    localUpdated,
    syncState,
    pendingOp,
    baseTitle,
    baseNotes,
    baseDue,
    baseStatus,
    webViewLink,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'tasks';
  @override
  VerificationContext validateIntegrity(
    Insertable<Task> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('list_id')) {
      context.handle(
        _listIdMeta,
        listId.isAcceptableOrUnknown(data['list_id']!, _listIdMeta),
      );
    } else if (isInserting) {
      context.missing(_listIdMeta);
    }
    if (data.containsKey('parent_id')) {
      context.handle(
        _parentIdMeta,
        parentId.isAcceptableOrUnknown(data['parent_id']!, _parentIdMeta),
      );
    }
    if (data.containsKey('position')) {
      context.handle(
        _positionMeta,
        position.isAcceptableOrUnknown(data['position']!, _positionMeta),
      );
    } else if (isInserting) {
      context.missing(_positionMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('notes')) {
      context.handle(
        _notesMeta,
        notes.isAcceptableOrUnknown(data['notes']!, _notesMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('due')) {
      context.handle(
        _dueMeta,
        due.isAcceptableOrUnknown(data['due']!, _dueMeta),
      );
    }
    if (data.containsKey('completed_at')) {
      context.handle(
        _completedAtMeta,
        completedAt.isAcceptableOrUnknown(
          data['completed_at']!,
          _completedAtMeta,
        ),
      );
    }
    if (data.containsKey('etag')) {
      context.handle(
        _etagMeta,
        etag.isAcceptableOrUnknown(data['etag']!, _etagMeta),
      );
    }
    if (data.containsKey('updated')) {
      context.handle(
        _updatedMeta,
        updated.isAcceptableOrUnknown(data['updated']!, _updatedMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedMeta);
    }
    if (data.containsKey('local_updated')) {
      context.handle(
        _localUpdatedMeta,
        localUpdated.isAcceptableOrUnknown(
          data['local_updated']!,
          _localUpdatedMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_localUpdatedMeta);
    }
    if (data.containsKey('sync_state')) {
      context.handle(
        _syncStateMeta,
        syncState.isAcceptableOrUnknown(data['sync_state']!, _syncStateMeta),
      );
    } else if (isInserting) {
      context.missing(_syncStateMeta);
    }
    if (data.containsKey('pending_op')) {
      context.handle(
        _pendingOpMeta,
        pendingOp.isAcceptableOrUnknown(data['pending_op']!, _pendingOpMeta),
      );
    }
    if (data.containsKey('base_title')) {
      context.handle(
        _baseTitleMeta,
        baseTitle.isAcceptableOrUnknown(data['base_title']!, _baseTitleMeta),
      );
    }
    if (data.containsKey('base_notes')) {
      context.handle(
        _baseNotesMeta,
        baseNotes.isAcceptableOrUnknown(data['base_notes']!, _baseNotesMeta),
      );
    }
    if (data.containsKey('base_due')) {
      context.handle(
        _baseDueMeta,
        baseDue.isAcceptableOrUnknown(data['base_due']!, _baseDueMeta),
      );
    }
    if (data.containsKey('base_status')) {
      context.handle(
        _baseStatusMeta,
        baseStatus.isAcceptableOrUnknown(data['base_status']!, _baseStatusMeta),
      );
    }
    if (data.containsKey('web_view_link')) {
      context.handle(
        _webViewLinkMeta,
        webViewLink.isAcceptableOrUnknown(
          data['web_view_link']!,
          _webViewLinkMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Task map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Task(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      ),
      listId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}list_id'],
      )!,
      parentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}parent_id'],
      ),
      position: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}position'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      notes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notes'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      due: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}due'],
      ),
      completedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}completed_at'],
      ),
      etag: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}etag'],
      ),
      updated: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated'],
      )!,
      localUpdated: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_updated'],
      )!,
      syncState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sync_state'],
      )!,
      pendingOp: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}pending_op'],
      ),
      baseTitle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_title'],
      ),
      baseNotes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_notes'],
      ),
      baseDue: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_due'],
      ),
      baseStatus: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_status'],
      ),
      webViewLink: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}web_view_link'],
      ),
    );
  }

  @override
  Tasks createAlias(String alias) {
    return Tasks(attachedDatabase, alias);
  }

  @override
  bool get dontWriteConstraints => true;
}

class Task extends DataClass implements Insertable<Task> {
  final String? id;
  final String listId;
  final String? parentId;
  final String position;
  final String title;
  final String? notes;
  final String status;
  final String? due;
  final String? completedAt;
  final String? etag;
  final String updated;
  final String localUpdated;
  final String syncState;
  final String? pendingOp;
  final String? baseTitle;
  final String? baseNotes;
  final String? baseDue;
  final String? baseStatus;
  final String? webViewLink;
  const Task({
    this.id,
    required this.listId,
    this.parentId,
    required this.position,
    required this.title,
    this.notes,
    required this.status,
    this.due,
    this.completedAt,
    this.etag,
    required this.updated,
    required this.localUpdated,
    required this.syncState,
    this.pendingOp,
    this.baseTitle,
    this.baseNotes,
    this.baseDue,
    this.baseStatus,
    this.webViewLink,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (!nullToAbsent || id != null) {
      map['id'] = Variable<String>(id);
    }
    map['list_id'] = Variable<String>(listId);
    if (!nullToAbsent || parentId != null) {
      map['parent_id'] = Variable<String>(parentId);
    }
    map['position'] = Variable<String>(position);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || notes != null) {
      map['notes'] = Variable<String>(notes);
    }
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || due != null) {
      map['due'] = Variable<String>(due);
    }
    if (!nullToAbsent || completedAt != null) {
      map['completed_at'] = Variable<String>(completedAt);
    }
    if (!nullToAbsent || etag != null) {
      map['etag'] = Variable<String>(etag);
    }
    map['updated'] = Variable<String>(updated);
    map['local_updated'] = Variable<String>(localUpdated);
    map['sync_state'] = Variable<String>(syncState);
    if (!nullToAbsent || pendingOp != null) {
      map['pending_op'] = Variable<String>(pendingOp);
    }
    if (!nullToAbsent || baseTitle != null) {
      map['base_title'] = Variable<String>(baseTitle);
    }
    if (!nullToAbsent || baseNotes != null) {
      map['base_notes'] = Variable<String>(baseNotes);
    }
    if (!nullToAbsent || baseDue != null) {
      map['base_due'] = Variable<String>(baseDue);
    }
    if (!nullToAbsent || baseStatus != null) {
      map['base_status'] = Variable<String>(baseStatus);
    }
    if (!nullToAbsent || webViewLink != null) {
      map['web_view_link'] = Variable<String>(webViewLink);
    }
    return map;
  }

  TasksCompanion toCompanion(bool nullToAbsent) {
    return TasksCompanion(
      id: id == null && nullToAbsent ? const Value.absent() : Value(id),
      listId: Value(listId),
      parentId: parentId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentId),
      position: Value(position),
      title: Value(title),
      notes: notes == null && nullToAbsent
          ? const Value.absent()
          : Value(notes),
      status: Value(status),
      due: due == null && nullToAbsent ? const Value.absent() : Value(due),
      completedAt: completedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(completedAt),
      etag: etag == null && nullToAbsent ? const Value.absent() : Value(etag),
      updated: Value(updated),
      localUpdated: Value(localUpdated),
      syncState: Value(syncState),
      pendingOp: pendingOp == null && nullToAbsent
          ? const Value.absent()
          : Value(pendingOp),
      baseTitle: baseTitle == null && nullToAbsent
          ? const Value.absent()
          : Value(baseTitle),
      baseNotes: baseNotes == null && nullToAbsent
          ? const Value.absent()
          : Value(baseNotes),
      baseDue: baseDue == null && nullToAbsent
          ? const Value.absent()
          : Value(baseDue),
      baseStatus: baseStatus == null && nullToAbsent
          ? const Value.absent()
          : Value(baseStatus),
      webViewLink: webViewLink == null && nullToAbsent
          ? const Value.absent()
          : Value(webViewLink),
    );
  }

  factory Task.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Task(
      id: serializer.fromJson<String?>(json['id']),
      listId: serializer.fromJson<String>(json['list_id']),
      parentId: serializer.fromJson<String?>(json['parent_id']),
      position: serializer.fromJson<String>(json['position']),
      title: serializer.fromJson<String>(json['title']),
      notes: serializer.fromJson<String?>(json['notes']),
      status: serializer.fromJson<String>(json['status']),
      due: serializer.fromJson<String?>(json['due']),
      completedAt: serializer.fromJson<String?>(json['completed_at']),
      etag: serializer.fromJson<String?>(json['etag']),
      updated: serializer.fromJson<String>(json['updated']),
      localUpdated: serializer.fromJson<String>(json['local_updated']),
      syncState: serializer.fromJson<String>(json['sync_state']),
      pendingOp: serializer.fromJson<String?>(json['pending_op']),
      baseTitle: serializer.fromJson<String?>(json['base_title']),
      baseNotes: serializer.fromJson<String?>(json['base_notes']),
      baseDue: serializer.fromJson<String?>(json['base_due']),
      baseStatus: serializer.fromJson<String?>(json['base_status']),
      webViewLink: serializer.fromJson<String?>(json['web_view_link']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String?>(id),
      'list_id': serializer.toJson<String>(listId),
      'parent_id': serializer.toJson<String?>(parentId),
      'position': serializer.toJson<String>(position),
      'title': serializer.toJson<String>(title),
      'notes': serializer.toJson<String?>(notes),
      'status': serializer.toJson<String>(status),
      'due': serializer.toJson<String?>(due),
      'completed_at': serializer.toJson<String?>(completedAt),
      'etag': serializer.toJson<String?>(etag),
      'updated': serializer.toJson<String>(updated),
      'local_updated': serializer.toJson<String>(localUpdated),
      'sync_state': serializer.toJson<String>(syncState),
      'pending_op': serializer.toJson<String?>(pendingOp),
      'base_title': serializer.toJson<String?>(baseTitle),
      'base_notes': serializer.toJson<String?>(baseNotes),
      'base_due': serializer.toJson<String?>(baseDue),
      'base_status': serializer.toJson<String?>(baseStatus),
      'web_view_link': serializer.toJson<String?>(webViewLink),
    };
  }

  Task copyWith({
    Value<String?> id = const Value.absent(),
    String? listId,
    Value<String?> parentId = const Value.absent(),
    String? position,
    String? title,
    Value<String?> notes = const Value.absent(),
    String? status,
    Value<String?> due = const Value.absent(),
    Value<String?> completedAt = const Value.absent(),
    Value<String?> etag = const Value.absent(),
    String? updated,
    String? localUpdated,
    String? syncState,
    Value<String?> pendingOp = const Value.absent(),
    Value<String?> baseTitle = const Value.absent(),
    Value<String?> baseNotes = const Value.absent(),
    Value<String?> baseDue = const Value.absent(),
    Value<String?> baseStatus = const Value.absent(),
    Value<String?> webViewLink = const Value.absent(),
  }) => Task(
    id: id.present ? id.value : this.id,
    listId: listId ?? this.listId,
    parentId: parentId.present ? parentId.value : this.parentId,
    position: position ?? this.position,
    title: title ?? this.title,
    notes: notes.present ? notes.value : this.notes,
    status: status ?? this.status,
    due: due.present ? due.value : this.due,
    completedAt: completedAt.present ? completedAt.value : this.completedAt,
    etag: etag.present ? etag.value : this.etag,
    updated: updated ?? this.updated,
    localUpdated: localUpdated ?? this.localUpdated,
    syncState: syncState ?? this.syncState,
    pendingOp: pendingOp.present ? pendingOp.value : this.pendingOp,
    baseTitle: baseTitle.present ? baseTitle.value : this.baseTitle,
    baseNotes: baseNotes.present ? baseNotes.value : this.baseNotes,
    baseDue: baseDue.present ? baseDue.value : this.baseDue,
    baseStatus: baseStatus.present ? baseStatus.value : this.baseStatus,
    webViewLink: webViewLink.present ? webViewLink.value : this.webViewLink,
  );
  Task copyWithCompanion(TasksCompanion data) {
    return Task(
      id: data.id.present ? data.id.value : this.id,
      listId: data.listId.present ? data.listId.value : this.listId,
      parentId: data.parentId.present ? data.parentId.value : this.parentId,
      position: data.position.present ? data.position.value : this.position,
      title: data.title.present ? data.title.value : this.title,
      notes: data.notes.present ? data.notes.value : this.notes,
      status: data.status.present ? data.status.value : this.status,
      due: data.due.present ? data.due.value : this.due,
      completedAt: data.completedAt.present
          ? data.completedAt.value
          : this.completedAt,
      etag: data.etag.present ? data.etag.value : this.etag,
      updated: data.updated.present ? data.updated.value : this.updated,
      localUpdated: data.localUpdated.present
          ? data.localUpdated.value
          : this.localUpdated,
      syncState: data.syncState.present ? data.syncState.value : this.syncState,
      pendingOp: data.pendingOp.present ? data.pendingOp.value : this.pendingOp,
      baseTitle: data.baseTitle.present ? data.baseTitle.value : this.baseTitle,
      baseNotes: data.baseNotes.present ? data.baseNotes.value : this.baseNotes,
      baseDue: data.baseDue.present ? data.baseDue.value : this.baseDue,
      baseStatus: data.baseStatus.present
          ? data.baseStatus.value
          : this.baseStatus,
      webViewLink: data.webViewLink.present
          ? data.webViewLink.value
          : this.webViewLink,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Task(')
          ..write('id: $id, ')
          ..write('listId: $listId, ')
          ..write('parentId: $parentId, ')
          ..write('position: $position, ')
          ..write('title: $title, ')
          ..write('notes: $notes, ')
          ..write('status: $status, ')
          ..write('due: $due, ')
          ..write('completedAt: $completedAt, ')
          ..write('etag: $etag, ')
          ..write('updated: $updated, ')
          ..write('localUpdated: $localUpdated, ')
          ..write('syncState: $syncState, ')
          ..write('pendingOp: $pendingOp, ')
          ..write('baseTitle: $baseTitle, ')
          ..write('baseNotes: $baseNotes, ')
          ..write('baseDue: $baseDue, ')
          ..write('baseStatus: $baseStatus, ')
          ..write('webViewLink: $webViewLink')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    listId,
    parentId,
    position,
    title,
    notes,
    status,
    due,
    completedAt,
    etag,
    updated,
    localUpdated,
    syncState,
    pendingOp,
    baseTitle,
    baseNotes,
    baseDue,
    baseStatus,
    webViewLink,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Task &&
          other.id == this.id &&
          other.listId == this.listId &&
          other.parentId == this.parentId &&
          other.position == this.position &&
          other.title == this.title &&
          other.notes == this.notes &&
          other.status == this.status &&
          other.due == this.due &&
          other.completedAt == this.completedAt &&
          other.etag == this.etag &&
          other.updated == this.updated &&
          other.localUpdated == this.localUpdated &&
          other.syncState == this.syncState &&
          other.pendingOp == this.pendingOp &&
          other.baseTitle == this.baseTitle &&
          other.baseNotes == this.baseNotes &&
          other.baseDue == this.baseDue &&
          other.baseStatus == this.baseStatus &&
          other.webViewLink == this.webViewLink);
}

class TasksCompanion extends UpdateCompanion<Task> {
  final Value<String?> id;
  final Value<String> listId;
  final Value<String?> parentId;
  final Value<String> position;
  final Value<String> title;
  final Value<String?> notes;
  final Value<String> status;
  final Value<String?> due;
  final Value<String?> completedAt;
  final Value<String?> etag;
  final Value<String> updated;
  final Value<String> localUpdated;
  final Value<String> syncState;
  final Value<String?> pendingOp;
  final Value<String?> baseTitle;
  final Value<String?> baseNotes;
  final Value<String?> baseDue;
  final Value<String?> baseStatus;
  final Value<String?> webViewLink;
  final Value<int> rowid;
  const TasksCompanion({
    this.id = const Value.absent(),
    this.listId = const Value.absent(),
    this.parentId = const Value.absent(),
    this.position = const Value.absent(),
    this.title = const Value.absent(),
    this.notes = const Value.absent(),
    this.status = const Value.absent(),
    this.due = const Value.absent(),
    this.completedAt = const Value.absent(),
    this.etag = const Value.absent(),
    this.updated = const Value.absent(),
    this.localUpdated = const Value.absent(),
    this.syncState = const Value.absent(),
    this.pendingOp = const Value.absent(),
    this.baseTitle = const Value.absent(),
    this.baseNotes = const Value.absent(),
    this.baseDue = const Value.absent(),
    this.baseStatus = const Value.absent(),
    this.webViewLink = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TasksCompanion.insert({
    this.id = const Value.absent(),
    required String listId,
    this.parentId = const Value.absent(),
    required String position,
    required String title,
    this.notes = const Value.absent(),
    required String status,
    this.due = const Value.absent(),
    this.completedAt = const Value.absent(),
    this.etag = const Value.absent(),
    required String updated,
    required String localUpdated,
    required String syncState,
    this.pendingOp = const Value.absent(),
    this.baseTitle = const Value.absent(),
    this.baseNotes = const Value.absent(),
    this.baseDue = const Value.absent(),
    this.baseStatus = const Value.absent(),
    this.webViewLink = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : listId = Value(listId),
       position = Value(position),
       title = Value(title),
       status = Value(status),
       updated = Value(updated),
       localUpdated = Value(localUpdated),
       syncState = Value(syncState);
  static Insertable<Task> custom({
    Expression<String>? id,
    Expression<String>? listId,
    Expression<String>? parentId,
    Expression<String>? position,
    Expression<String>? title,
    Expression<String>? notes,
    Expression<String>? status,
    Expression<String>? due,
    Expression<String>? completedAt,
    Expression<String>? etag,
    Expression<String>? updated,
    Expression<String>? localUpdated,
    Expression<String>? syncState,
    Expression<String>? pendingOp,
    Expression<String>? baseTitle,
    Expression<String>? baseNotes,
    Expression<String>? baseDue,
    Expression<String>? baseStatus,
    Expression<String>? webViewLink,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (listId != null) 'list_id': listId,
      if (parentId != null) 'parent_id': parentId,
      if (position != null) 'position': position,
      if (title != null) 'title': title,
      if (notes != null) 'notes': notes,
      if (status != null) 'status': status,
      if (due != null) 'due': due,
      if (completedAt != null) 'completed_at': completedAt,
      if (etag != null) 'etag': etag,
      if (updated != null) 'updated': updated,
      if (localUpdated != null) 'local_updated': localUpdated,
      if (syncState != null) 'sync_state': syncState,
      if (pendingOp != null) 'pending_op': pendingOp,
      if (baseTitle != null) 'base_title': baseTitle,
      if (baseNotes != null) 'base_notes': baseNotes,
      if (baseDue != null) 'base_due': baseDue,
      if (baseStatus != null) 'base_status': baseStatus,
      if (webViewLink != null) 'web_view_link': webViewLink,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TasksCompanion copyWith({
    Value<String?>? id,
    Value<String>? listId,
    Value<String?>? parentId,
    Value<String>? position,
    Value<String>? title,
    Value<String?>? notes,
    Value<String>? status,
    Value<String?>? due,
    Value<String?>? completedAt,
    Value<String?>? etag,
    Value<String>? updated,
    Value<String>? localUpdated,
    Value<String>? syncState,
    Value<String?>? pendingOp,
    Value<String?>? baseTitle,
    Value<String?>? baseNotes,
    Value<String?>? baseDue,
    Value<String?>? baseStatus,
    Value<String?>? webViewLink,
    Value<int>? rowid,
  }) {
    return TasksCompanion(
      id: id ?? this.id,
      listId: listId ?? this.listId,
      parentId: parentId ?? this.parentId,
      position: position ?? this.position,
      title: title ?? this.title,
      notes: notes ?? this.notes,
      status: status ?? this.status,
      due: due ?? this.due,
      completedAt: completedAt ?? this.completedAt,
      etag: etag ?? this.etag,
      updated: updated ?? this.updated,
      localUpdated: localUpdated ?? this.localUpdated,
      syncState: syncState ?? this.syncState,
      pendingOp: pendingOp ?? this.pendingOp,
      baseTitle: baseTitle ?? this.baseTitle,
      baseNotes: baseNotes ?? this.baseNotes,
      baseDue: baseDue ?? this.baseDue,
      baseStatus: baseStatus ?? this.baseStatus,
      webViewLink: webViewLink ?? this.webViewLink,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (listId.present) {
      map['list_id'] = Variable<String>(listId.value);
    }
    if (parentId.present) {
      map['parent_id'] = Variable<String>(parentId.value);
    }
    if (position.present) {
      map['position'] = Variable<String>(position.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (notes.present) {
      map['notes'] = Variable<String>(notes.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (due.present) {
      map['due'] = Variable<String>(due.value);
    }
    if (completedAt.present) {
      map['completed_at'] = Variable<String>(completedAt.value);
    }
    if (etag.present) {
      map['etag'] = Variable<String>(etag.value);
    }
    if (updated.present) {
      map['updated'] = Variable<String>(updated.value);
    }
    if (localUpdated.present) {
      map['local_updated'] = Variable<String>(localUpdated.value);
    }
    if (syncState.present) {
      map['sync_state'] = Variable<String>(syncState.value);
    }
    if (pendingOp.present) {
      map['pending_op'] = Variable<String>(pendingOp.value);
    }
    if (baseTitle.present) {
      map['base_title'] = Variable<String>(baseTitle.value);
    }
    if (baseNotes.present) {
      map['base_notes'] = Variable<String>(baseNotes.value);
    }
    if (baseDue.present) {
      map['base_due'] = Variable<String>(baseDue.value);
    }
    if (baseStatus.present) {
      map['base_status'] = Variable<String>(baseStatus.value);
    }
    if (webViewLink.present) {
      map['web_view_link'] = Variable<String>(webViewLink.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TasksCompanion(')
          ..write('id: $id, ')
          ..write('listId: $listId, ')
          ..write('parentId: $parentId, ')
          ..write('position: $position, ')
          ..write('title: $title, ')
          ..write('notes: $notes, ')
          ..write('status: $status, ')
          ..write('due: $due, ')
          ..write('completedAt: $completedAt, ')
          ..write('etag: $etag, ')
          ..write('updated: $updated, ')
          ..write('localUpdated: $localUpdated, ')
          ..write('syncState: $syncState, ')
          ..write('pendingOp: $pendingOp, ')
          ..write('baseTitle: $baseTitle, ')
          ..write('baseNotes: $baseNotes, ')
          ..write('baseDue: $baseDue, ')
          ..write('baseStatus: $baseStatus, ')
          ..write('webViewLink: $webViewLink, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class PendingMoves extends Table with TableInfo<PendingMoves, PendingMove> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  PendingMoves(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _taskIdMeta = const VerificationMeta('taskId');
  late final GeneratedColumn<String> taskId = GeneratedColumn<String>(
    'task_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'PRIMARY KEY REFERENCES tasks(id)ON DELETE CASCADE',
  );
  static const VerificationMeta _listIdMeta = const VerificationMeta('listId');
  late final GeneratedColumn<String> listId = GeneratedColumn<String>(
    'list_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL REFERENCES task_lists(id)ON DELETE CASCADE',
  );
  static const VerificationMeta _parentIdMeta = const VerificationMeta(
    'parentId',
  );
  late final GeneratedColumn<String> parentId = GeneratedColumn<String>(
    'parent_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _previousIdMeta = const VerificationMeta(
    'previousId',
  );
  late final GeneratedColumn<String> previousId = GeneratedColumn<String>(
    'previous_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  @override
  List<GeneratedColumn> get $columns => [taskId, listId, parentId, previousId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'pending_moves';
  @override
  VerificationContext validateIntegrity(
    Insertable<PendingMove> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('task_id')) {
      context.handle(
        _taskIdMeta,
        taskId.isAcceptableOrUnknown(data['task_id']!, _taskIdMeta),
      );
    }
    if (data.containsKey('list_id')) {
      context.handle(
        _listIdMeta,
        listId.isAcceptableOrUnknown(data['list_id']!, _listIdMeta),
      );
    } else if (isInserting) {
      context.missing(_listIdMeta);
    }
    if (data.containsKey('parent_id')) {
      context.handle(
        _parentIdMeta,
        parentId.isAcceptableOrUnknown(data['parent_id']!, _parentIdMeta),
      );
    }
    if (data.containsKey('previous_id')) {
      context.handle(
        _previousIdMeta,
        previousId.isAcceptableOrUnknown(data['previous_id']!, _previousIdMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {taskId};
  @override
  PendingMove map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PendingMove(
      taskId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}task_id'],
      ),
      listId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}list_id'],
      )!,
      parentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}parent_id'],
      ),
      previousId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}previous_id'],
      ),
    );
  }

  @override
  PendingMoves createAlias(String alias) {
    return PendingMoves(attachedDatabase, alias);
  }

  @override
  bool get dontWriteConstraints => true;
}

class PendingMove extends DataClass implements Insertable<PendingMove> {
  final String? taskId;
  final String listId;
  final String? parentId;
  final String? previousId;
  const PendingMove({
    this.taskId,
    required this.listId,
    this.parentId,
    this.previousId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (!nullToAbsent || taskId != null) {
      map['task_id'] = Variable<String>(taskId);
    }
    map['list_id'] = Variable<String>(listId);
    if (!nullToAbsent || parentId != null) {
      map['parent_id'] = Variable<String>(parentId);
    }
    if (!nullToAbsent || previousId != null) {
      map['previous_id'] = Variable<String>(previousId);
    }
    return map;
  }

  PendingMovesCompanion toCompanion(bool nullToAbsent) {
    return PendingMovesCompanion(
      taskId: taskId == null && nullToAbsent
          ? const Value.absent()
          : Value(taskId),
      listId: Value(listId),
      parentId: parentId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentId),
      previousId: previousId == null && nullToAbsent
          ? const Value.absent()
          : Value(previousId),
    );
  }

  factory PendingMove.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PendingMove(
      taskId: serializer.fromJson<String?>(json['task_id']),
      listId: serializer.fromJson<String>(json['list_id']),
      parentId: serializer.fromJson<String?>(json['parent_id']),
      previousId: serializer.fromJson<String?>(json['previous_id']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'task_id': serializer.toJson<String?>(taskId),
      'list_id': serializer.toJson<String>(listId),
      'parent_id': serializer.toJson<String?>(parentId),
      'previous_id': serializer.toJson<String?>(previousId),
    };
  }

  PendingMove copyWith({
    Value<String?> taskId = const Value.absent(),
    String? listId,
    Value<String?> parentId = const Value.absent(),
    Value<String?> previousId = const Value.absent(),
  }) => PendingMove(
    taskId: taskId.present ? taskId.value : this.taskId,
    listId: listId ?? this.listId,
    parentId: parentId.present ? parentId.value : this.parentId,
    previousId: previousId.present ? previousId.value : this.previousId,
  );
  PendingMove copyWithCompanion(PendingMovesCompanion data) {
    return PendingMove(
      taskId: data.taskId.present ? data.taskId.value : this.taskId,
      listId: data.listId.present ? data.listId.value : this.listId,
      parentId: data.parentId.present ? data.parentId.value : this.parentId,
      previousId: data.previousId.present
          ? data.previousId.value
          : this.previousId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PendingMove(')
          ..write('taskId: $taskId, ')
          ..write('listId: $listId, ')
          ..write('parentId: $parentId, ')
          ..write('previousId: $previousId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(taskId, listId, parentId, previousId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PendingMove &&
          other.taskId == this.taskId &&
          other.listId == this.listId &&
          other.parentId == this.parentId &&
          other.previousId == this.previousId);
}

class PendingMovesCompanion extends UpdateCompanion<PendingMove> {
  final Value<String?> taskId;
  final Value<String> listId;
  final Value<String?> parentId;
  final Value<String?> previousId;
  final Value<int> rowid;
  const PendingMovesCompanion({
    this.taskId = const Value.absent(),
    this.listId = const Value.absent(),
    this.parentId = const Value.absent(),
    this.previousId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PendingMovesCompanion.insert({
    this.taskId = const Value.absent(),
    required String listId,
    this.parentId = const Value.absent(),
    this.previousId = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : listId = Value(listId);
  static Insertable<PendingMove> custom({
    Expression<String>? taskId,
    Expression<String>? listId,
    Expression<String>? parentId,
    Expression<String>? previousId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (taskId != null) 'task_id': taskId,
      if (listId != null) 'list_id': listId,
      if (parentId != null) 'parent_id': parentId,
      if (previousId != null) 'previous_id': previousId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PendingMovesCompanion copyWith({
    Value<String?>? taskId,
    Value<String>? listId,
    Value<String?>? parentId,
    Value<String?>? previousId,
    Value<int>? rowid,
  }) {
    return PendingMovesCompanion(
      taskId: taskId ?? this.taskId,
      listId: listId ?? this.listId,
      parentId: parentId ?? this.parentId,
      previousId: previousId ?? this.previousId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (taskId.present) {
      map['task_id'] = Variable<String>(taskId.value);
    }
    if (listId.present) {
      map['list_id'] = Variable<String>(listId.value);
    }
    if (parentId.present) {
      map['parent_id'] = Variable<String>(parentId.value);
    }
    if (previousId.present) {
      map['previous_id'] = Variable<String>(previousId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PendingMovesCompanion(')
          ..write('taskId: $taskId, ')
          ..write('listId: $listId, ')
          ..write('parentId: $parentId, ')
          ..write('previousId: $previousId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class SyncLog extends Table with TableInfo<SyncLog, SyncLogData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  SyncLog(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'PRIMARY KEY AUTOINCREMENT',
  );
  static const VerificationMeta _ranAtMeta = const VerificationMeta('ranAt');
  late final GeneratedColumn<String> ranAt = GeneratedColumn<String>(
    'ran_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _durationMsMeta = const VerificationMeta(
    'durationMs',
  );
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
    'duration_ms',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _pulledMeta = const VerificationMeta('pulled');
  late final GeneratedColumn<int> pulled = GeneratedColumn<int>(
    'pulled',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT 0',
    defaultValue: const CustomExpression('0'),
  );
  static const VerificationMeta _pushedMeta = const VerificationMeta('pushed');
  late final GeneratedColumn<int> pushed = GeneratedColumn<int>(
    'pushed',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT 0',
    defaultValue: const CustomExpression('0'),
  );
  static const VerificationMeta _conflictsMeta = const VerificationMeta(
    'conflicts',
  );
  late final GeneratedColumn<int> conflicts = GeneratedColumn<int>(
    'conflicts',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT 0',
    defaultValue: const CustomExpression('0'),
  );
  static const VerificationMeta _errorMeta = const VerificationMeta('error');
  late final GeneratedColumn<String> error = GeneratedColumn<String>(
    'error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    ranAt,
    durationMs,
    pulled,
    pushed,
    conflicts,
    error,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_log';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncLogData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('ran_at')) {
      context.handle(
        _ranAtMeta,
        ranAt.isAcceptableOrUnknown(data['ran_at']!, _ranAtMeta),
      );
    } else if (isInserting) {
      context.missing(_ranAtMeta);
    }
    if (data.containsKey('duration_ms')) {
      context.handle(
        _durationMsMeta,
        durationMs.isAcceptableOrUnknown(data['duration_ms']!, _durationMsMeta),
      );
    }
    if (data.containsKey('pulled')) {
      context.handle(
        _pulledMeta,
        pulled.isAcceptableOrUnknown(data['pulled']!, _pulledMeta),
      );
    }
    if (data.containsKey('pushed')) {
      context.handle(
        _pushedMeta,
        pushed.isAcceptableOrUnknown(data['pushed']!, _pushedMeta),
      );
    }
    if (data.containsKey('conflicts')) {
      context.handle(
        _conflictsMeta,
        conflicts.isAcceptableOrUnknown(data['conflicts']!, _conflictsMeta),
      );
    }
    if (data.containsKey('error')) {
      context.handle(
        _errorMeta,
        error.isAcceptableOrUnknown(data['error']!, _errorMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SyncLogData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncLogData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      ranAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}ran_at'],
      )!,
      durationMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_ms'],
      ),
      pulled: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}pulled'],
      )!,
      pushed: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}pushed'],
      )!,
      conflicts: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}conflicts'],
      )!,
      error: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}error'],
      ),
    );
  }

  @override
  SyncLog createAlias(String alias) {
    return SyncLog(attachedDatabase, alias);
  }

  @override
  bool get dontWriteConstraints => true;
}

class SyncLogData extends DataClass implements Insertable<SyncLogData> {
  final int id;
  final String ranAt;
  final int? durationMs;
  final int pulled;
  final int pushed;
  final int conflicts;
  final String? error;
  const SyncLogData({
    required this.id,
    required this.ranAt,
    this.durationMs,
    required this.pulled,
    required this.pushed,
    required this.conflicts,
    this.error,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['ran_at'] = Variable<String>(ranAt);
    if (!nullToAbsent || durationMs != null) {
      map['duration_ms'] = Variable<int>(durationMs);
    }
    map['pulled'] = Variable<int>(pulled);
    map['pushed'] = Variable<int>(pushed);
    map['conflicts'] = Variable<int>(conflicts);
    if (!nullToAbsent || error != null) {
      map['error'] = Variable<String>(error);
    }
    return map;
  }

  SyncLogCompanion toCompanion(bool nullToAbsent) {
    return SyncLogCompanion(
      id: Value(id),
      ranAt: Value(ranAt),
      durationMs: durationMs == null && nullToAbsent
          ? const Value.absent()
          : Value(durationMs),
      pulled: Value(pulled),
      pushed: Value(pushed),
      conflicts: Value(conflicts),
      error: error == null && nullToAbsent
          ? const Value.absent()
          : Value(error),
    );
  }

  factory SyncLogData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncLogData(
      id: serializer.fromJson<int>(json['id']),
      ranAt: serializer.fromJson<String>(json['ran_at']),
      durationMs: serializer.fromJson<int?>(json['duration_ms']),
      pulled: serializer.fromJson<int>(json['pulled']),
      pushed: serializer.fromJson<int>(json['pushed']),
      conflicts: serializer.fromJson<int>(json['conflicts']),
      error: serializer.fromJson<String?>(json['error']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'ran_at': serializer.toJson<String>(ranAt),
      'duration_ms': serializer.toJson<int?>(durationMs),
      'pulled': serializer.toJson<int>(pulled),
      'pushed': serializer.toJson<int>(pushed),
      'conflicts': serializer.toJson<int>(conflicts),
      'error': serializer.toJson<String?>(error),
    };
  }

  SyncLogData copyWith({
    int? id,
    String? ranAt,
    Value<int?> durationMs = const Value.absent(),
    int? pulled,
    int? pushed,
    int? conflicts,
    Value<String?> error = const Value.absent(),
  }) => SyncLogData(
    id: id ?? this.id,
    ranAt: ranAt ?? this.ranAt,
    durationMs: durationMs.present ? durationMs.value : this.durationMs,
    pulled: pulled ?? this.pulled,
    pushed: pushed ?? this.pushed,
    conflicts: conflicts ?? this.conflicts,
    error: error.present ? error.value : this.error,
  );
  SyncLogData copyWithCompanion(SyncLogCompanion data) {
    return SyncLogData(
      id: data.id.present ? data.id.value : this.id,
      ranAt: data.ranAt.present ? data.ranAt.value : this.ranAt,
      durationMs: data.durationMs.present
          ? data.durationMs.value
          : this.durationMs,
      pulled: data.pulled.present ? data.pulled.value : this.pulled,
      pushed: data.pushed.present ? data.pushed.value : this.pushed,
      conflicts: data.conflicts.present ? data.conflicts.value : this.conflicts,
      error: data.error.present ? data.error.value : this.error,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncLogData(')
          ..write('id: $id, ')
          ..write('ranAt: $ranAt, ')
          ..write('durationMs: $durationMs, ')
          ..write('pulled: $pulled, ')
          ..write('pushed: $pushed, ')
          ..write('conflicts: $conflicts, ')
          ..write('error: $error')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, ranAt, durationMs, pulled, pushed, conflicts, error);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncLogData &&
          other.id == this.id &&
          other.ranAt == this.ranAt &&
          other.durationMs == this.durationMs &&
          other.pulled == this.pulled &&
          other.pushed == this.pushed &&
          other.conflicts == this.conflicts &&
          other.error == this.error);
}

class SyncLogCompanion extends UpdateCompanion<SyncLogData> {
  final Value<int> id;
  final Value<String> ranAt;
  final Value<int?> durationMs;
  final Value<int> pulled;
  final Value<int> pushed;
  final Value<int> conflicts;
  final Value<String?> error;
  const SyncLogCompanion({
    this.id = const Value.absent(),
    this.ranAt = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.pulled = const Value.absent(),
    this.pushed = const Value.absent(),
    this.conflicts = const Value.absent(),
    this.error = const Value.absent(),
  });
  SyncLogCompanion.insert({
    this.id = const Value.absent(),
    required String ranAt,
    this.durationMs = const Value.absent(),
    this.pulled = const Value.absent(),
    this.pushed = const Value.absent(),
    this.conflicts = const Value.absent(),
    this.error = const Value.absent(),
  }) : ranAt = Value(ranAt);
  static Insertable<SyncLogData> custom({
    Expression<int>? id,
    Expression<String>? ranAt,
    Expression<int>? durationMs,
    Expression<int>? pulled,
    Expression<int>? pushed,
    Expression<int>? conflicts,
    Expression<String>? error,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (ranAt != null) 'ran_at': ranAt,
      if (durationMs != null) 'duration_ms': durationMs,
      if (pulled != null) 'pulled': pulled,
      if (pushed != null) 'pushed': pushed,
      if (conflicts != null) 'conflicts': conflicts,
      if (error != null) 'error': error,
    });
  }

  SyncLogCompanion copyWith({
    Value<int>? id,
    Value<String>? ranAt,
    Value<int?>? durationMs,
    Value<int>? pulled,
    Value<int>? pushed,
    Value<int>? conflicts,
    Value<String?>? error,
  }) {
    return SyncLogCompanion(
      id: id ?? this.id,
      ranAt: ranAt ?? this.ranAt,
      durationMs: durationMs ?? this.durationMs,
      pulled: pulled ?? this.pulled,
      pushed: pushed ?? this.pushed,
      conflicts: conflicts ?? this.conflicts,
      error: error ?? this.error,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (ranAt.present) {
      map['ran_at'] = Variable<String>(ranAt.value);
    }
    if (durationMs.present) {
      map['duration_ms'] = Variable<int>(durationMs.value);
    }
    if (pulled.present) {
      map['pulled'] = Variable<int>(pulled.value);
    }
    if (pushed.present) {
      map['pushed'] = Variable<int>(pushed.value);
    }
    if (conflicts.present) {
      map['conflicts'] = Variable<int>(conflicts.value);
    }
    if (error.present) {
      map['error'] = Variable<String>(error.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncLogCompanion(')
          ..write('id: $id, ')
          ..write('ranAt: $ranAt, ')
          ..write('durationMs: $durationMs, ')
          ..write('pulled: $pulled, ')
          ..write('pushed: $pushed, ')
          ..write('conflicts: $conflicts, ')
          ..write('error: $error')
          ..write(')'))
        .toString();
  }
}

class InflightCreates extends Table
    with TableInfo<InflightCreates, InflightCreate> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  InflightCreates(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _localIdMeta = const VerificationMeta(
    'localId',
  );
  late final GeneratedColumn<String> localId = GeneratedColumn<String>(
    'local_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'PRIMARY KEY REFERENCES tasks(id)ON DELETE CASCADE',
  );
  static const VerificationMeta _listIdMeta = const VerificationMeta('listId');
  late final GeneratedColumn<String> listId = GeneratedColumn<String>(
    'list_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL REFERENCES task_lists(id)ON DELETE CASCADE',
  );
  static const VerificationMeta _baseLocalUpdatedMeta = const VerificationMeta(
    'baseLocalUpdated',
  );
  late final GeneratedColumn<String> baseLocalUpdated = GeneratedColumn<String>(
    'base_local_updated',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  @override
  List<GeneratedColumn> get $columns => [localId, listId, baseLocalUpdated];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'inflight_creates';
  @override
  VerificationContext validateIntegrity(
    Insertable<InflightCreate> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('local_id')) {
      context.handle(
        _localIdMeta,
        localId.isAcceptableOrUnknown(data['local_id']!, _localIdMeta),
      );
    }
    if (data.containsKey('list_id')) {
      context.handle(
        _listIdMeta,
        listId.isAcceptableOrUnknown(data['list_id']!, _listIdMeta),
      );
    } else if (isInserting) {
      context.missing(_listIdMeta);
    }
    if (data.containsKey('base_local_updated')) {
      context.handle(
        _baseLocalUpdatedMeta,
        baseLocalUpdated.isAcceptableOrUnknown(
          data['base_local_updated']!,
          _baseLocalUpdatedMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {localId};
  @override
  InflightCreate map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return InflightCreate(
      localId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_id'],
      ),
      listId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}list_id'],
      )!,
      baseLocalUpdated: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_local_updated'],
      ),
    );
  }

  @override
  InflightCreates createAlias(String alias) {
    return InflightCreates(attachedDatabase, alias);
  }

  @override
  bool get dontWriteConstraints => true;
}

class InflightCreate extends DataClass implements Insertable<InflightCreate> {
  final String? localId;
  final String listId;
  final String? baseLocalUpdated;
  const InflightCreate({
    this.localId,
    required this.listId,
    this.baseLocalUpdated,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (!nullToAbsent || localId != null) {
      map['local_id'] = Variable<String>(localId);
    }
    map['list_id'] = Variable<String>(listId);
    if (!nullToAbsent || baseLocalUpdated != null) {
      map['base_local_updated'] = Variable<String>(baseLocalUpdated);
    }
    return map;
  }

  InflightCreatesCompanion toCompanion(bool nullToAbsent) {
    return InflightCreatesCompanion(
      localId: localId == null && nullToAbsent
          ? const Value.absent()
          : Value(localId),
      listId: Value(listId),
      baseLocalUpdated: baseLocalUpdated == null && nullToAbsent
          ? const Value.absent()
          : Value(baseLocalUpdated),
    );
  }

  factory InflightCreate.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return InflightCreate(
      localId: serializer.fromJson<String?>(json['local_id']),
      listId: serializer.fromJson<String>(json['list_id']),
      baseLocalUpdated: serializer.fromJson<String?>(
        json['base_local_updated'],
      ),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'local_id': serializer.toJson<String?>(localId),
      'list_id': serializer.toJson<String>(listId),
      'base_local_updated': serializer.toJson<String?>(baseLocalUpdated),
    };
  }

  InflightCreate copyWith({
    Value<String?> localId = const Value.absent(),
    String? listId,
    Value<String?> baseLocalUpdated = const Value.absent(),
  }) => InflightCreate(
    localId: localId.present ? localId.value : this.localId,
    listId: listId ?? this.listId,
    baseLocalUpdated: baseLocalUpdated.present
        ? baseLocalUpdated.value
        : this.baseLocalUpdated,
  );
  InflightCreate copyWithCompanion(InflightCreatesCompanion data) {
    return InflightCreate(
      localId: data.localId.present ? data.localId.value : this.localId,
      listId: data.listId.present ? data.listId.value : this.listId,
      baseLocalUpdated: data.baseLocalUpdated.present
          ? data.baseLocalUpdated.value
          : this.baseLocalUpdated,
    );
  }

  @override
  String toString() {
    return (StringBuffer('InflightCreate(')
          ..write('localId: $localId, ')
          ..write('listId: $listId, ')
          ..write('baseLocalUpdated: $baseLocalUpdated')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(localId, listId, baseLocalUpdated);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is InflightCreate &&
          other.localId == this.localId &&
          other.listId == this.listId &&
          other.baseLocalUpdated == this.baseLocalUpdated);
}

class InflightCreatesCompanion extends UpdateCompanion<InflightCreate> {
  final Value<String?> localId;
  final Value<String> listId;
  final Value<String?> baseLocalUpdated;
  final Value<int> rowid;
  const InflightCreatesCompanion({
    this.localId = const Value.absent(),
    this.listId = const Value.absent(),
    this.baseLocalUpdated = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  InflightCreatesCompanion.insert({
    this.localId = const Value.absent(),
    required String listId,
    this.baseLocalUpdated = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : listId = Value(listId);
  static Insertable<InflightCreate> custom({
    Expression<String>? localId,
    Expression<String>? listId,
    Expression<String>? baseLocalUpdated,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (localId != null) 'local_id': localId,
      if (listId != null) 'list_id': listId,
      if (baseLocalUpdated != null) 'base_local_updated': baseLocalUpdated,
      if (rowid != null) 'rowid': rowid,
    });
  }

  InflightCreatesCompanion copyWith({
    Value<String?>? localId,
    Value<String>? listId,
    Value<String?>? baseLocalUpdated,
    Value<int>? rowid,
  }) {
    return InflightCreatesCompanion(
      localId: localId ?? this.localId,
      listId: listId ?? this.listId,
      baseLocalUpdated: baseLocalUpdated ?? this.baseLocalUpdated,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (localId.present) {
      map['local_id'] = Variable<String>(localId.value);
    }
    if (listId.present) {
      map['list_id'] = Variable<String>(listId.value);
    }
    if (baseLocalUpdated.present) {
      map['base_local_updated'] = Variable<String>(baseLocalUpdated.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('InflightCreatesCompanion(')
          ..write('localId: $localId, ')
          ..write('listId: $listId, ')
          ..write('baseLocalUpdated: $baseLocalUpdated, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final TaskLists taskLists = TaskLists(this);
  late final Tasks tasks = Tasks(this);
  late final Index idxTasksTree = Index(
    'idx_tasks_tree',
    'CREATE INDEX idx_tasks_tree ON tasks (list_id, parent_id, position)',
  );
  late final Index idxTasksDirty = Index(
    'idx_tasks_dirty',
    'CREATE INDEX idx_tasks_dirty ON tasks (sync_state) WHERE sync_state != \'clean\'',
  );
  late final Index idxTasksDue = Index(
    'idx_tasks_due',
    'CREATE INDEX idx_tasks_due ON tasks (due) WHERE due IS NOT NULL',
  );
  late final PendingMoves pendingMoves = PendingMoves(this);
  late final SyncLog syncLog = SyncLog(this);
  late final InflightCreates inflightCreates = InflightCreates(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    taskLists,
    tasks,
    idxTasksTree,
    idxTasksDirty,
    idxTasksDue,
    pendingMoves,
    syncLog,
    inflightCreates,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'task_lists',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('tasks', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'tasks',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('pending_moves', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'task_lists',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('pending_moves', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'tasks',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('inflight_creates', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'task_lists',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('inflight_creates', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $TaskListsCreateCompanionBuilder =
    TaskListsCompanion Function({
      Value<String?> id,
      required String title,
      Value<String?> etag,
      required String updated,
      required String localUpdated,
      required String syncState,
      Value<String?> pendingOp,
      Value<int> localOnly,
      Value<int> rowid,
    });
typedef $TaskListsUpdateCompanionBuilder =
    TaskListsCompanion Function({
      Value<String?> id,
      Value<String> title,
      Value<String?> etag,
      Value<String> updated,
      Value<String> localUpdated,
      Value<String> syncState,
      Value<String?> pendingOp,
      Value<int> localOnly,
      Value<int> rowid,
    });

final class $TaskListsReferences
    extends BaseReferences<_$AppDatabase, TaskLists, TaskList> {
  $TaskListsReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<Tasks, List<Task>> _tasksRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.tasks,
    aliasName: 'task_lists__id__tasks__list_id',
  );

  $TasksProcessedTableManager get tasksRefs {
    final manager = $TasksTableManager(
      $_db,
      $_db.tasks,
    ).filter((f) => f.listId.id.sqlEquals($_itemColumn<String>('id')));

    final cache = $_typedResult.readTableOrNull(_tasksRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<PendingMoves, List<PendingMove>>
  _pendingMovesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.pendingMoves,
    aliasName: 'task_lists__id__pending_moves__list_id',
  );

  $PendingMovesProcessedTableManager get pendingMovesRefs {
    final manager = $PendingMovesTableManager(
      $_db,
      $_db.pendingMoves,
    ).filter((f) => f.listId.id.sqlEquals($_itemColumn<String>('id')));

    final cache = $_typedResult.readTableOrNull(_pendingMovesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<InflightCreates, List<InflightCreate>>
  _inflightCreatesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.inflightCreates,
    aliasName: 'task_lists__id__inflight_creates__list_id',
  );

  $InflightCreatesProcessedTableManager get inflightCreatesRefs {
    final manager = $InflightCreatesTableManager(
      $_db,
      $_db.inflightCreates,
    ).filter((f) => f.listId.id.sqlEquals($_itemColumn<String>('id')));

    final cache = $_typedResult.readTableOrNull(
      _inflightCreatesRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $TaskListsFilterComposer extends Composer<_$AppDatabase, TaskLists> {
  $TaskListsFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get etag => $composableBuilder(
    column: $table.etag,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get updated => $composableBuilder(
    column: $table.updated,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localUpdated => $composableBuilder(
    column: $table.localUpdated,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get syncState => $composableBuilder(
    column: $table.syncState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get pendingOp => $composableBuilder(
    column: $table.pendingOp,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get localOnly => $composableBuilder(
    column: $table.localOnly,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> tasksRefs(
    Expression<bool> Function($TasksFilterComposer f) f,
  ) {
    final $TasksFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.listId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $TasksFilterComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> pendingMovesRefs(
    Expression<bool> Function($PendingMovesFilterComposer f) f,
  ) {
    final $PendingMovesFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.pendingMoves,
      getReferencedColumn: (t) => t.listId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $PendingMovesFilterComposer(
            $db: $db,
            $table: $db.pendingMoves,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> inflightCreatesRefs(
    Expression<bool> Function($InflightCreatesFilterComposer f) f,
  ) {
    final $InflightCreatesFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.inflightCreates,
      getReferencedColumn: (t) => t.listId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $InflightCreatesFilterComposer(
            $db: $db,
            $table: $db.inflightCreates,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $TaskListsOrderingComposer extends Composer<_$AppDatabase, TaskLists> {
  $TaskListsOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get etag => $composableBuilder(
    column: $table.etag,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get updated => $composableBuilder(
    column: $table.updated,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localUpdated => $composableBuilder(
    column: $table.localUpdated,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get syncState => $composableBuilder(
    column: $table.syncState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get pendingOp => $composableBuilder(
    column: $table.pendingOp,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get localOnly => $composableBuilder(
    column: $table.localOnly,
    builder: (column) => ColumnOrderings(column),
  );
}

class $TaskListsAnnotationComposer extends Composer<_$AppDatabase, TaskLists> {
  $TaskListsAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get etag =>
      $composableBuilder(column: $table.etag, builder: (column) => column);

  GeneratedColumn<String> get updated =>
      $composableBuilder(column: $table.updated, builder: (column) => column);

  GeneratedColumn<String> get localUpdated => $composableBuilder(
    column: $table.localUpdated,
    builder: (column) => column,
  );

  GeneratedColumn<String> get syncState =>
      $composableBuilder(column: $table.syncState, builder: (column) => column);

  GeneratedColumn<String> get pendingOp =>
      $composableBuilder(column: $table.pendingOp, builder: (column) => column);

  GeneratedColumn<int> get localOnly =>
      $composableBuilder(column: $table.localOnly, builder: (column) => column);

  Expression<T> tasksRefs<T extends Object>(
    Expression<T> Function($TasksAnnotationComposer a) f,
  ) {
    final $TasksAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.listId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $TasksAnnotationComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> pendingMovesRefs<T extends Object>(
    Expression<T> Function($PendingMovesAnnotationComposer a) f,
  ) {
    final $PendingMovesAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.pendingMoves,
      getReferencedColumn: (t) => t.listId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $PendingMovesAnnotationComposer(
            $db: $db,
            $table: $db.pendingMoves,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> inflightCreatesRefs<T extends Object>(
    Expression<T> Function($InflightCreatesAnnotationComposer a) f,
  ) {
    final $InflightCreatesAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.inflightCreates,
      getReferencedColumn: (t) => t.listId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $InflightCreatesAnnotationComposer(
            $db: $db,
            $table: $db.inflightCreates,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $TaskListsTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          TaskLists,
          TaskList,
          $TaskListsFilterComposer,
          $TaskListsOrderingComposer,
          $TaskListsAnnotationComposer,
          $TaskListsCreateCompanionBuilder,
          $TaskListsUpdateCompanionBuilder,
          (TaskList, $TaskListsReferences),
          TaskList,
          PrefetchHooks Function({
            bool tasksRefs,
            bool pendingMovesRefs,
            bool inflightCreatesRefs,
          })
        > {
  $TaskListsTableManager(_$AppDatabase db, TaskLists table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $TaskListsFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $TaskListsOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $TaskListsAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String?> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> etag = const Value.absent(),
                Value<String> updated = const Value.absent(),
                Value<String> localUpdated = const Value.absent(),
                Value<String> syncState = const Value.absent(),
                Value<String?> pendingOp = const Value.absent(),
                Value<int> localOnly = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TaskListsCompanion(
                id: id,
                title: title,
                etag: etag,
                updated: updated,
                localUpdated: localUpdated,
                syncState: syncState,
                pendingOp: pendingOp,
                localOnly: localOnly,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                Value<String?> id = const Value.absent(),
                required String title,
                Value<String?> etag = const Value.absent(),
                required String updated,
                required String localUpdated,
                required String syncState,
                Value<String?> pendingOp = const Value.absent(),
                Value<int> localOnly = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TaskListsCompanion.insert(
                id: id,
                title: title,
                etag: etag,
                updated: updated,
                localUpdated: localUpdated,
                syncState: syncState,
                pendingOp: pendingOp,
                localOnly: localOnly,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (e.readTable(table), $TaskListsReferences(db, table, e)),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                tasksRefs = false,
                pendingMovesRefs = false,
                inflightCreatesRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (tasksRefs) db.tasks,
                    if (pendingMovesRefs) db.pendingMoves,
                    if (inflightCreatesRefs) db.inflightCreates,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (tasksRefs)
                        await $_getPrefetchedData<TaskList, TaskLists, Task>(
                          currentTable: table,
                          referencedTable: $TaskListsReferences._tasksRefsTable(
                            db,
                          ),
                          managerFromTypedResult: (p0) =>
                              $TaskListsReferences(db, table, p0).tasksRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.listId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (pendingMovesRefs)
                        await $_getPrefetchedData<
                          TaskList,
                          TaskLists,
                          PendingMove
                        >(
                          currentTable: table,
                          referencedTable: $TaskListsReferences
                              ._pendingMovesRefsTable(db),
                          managerFromTypedResult: (p0) => $TaskListsReferences(
                            db,
                            table,
                            p0,
                          ).pendingMovesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.listId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (inflightCreatesRefs)
                        await $_getPrefetchedData<
                          TaskList,
                          TaskLists,
                          InflightCreate
                        >(
                          currentTable: table,
                          referencedTable: $TaskListsReferences
                              ._inflightCreatesRefsTable(db),
                          managerFromTypedResult: (p0) => $TaskListsReferences(
                            db,
                            table,
                            p0,
                          ).inflightCreatesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.listId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $TaskListsProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      TaskLists,
      TaskList,
      $TaskListsFilterComposer,
      $TaskListsOrderingComposer,
      $TaskListsAnnotationComposer,
      $TaskListsCreateCompanionBuilder,
      $TaskListsUpdateCompanionBuilder,
      (TaskList, $TaskListsReferences),
      TaskList,
      PrefetchHooks Function({
        bool tasksRefs,
        bool pendingMovesRefs,
        bool inflightCreatesRefs,
      })
    >;
typedef $TasksCreateCompanionBuilder =
    TasksCompanion Function({
      Value<String?> id,
      required String listId,
      Value<String?> parentId,
      required String position,
      required String title,
      Value<String?> notes,
      required String status,
      Value<String?> due,
      Value<String?> completedAt,
      Value<String?> etag,
      required String updated,
      required String localUpdated,
      required String syncState,
      Value<String?> pendingOp,
      Value<String?> baseTitle,
      Value<String?> baseNotes,
      Value<String?> baseDue,
      Value<String?> baseStatus,
      Value<String?> webViewLink,
      Value<int> rowid,
    });
typedef $TasksUpdateCompanionBuilder =
    TasksCompanion Function({
      Value<String?> id,
      Value<String> listId,
      Value<String?> parentId,
      Value<String> position,
      Value<String> title,
      Value<String?> notes,
      Value<String> status,
      Value<String?> due,
      Value<String?> completedAt,
      Value<String?> etag,
      Value<String> updated,
      Value<String> localUpdated,
      Value<String> syncState,
      Value<String?> pendingOp,
      Value<String?> baseTitle,
      Value<String?> baseNotes,
      Value<String?> baseDue,
      Value<String?> baseStatus,
      Value<String?> webViewLink,
      Value<int> rowid,
    });

final class $TasksReferences
    extends BaseReferences<_$AppDatabase, Tasks, Task> {
  $TasksReferences(super.$_db, super.$_table, super.$_typedResult);

  static TaskLists _listIdTable(_$AppDatabase db) =>
      db.taskLists.createAlias('tasks__list_id__task_lists__id');

  $TaskListsProcessedTableManager get listId {
    final $_column = $_itemColumn<String>('list_id')!;

    final manager = $TaskListsTableManager(
      $_db,
      $_db.taskLists,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_listIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<PendingMoves, List<PendingMove>>
  _pendingMovesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.pendingMoves,
    aliasName: 'tasks__id__pending_moves__task_id',
  );

  $PendingMovesProcessedTableManager get pendingMovesRefs {
    final manager = $PendingMovesTableManager(
      $_db,
      $_db.pendingMoves,
    ).filter((f) => f.taskId.id.sqlEquals($_itemColumn<String>('id')));

    final cache = $_typedResult.readTableOrNull(_pendingMovesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<InflightCreates, List<InflightCreate>>
  _inflightCreatesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.inflightCreates,
    aliasName: 'tasks__id__inflight_creates__local_id',
  );

  $InflightCreatesProcessedTableManager get inflightCreatesRefs {
    final manager = $InflightCreatesTableManager(
      $_db,
      $_db.inflightCreates,
    ).filter((f) => f.localId.id.sqlEquals($_itemColumn<String>('id')));

    final cache = $_typedResult.readTableOrNull(
      _inflightCreatesRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $TasksFilterComposer extends Composer<_$AppDatabase, Tasks> {
  $TasksFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get due => $composableBuilder(
    column: $table.due,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get completedAt => $composableBuilder(
    column: $table.completedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get etag => $composableBuilder(
    column: $table.etag,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get updated => $composableBuilder(
    column: $table.updated,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localUpdated => $composableBuilder(
    column: $table.localUpdated,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get syncState => $composableBuilder(
    column: $table.syncState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get pendingOp => $composableBuilder(
    column: $table.pendingOp,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseTitle => $composableBuilder(
    column: $table.baseTitle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseNotes => $composableBuilder(
    column: $table.baseNotes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseDue => $composableBuilder(
    column: $table.baseDue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseStatus => $composableBuilder(
    column: $table.baseStatus,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get webViewLink => $composableBuilder(
    column: $table.webViewLink,
    builder: (column) => ColumnFilters(column),
  );

  $TaskListsFilterComposer get listId {
    final $TaskListsFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.listId,
      referencedTable: $db.taskLists,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $TaskListsFilterComposer(
            $db: $db,
            $table: $db.taskLists,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> pendingMovesRefs(
    Expression<bool> Function($PendingMovesFilterComposer f) f,
  ) {
    final $PendingMovesFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.pendingMoves,
      getReferencedColumn: (t) => t.taskId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $PendingMovesFilterComposer(
            $db: $db,
            $table: $db.pendingMoves,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> inflightCreatesRefs(
    Expression<bool> Function($InflightCreatesFilterComposer f) f,
  ) {
    final $InflightCreatesFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.inflightCreates,
      getReferencedColumn: (t) => t.localId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $InflightCreatesFilterComposer(
            $db: $db,
            $table: $db.inflightCreates,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $TasksOrderingComposer extends Composer<_$AppDatabase, Tasks> {
  $TasksOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get due => $composableBuilder(
    column: $table.due,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get completedAt => $composableBuilder(
    column: $table.completedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get etag => $composableBuilder(
    column: $table.etag,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get updated => $composableBuilder(
    column: $table.updated,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localUpdated => $composableBuilder(
    column: $table.localUpdated,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get syncState => $composableBuilder(
    column: $table.syncState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get pendingOp => $composableBuilder(
    column: $table.pendingOp,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseTitle => $composableBuilder(
    column: $table.baseTitle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseNotes => $composableBuilder(
    column: $table.baseNotes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseDue => $composableBuilder(
    column: $table.baseDue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseStatus => $composableBuilder(
    column: $table.baseStatus,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get webViewLink => $composableBuilder(
    column: $table.webViewLink,
    builder: (column) => ColumnOrderings(column),
  );

  $TaskListsOrderingComposer get listId {
    final $TaskListsOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.listId,
      referencedTable: $db.taskLists,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $TaskListsOrderingComposer(
            $db: $db,
            $table: $db.taskLists,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $TasksAnnotationComposer extends Composer<_$AppDatabase, Tasks> {
  $TasksAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get parentId =>
      $composableBuilder(column: $table.parentId, builder: (column) => column);

  GeneratedColumn<String> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get due =>
      $composableBuilder(column: $table.due, builder: (column) => column);

  GeneratedColumn<String> get completedAt => $composableBuilder(
    column: $table.completedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get etag =>
      $composableBuilder(column: $table.etag, builder: (column) => column);

  GeneratedColumn<String> get updated =>
      $composableBuilder(column: $table.updated, builder: (column) => column);

  GeneratedColumn<String> get localUpdated => $composableBuilder(
    column: $table.localUpdated,
    builder: (column) => column,
  );

  GeneratedColumn<String> get syncState =>
      $composableBuilder(column: $table.syncState, builder: (column) => column);

  GeneratedColumn<String> get pendingOp =>
      $composableBuilder(column: $table.pendingOp, builder: (column) => column);

  GeneratedColumn<String> get baseTitle =>
      $composableBuilder(column: $table.baseTitle, builder: (column) => column);

  GeneratedColumn<String> get baseNotes =>
      $composableBuilder(column: $table.baseNotes, builder: (column) => column);

  GeneratedColumn<String> get baseDue =>
      $composableBuilder(column: $table.baseDue, builder: (column) => column);

  GeneratedColumn<String> get baseStatus => $composableBuilder(
    column: $table.baseStatus,
    builder: (column) => column,
  );

  GeneratedColumn<String> get webViewLink => $composableBuilder(
    column: $table.webViewLink,
    builder: (column) => column,
  );

  $TaskListsAnnotationComposer get listId {
    final $TaskListsAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.listId,
      referencedTable: $db.taskLists,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $TaskListsAnnotationComposer(
            $db: $db,
            $table: $db.taskLists,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> pendingMovesRefs<T extends Object>(
    Expression<T> Function($PendingMovesAnnotationComposer a) f,
  ) {
    final $PendingMovesAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.pendingMoves,
      getReferencedColumn: (t) => t.taskId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $PendingMovesAnnotationComposer(
            $db: $db,
            $table: $db.pendingMoves,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> inflightCreatesRefs<T extends Object>(
    Expression<T> Function($InflightCreatesAnnotationComposer a) f,
  ) {
    final $InflightCreatesAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.inflightCreates,
      getReferencedColumn: (t) => t.localId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $InflightCreatesAnnotationComposer(
            $db: $db,
            $table: $db.inflightCreates,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $TasksTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          Tasks,
          Task,
          $TasksFilterComposer,
          $TasksOrderingComposer,
          $TasksAnnotationComposer,
          $TasksCreateCompanionBuilder,
          $TasksUpdateCompanionBuilder,
          (Task, $TasksReferences),
          Task,
          PrefetchHooks Function({
            bool listId,
            bool pendingMovesRefs,
            bool inflightCreatesRefs,
          })
        > {
  $TasksTableManager(_$AppDatabase db, Tasks table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $TasksFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $TasksOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $TasksAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String?> id = const Value.absent(),
                Value<String> listId = const Value.absent(),
                Value<String?> parentId = const Value.absent(),
                Value<String> position = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String?> due = const Value.absent(),
                Value<String?> completedAt = const Value.absent(),
                Value<String?> etag = const Value.absent(),
                Value<String> updated = const Value.absent(),
                Value<String> localUpdated = const Value.absent(),
                Value<String> syncState = const Value.absent(),
                Value<String?> pendingOp = const Value.absent(),
                Value<String?> baseTitle = const Value.absent(),
                Value<String?> baseNotes = const Value.absent(),
                Value<String?> baseDue = const Value.absent(),
                Value<String?> baseStatus = const Value.absent(),
                Value<String?> webViewLink = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TasksCompanion(
                id: id,
                listId: listId,
                parentId: parentId,
                position: position,
                title: title,
                notes: notes,
                status: status,
                due: due,
                completedAt: completedAt,
                etag: etag,
                updated: updated,
                localUpdated: localUpdated,
                syncState: syncState,
                pendingOp: pendingOp,
                baseTitle: baseTitle,
                baseNotes: baseNotes,
                baseDue: baseDue,
                baseStatus: baseStatus,
                webViewLink: webViewLink,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                Value<String?> id = const Value.absent(),
                required String listId,
                Value<String?> parentId = const Value.absent(),
                required String position,
                required String title,
                Value<String?> notes = const Value.absent(),
                required String status,
                Value<String?> due = const Value.absent(),
                Value<String?> completedAt = const Value.absent(),
                Value<String?> etag = const Value.absent(),
                required String updated,
                required String localUpdated,
                required String syncState,
                Value<String?> pendingOp = const Value.absent(),
                Value<String?> baseTitle = const Value.absent(),
                Value<String?> baseNotes = const Value.absent(),
                Value<String?> baseDue = const Value.absent(),
                Value<String?> baseStatus = const Value.absent(),
                Value<String?> webViewLink = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TasksCompanion.insert(
                id: id,
                listId: listId,
                parentId: parentId,
                position: position,
                title: title,
                notes: notes,
                status: status,
                due: due,
                completedAt: completedAt,
                etag: etag,
                updated: updated,
                localUpdated: localUpdated,
                syncState: syncState,
                pendingOp: pendingOp,
                baseTitle: baseTitle,
                baseNotes: baseNotes,
                baseDue: baseDue,
                baseStatus: baseStatus,
                webViewLink: webViewLink,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), $TasksReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback:
              ({
                listId = false,
                pendingMovesRefs = false,
                inflightCreatesRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (pendingMovesRefs) db.pendingMoves,
                    if (inflightCreatesRefs) db.inflightCreates,
                  ],
                  addJoins:
                      <
                        T extends TableManagerState<
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic
                        >
                      >(state) {
                        if (listId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.listId,
                                    referencedTable: $TasksReferences
                                        ._listIdTable(db),
                                    referencedColumn: $TasksReferences
                                        ._listIdTable(db)
                                        .id,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (pendingMovesRefs)
                        await $_getPrefetchedData<Task, Tasks, PendingMove>(
                          currentTable: table,
                          referencedTable: $TasksReferences
                              ._pendingMovesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $TasksReferences(db, table, p0).pendingMovesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.taskId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (inflightCreatesRefs)
                        await $_getPrefetchedData<Task, Tasks, InflightCreate>(
                          currentTable: table,
                          referencedTable: $TasksReferences
                              ._inflightCreatesRefsTable(db),
                          managerFromTypedResult: (p0) => $TasksReferences(
                            db,
                            table,
                            p0,
                          ).inflightCreatesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.localId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $TasksProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      Tasks,
      Task,
      $TasksFilterComposer,
      $TasksOrderingComposer,
      $TasksAnnotationComposer,
      $TasksCreateCompanionBuilder,
      $TasksUpdateCompanionBuilder,
      (Task, $TasksReferences),
      Task,
      PrefetchHooks Function({
        bool listId,
        bool pendingMovesRefs,
        bool inflightCreatesRefs,
      })
    >;
typedef $PendingMovesCreateCompanionBuilder =
    PendingMovesCompanion Function({
      Value<String?> taskId,
      required String listId,
      Value<String?> parentId,
      Value<String?> previousId,
      Value<int> rowid,
    });
typedef $PendingMovesUpdateCompanionBuilder =
    PendingMovesCompanion Function({
      Value<String?> taskId,
      Value<String> listId,
      Value<String?> parentId,
      Value<String?> previousId,
      Value<int> rowid,
    });

final class $PendingMovesReferences
    extends BaseReferences<_$AppDatabase, PendingMoves, PendingMove> {
  $PendingMovesReferences(super.$_db, super.$_table, super.$_typedResult);

  static Tasks _taskIdTable(_$AppDatabase db) =>
      db.tasks.createAlias('pending_moves__task_id__tasks__id');

  $TasksProcessedTableManager? get taskId {
    final $_column = $_itemColumn<String>('task_id');
    if ($_column == null) return null;
    final manager = $TasksTableManager(
      $_db,
      $_db.tasks,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_taskIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static TaskLists _listIdTable(_$AppDatabase db) =>
      db.taskLists.createAlias('pending_moves__list_id__task_lists__id');

  $TaskListsProcessedTableManager get listId {
    final $_column = $_itemColumn<String>('list_id')!;

    final manager = $TaskListsTableManager(
      $_db,
      $_db.taskLists,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_listIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $PendingMovesFilterComposer
    extends Composer<_$AppDatabase, PendingMoves> {
  $PendingMovesFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get previousId => $composableBuilder(
    column: $table.previousId,
    builder: (column) => ColumnFilters(column),
  );

  $TasksFilterComposer get taskId {
    final $TasksFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $TasksFilterComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $TaskListsFilterComposer get listId {
    final $TaskListsFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.listId,
      referencedTable: $db.taskLists,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $TaskListsFilterComposer(
            $db: $db,
            $table: $db.taskLists,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $PendingMovesOrderingComposer
    extends Composer<_$AppDatabase, PendingMoves> {
  $PendingMovesOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get previousId => $composableBuilder(
    column: $table.previousId,
    builder: (column) => ColumnOrderings(column),
  );

  $TasksOrderingComposer get taskId {
    final $TasksOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $TasksOrderingComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $TaskListsOrderingComposer get listId {
    final $TaskListsOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.listId,
      referencedTable: $db.taskLists,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $TaskListsOrderingComposer(
            $db: $db,
            $table: $db.taskLists,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $PendingMovesAnnotationComposer
    extends Composer<_$AppDatabase, PendingMoves> {
  $PendingMovesAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get parentId =>
      $composableBuilder(column: $table.parentId, builder: (column) => column);

  GeneratedColumn<String> get previousId => $composableBuilder(
    column: $table.previousId,
    builder: (column) => column,
  );

  $TasksAnnotationComposer get taskId {
    final $TasksAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $TasksAnnotationComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $TaskListsAnnotationComposer get listId {
    final $TaskListsAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.listId,
      referencedTable: $db.taskLists,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $TaskListsAnnotationComposer(
            $db: $db,
            $table: $db.taskLists,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $PendingMovesTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          PendingMoves,
          PendingMove,
          $PendingMovesFilterComposer,
          $PendingMovesOrderingComposer,
          $PendingMovesAnnotationComposer,
          $PendingMovesCreateCompanionBuilder,
          $PendingMovesUpdateCompanionBuilder,
          (PendingMove, $PendingMovesReferences),
          PendingMove,
          PrefetchHooks Function({bool taskId, bool listId})
        > {
  $PendingMovesTableManager(_$AppDatabase db, PendingMoves table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $PendingMovesFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $PendingMovesOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $PendingMovesAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String?> taskId = const Value.absent(),
                Value<String> listId = const Value.absent(),
                Value<String?> parentId = const Value.absent(),
                Value<String?> previousId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PendingMovesCompanion(
                taskId: taskId,
                listId: listId,
                parentId: parentId,
                previousId: previousId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                Value<String?> taskId = const Value.absent(),
                required String listId,
                Value<String?> parentId = const Value.absent(),
                Value<String?> previousId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PendingMovesCompanion.insert(
                taskId: taskId,
                listId: listId,
                parentId: parentId,
                previousId: previousId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) =>
                    (e.readTable(table), $PendingMovesReferences(db, table, e)),
              )
              .toList(),
          prefetchHooksCallback: ({taskId = false, listId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (taskId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.taskId,
                                referencedTable: $PendingMovesReferences
                                    ._taskIdTable(db),
                                referencedColumn: $PendingMovesReferences
                                    ._taskIdTable(db)
                                    .id,
                              )
                              as T;
                    }
                    if (listId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.listId,
                                referencedTable: $PendingMovesReferences
                                    ._listIdTable(db),
                                referencedColumn: $PendingMovesReferences
                                    ._listIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $PendingMovesProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      PendingMoves,
      PendingMove,
      $PendingMovesFilterComposer,
      $PendingMovesOrderingComposer,
      $PendingMovesAnnotationComposer,
      $PendingMovesCreateCompanionBuilder,
      $PendingMovesUpdateCompanionBuilder,
      (PendingMove, $PendingMovesReferences),
      PendingMove,
      PrefetchHooks Function({bool taskId, bool listId})
    >;
typedef $SyncLogCreateCompanionBuilder =
    SyncLogCompanion Function({
      Value<int> id,
      required String ranAt,
      Value<int?> durationMs,
      Value<int> pulled,
      Value<int> pushed,
      Value<int> conflicts,
      Value<String?> error,
    });
typedef $SyncLogUpdateCompanionBuilder =
    SyncLogCompanion Function({
      Value<int> id,
      Value<String> ranAt,
      Value<int?> durationMs,
      Value<int> pulled,
      Value<int> pushed,
      Value<int> conflicts,
      Value<String?> error,
    });

class $SyncLogFilterComposer extends Composer<_$AppDatabase, SyncLog> {
  $SyncLogFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ranAt => $composableBuilder(
    column: $table.ranAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get pulled => $composableBuilder(
    column: $table.pulled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get pushed => $composableBuilder(
    column: $table.pushed,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get conflicts => $composableBuilder(
    column: $table.conflicts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get error => $composableBuilder(
    column: $table.error,
    builder: (column) => ColumnFilters(column),
  );
}

class $SyncLogOrderingComposer extends Composer<_$AppDatabase, SyncLog> {
  $SyncLogOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ranAt => $composableBuilder(
    column: $table.ranAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get pulled => $composableBuilder(
    column: $table.pulled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get pushed => $composableBuilder(
    column: $table.pushed,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get conflicts => $composableBuilder(
    column: $table.conflicts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get error => $composableBuilder(
    column: $table.error,
    builder: (column) => ColumnOrderings(column),
  );
}

class $SyncLogAnnotationComposer extends Composer<_$AppDatabase, SyncLog> {
  $SyncLogAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get ranAt =>
      $composableBuilder(column: $table.ranAt, builder: (column) => column);

  GeneratedColumn<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => column,
  );

  GeneratedColumn<int> get pulled =>
      $composableBuilder(column: $table.pulled, builder: (column) => column);

  GeneratedColumn<int> get pushed =>
      $composableBuilder(column: $table.pushed, builder: (column) => column);

  GeneratedColumn<int> get conflicts =>
      $composableBuilder(column: $table.conflicts, builder: (column) => column);

  GeneratedColumn<String> get error =>
      $composableBuilder(column: $table.error, builder: (column) => column);
}

class $SyncLogTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          SyncLog,
          SyncLogData,
          $SyncLogFilterComposer,
          $SyncLogOrderingComposer,
          $SyncLogAnnotationComposer,
          $SyncLogCreateCompanionBuilder,
          $SyncLogUpdateCompanionBuilder,
          (SyncLogData, BaseReferences<_$AppDatabase, SyncLog, SyncLogData>),
          SyncLogData,
          PrefetchHooks Function()
        > {
  $SyncLogTableManager(_$AppDatabase db, SyncLog table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $SyncLogFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $SyncLogOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $SyncLogAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> ranAt = const Value.absent(),
                Value<int?> durationMs = const Value.absent(),
                Value<int> pulled = const Value.absent(),
                Value<int> pushed = const Value.absent(),
                Value<int> conflicts = const Value.absent(),
                Value<String?> error = const Value.absent(),
              }) => SyncLogCompanion(
                id: id,
                ranAt: ranAt,
                durationMs: durationMs,
                pulled: pulled,
                pushed: pushed,
                conflicts: conflicts,
                error: error,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String ranAt,
                Value<int?> durationMs = const Value.absent(),
                Value<int> pulled = const Value.absent(),
                Value<int> pushed = const Value.absent(),
                Value<int> conflicts = const Value.absent(),
                Value<String?> error = const Value.absent(),
              }) => SyncLogCompanion.insert(
                id: id,
                ranAt: ranAt,
                durationMs: durationMs,
                pulled: pulled,
                pushed: pushed,
                conflicts: conflicts,
                error: error,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $SyncLogProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      SyncLog,
      SyncLogData,
      $SyncLogFilterComposer,
      $SyncLogOrderingComposer,
      $SyncLogAnnotationComposer,
      $SyncLogCreateCompanionBuilder,
      $SyncLogUpdateCompanionBuilder,
      (SyncLogData, BaseReferences<_$AppDatabase, SyncLog, SyncLogData>),
      SyncLogData,
      PrefetchHooks Function()
    >;
typedef $InflightCreatesCreateCompanionBuilder =
    InflightCreatesCompanion Function({
      Value<String?> localId,
      required String listId,
      Value<String?> baseLocalUpdated,
      Value<int> rowid,
    });
typedef $InflightCreatesUpdateCompanionBuilder =
    InflightCreatesCompanion Function({
      Value<String?> localId,
      Value<String> listId,
      Value<String?> baseLocalUpdated,
      Value<int> rowid,
    });

final class $InflightCreatesReferences
    extends BaseReferences<_$AppDatabase, InflightCreates, InflightCreate> {
  $InflightCreatesReferences(super.$_db, super.$_table, super.$_typedResult);

  static Tasks _localIdTable(_$AppDatabase db) =>
      db.tasks.createAlias('inflight_creates__local_id__tasks__id');

  $TasksProcessedTableManager? get localId {
    final $_column = $_itemColumn<String>('local_id');
    if ($_column == null) return null;
    final manager = $TasksTableManager(
      $_db,
      $_db.tasks,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_localIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static TaskLists _listIdTable(_$AppDatabase db) =>
      db.taskLists.createAlias('inflight_creates__list_id__task_lists__id');

  $TaskListsProcessedTableManager get listId {
    final $_column = $_itemColumn<String>('list_id')!;

    final manager = $TaskListsTableManager(
      $_db,
      $_db.taskLists,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_listIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $InflightCreatesFilterComposer
    extends Composer<_$AppDatabase, InflightCreates> {
  $InflightCreatesFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get baseLocalUpdated => $composableBuilder(
    column: $table.baseLocalUpdated,
    builder: (column) => ColumnFilters(column),
  );

  $TasksFilterComposer get localId {
    final $TasksFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.localId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $TasksFilterComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $TaskListsFilterComposer get listId {
    final $TaskListsFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.listId,
      referencedTable: $db.taskLists,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $TaskListsFilterComposer(
            $db: $db,
            $table: $db.taskLists,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $InflightCreatesOrderingComposer
    extends Composer<_$AppDatabase, InflightCreates> {
  $InflightCreatesOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get baseLocalUpdated => $composableBuilder(
    column: $table.baseLocalUpdated,
    builder: (column) => ColumnOrderings(column),
  );

  $TasksOrderingComposer get localId {
    final $TasksOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.localId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $TasksOrderingComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $TaskListsOrderingComposer get listId {
    final $TaskListsOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.listId,
      referencedTable: $db.taskLists,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $TaskListsOrderingComposer(
            $db: $db,
            $table: $db.taskLists,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $InflightCreatesAnnotationComposer
    extends Composer<_$AppDatabase, InflightCreates> {
  $InflightCreatesAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get baseLocalUpdated => $composableBuilder(
    column: $table.baseLocalUpdated,
    builder: (column) => column,
  );

  $TasksAnnotationComposer get localId {
    final $TasksAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.localId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $TasksAnnotationComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $TaskListsAnnotationComposer get listId {
    final $TaskListsAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.listId,
      referencedTable: $db.taskLists,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $TaskListsAnnotationComposer(
            $db: $db,
            $table: $db.taskLists,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $InflightCreatesTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          InflightCreates,
          InflightCreate,
          $InflightCreatesFilterComposer,
          $InflightCreatesOrderingComposer,
          $InflightCreatesAnnotationComposer,
          $InflightCreatesCreateCompanionBuilder,
          $InflightCreatesUpdateCompanionBuilder,
          (InflightCreate, $InflightCreatesReferences),
          InflightCreate,
          PrefetchHooks Function({bool localId, bool listId})
        > {
  $InflightCreatesTableManager(_$AppDatabase db, InflightCreates table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $InflightCreatesFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $InflightCreatesOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $InflightCreatesAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String?> localId = const Value.absent(),
                Value<String> listId = const Value.absent(),
                Value<String?> baseLocalUpdated = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => InflightCreatesCompanion(
                localId: localId,
                listId: listId,
                baseLocalUpdated: baseLocalUpdated,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                Value<String?> localId = const Value.absent(),
                required String listId,
                Value<String?> baseLocalUpdated = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => InflightCreatesCompanion.insert(
                localId: localId,
                listId: listId,
                baseLocalUpdated: baseLocalUpdated,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $InflightCreatesReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({localId = false, listId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (localId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.localId,
                                referencedTable: $InflightCreatesReferences
                                    ._localIdTable(db),
                                referencedColumn: $InflightCreatesReferences
                                    ._localIdTable(db)
                                    .id,
                              )
                              as T;
                    }
                    if (listId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.listId,
                                referencedTable: $InflightCreatesReferences
                                    ._listIdTable(db),
                                referencedColumn: $InflightCreatesReferences
                                    ._listIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $InflightCreatesProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      InflightCreates,
      InflightCreate,
      $InflightCreatesFilterComposer,
      $InflightCreatesOrderingComposer,
      $InflightCreatesAnnotationComposer,
      $InflightCreatesCreateCompanionBuilder,
      $InflightCreatesUpdateCompanionBuilder,
      (InflightCreate, $InflightCreatesReferences),
      InflightCreate,
      PrefetchHooks Function({bool localId, bool listId})
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $TaskListsTableManager get taskLists =>
      $TaskListsTableManager(_db, _db.taskLists);
  $TasksTableManager get tasks => $TasksTableManager(_db, _db.tasks);
  $PendingMovesTableManager get pendingMoves =>
      $PendingMovesTableManager(_db, _db.pendingMoves);
  $SyncLogTableManager get syncLog => $SyncLogTableManager(_db, _db.syncLog);
  $InflightCreatesTableManager get inflightCreates =>
      $InflightCreatesTableManager(_db, _db.inflightCreates);
}
