// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $AccountsTable extends Accounts with TableInfo<$AccountsTable, Account> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AccountsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _googleSubjectMeta = const VerificationMeta(
    'googleSubject',
  );
  @override
  late final GeneratedColumn<String> googleSubject = GeneratedColumn<String>(
    'google_subject',
    aliasedName,
    false,
    check: () => ComparableExpr(googleSubject.length).isBiggerThanValue(0),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'),
  );
  @override
  List<GeneratedColumn> get $columns => [id, googleSubject];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'accounts';
  @override
  VerificationContext validateIntegrity(
    Insertable<Account> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('google_subject')) {
      context.handle(
        _googleSubjectMeta,
        googleSubject.isAcceptableOrUnknown(
          data['google_subject']!,
          _googleSubjectMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_googleSubjectMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Account map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Account(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      googleSubject: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}google_subject'],
      )!,
    );
  }

  @override
  $AccountsTable createAlias(String alias) {
    return $AccountsTable(attachedDatabase, alias);
  }
}

class Account extends DataClass implements Insertable<Account> {
  final int id;
  final String googleSubject;
  const Account({required this.id, required this.googleSubject});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['google_subject'] = Variable<String>(googleSubject);
    return map;
  }

  AccountsCompanion toCompanion(bool nullToAbsent) {
    return AccountsCompanion(
      id: Value(id),
      googleSubject: Value(googleSubject),
    );
  }

  factory Account.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Account(
      id: serializer.fromJson<int>(json['id']),
      googleSubject: serializer.fromJson<String>(json['googleSubject']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'googleSubject': serializer.toJson<String>(googleSubject),
    };
  }

  Account copyWith({int? id, String? googleSubject}) => Account(
    id: id ?? this.id,
    googleSubject: googleSubject ?? this.googleSubject,
  );
  Account copyWithCompanion(AccountsCompanion data) {
    return Account(
      id: data.id.present ? data.id.value : this.id,
      googleSubject: data.googleSubject.present
          ? data.googleSubject.value
          : this.googleSubject,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Account(')
          ..write('id: $id, ')
          ..write('googleSubject: $googleSubject')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, googleSubject);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Account &&
          other.id == this.id &&
          other.googleSubject == this.googleSubject);
}

class AccountsCompanion extends UpdateCompanion<Account> {
  final Value<int> id;
  final Value<String> googleSubject;
  const AccountsCompanion({
    this.id = const Value.absent(),
    this.googleSubject = const Value.absent(),
  });
  AccountsCompanion.insert({
    this.id = const Value.absent(),
    required String googleSubject,
  }) : googleSubject = Value(googleSubject);
  static Insertable<Account> custom({
    Expression<int>? id,
    Expression<String>? googleSubject,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (googleSubject != null) 'google_subject': googleSubject,
    });
  }

  AccountsCompanion copyWith({Value<int>? id, Value<String>? googleSubject}) {
    return AccountsCompanion(
      id: id ?? this.id,
      googleSubject: googleSubject ?? this.googleSubject,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (googleSubject.present) {
      map['google_subject'] = Variable<String>(googleSubject.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AccountsCompanion(')
          ..write('id: $id, ')
          ..write('googleSubject: $googleSubject')
          ..write(')'))
        .toString();
  }
}

class $TaskListCacheRowsTable extends TaskListCacheRows
    with TableInfo<$TaskListCacheRowsTable, TaskListCacheRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TaskListCacheRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _remoteIdMeta = const VerificationMeta(
    'remoteId',
  );
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
    'remote_id',
    aliasedName,
    true,
    check: () =>
        remoteId.isNull() |
        ComparableExpr(remoteId.length).isBiggerThanValue(0),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _projectionMeta = const VerificationMeta(
    'projection',
  );
  @override
  late final GeneratedColumn<String> projection = GeneratedColumn<String>(
    'projection',
    aliasedName,
    false,
    check: () =>
        projection.isIn(const <String>['supported', 'deleted', 'unsupported']),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    remoteId,
    title,
    projection,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'task_lists';
  @override
  VerificationContext validateIntegrity(
    Insertable<TaskListCacheRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('remote_id')) {
      context.handle(
        _remoteIdMeta,
        remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta),
      );
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('projection')) {
      context.handle(
        _projectionMeta,
        projection.isAcceptableOrUnknown(data['projection']!, _projectionMeta),
      );
    } else if (isInserting) {
      context.missing(_projectionMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, id},
    {accountId, remoteId},
  ];
  @override
  TaskListCacheRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TaskListCacheRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      remoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_id'],
      ),
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      projection: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}projection'],
      )!,
    );
  }

  @override
  $TaskListCacheRowsTable createAlias(String alias) {
    return $TaskListCacheRowsTable(attachedDatabase, alias);
  }
}

class TaskListCacheRow extends DataClass
    implements Insertable<TaskListCacheRow> {
  final int id;
  final int accountId;
  final String? remoteId;
  final String title;
  final String projection;
  const TaskListCacheRow({
    required this.id,
    required this.accountId,
    this.remoteId,
    required this.title,
    required this.projection,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['account_id'] = Variable<int>(accountId);
    if (!nullToAbsent || remoteId != null) {
      map['remote_id'] = Variable<String>(remoteId);
    }
    map['title'] = Variable<String>(title);
    map['projection'] = Variable<String>(projection);
    return map;
  }

  TaskListCacheRowsCompanion toCompanion(bool nullToAbsent) {
    return TaskListCacheRowsCompanion(
      id: Value(id),
      accountId: Value(accountId),
      remoteId: remoteId == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteId),
      title: Value(title),
      projection: Value(projection),
    );
  }

  factory TaskListCacheRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TaskListCacheRow(
      id: serializer.fromJson<int>(json['id']),
      accountId: serializer.fromJson<int>(json['accountId']),
      remoteId: serializer.fromJson<String?>(json['remoteId']),
      title: serializer.fromJson<String>(json['title']),
      projection: serializer.fromJson<String>(json['projection']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'accountId': serializer.toJson<int>(accountId),
      'remoteId': serializer.toJson<String?>(remoteId),
      'title': serializer.toJson<String>(title),
      'projection': serializer.toJson<String>(projection),
    };
  }

  TaskListCacheRow copyWith({
    int? id,
    int? accountId,
    Value<String?> remoteId = const Value.absent(),
    String? title,
    String? projection,
  }) => TaskListCacheRow(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    remoteId: remoteId.present ? remoteId.value : this.remoteId,
    title: title ?? this.title,
    projection: projection ?? this.projection,
  );
  TaskListCacheRow copyWithCompanion(TaskListCacheRowsCompanion data) {
    return TaskListCacheRow(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      title: data.title.present ? data.title.value : this.title,
      projection: data.projection.present
          ? data.projection.value
          : this.projection,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TaskListCacheRow(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('remoteId: $remoteId, ')
          ..write('title: $title, ')
          ..write('projection: $projection')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, accountId, remoteId, title, projection);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TaskListCacheRow &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.remoteId == this.remoteId &&
          other.title == this.title &&
          other.projection == this.projection);
}

class TaskListCacheRowsCompanion extends UpdateCompanion<TaskListCacheRow> {
  final Value<int> id;
  final Value<int> accountId;
  final Value<String?> remoteId;
  final Value<String> title;
  final Value<String> projection;
  const TaskListCacheRowsCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.title = const Value.absent(),
    this.projection = const Value.absent(),
  });
  TaskListCacheRowsCompanion.insert({
    this.id = const Value.absent(),
    required int accountId,
    this.remoteId = const Value.absent(),
    required String title,
    required String projection,
  }) : accountId = Value(accountId),
       title = Value(title),
       projection = Value(projection);
  static Insertable<TaskListCacheRow> custom({
    Expression<int>? id,
    Expression<int>? accountId,
    Expression<String>? remoteId,
    Expression<String>? title,
    Expression<String>? projection,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (remoteId != null) 'remote_id': remoteId,
      if (title != null) 'title': title,
      if (projection != null) 'projection': projection,
    });
  }

  TaskListCacheRowsCompanion copyWith({
    Value<int>? id,
    Value<int>? accountId,
    Value<String?>? remoteId,
    Value<String>? title,
    Value<String>? projection,
  }) {
    return TaskListCacheRowsCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      remoteId: remoteId ?? this.remoteId,
      title: title ?? this.title,
      projection: projection ?? this.projection,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (projection.present) {
      map['projection'] = Variable<String>(projection.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TaskListCacheRowsCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('remoteId: $remoteId, ')
          ..write('title: $title, ')
          ..write('projection: $projection')
          ..write(')'))
        .toString();
  }
}

class $TaskCacheRowsTable extends TaskCacheRows
    with TableInfo<$TaskCacheRowsTable, TaskCacheRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TaskCacheRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _taskListIdMeta = const VerificationMeta(
    'taskListId',
  );
  @override
  late final GeneratedColumn<int> taskListId = GeneratedColumn<int>(
    'task_list_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _parentTaskIdMeta = const VerificationMeta(
    'parentTaskId',
  );
  @override
  late final GeneratedColumn<int> parentTaskId = GeneratedColumn<int>(
    'parent_task_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _remoteIdMeta = const VerificationMeta(
    'remoteId',
  );
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
    'remote_id',
    aliasedName,
    true,
    check: () =>
        remoteId.isNull() |
        ComparableExpr(remoteId.length).isBiggerThanValue(0),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
    'notes',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    check: () => status.isIn(const <String>['needs_action', 'completed']),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dueEpochDayMeta = const VerificationMeta(
    'dueEpochDay',
  );
  @override
  late final GeneratedColumn<int> dueEpochDay = GeneratedColumn<int>(
    'due_epoch_day',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _positionMeta = const VerificationMeta(
    'position',
  );
  @override
  late final GeneratedColumn<String> position = GeneratedColumn<String>(
    'position',
    aliasedName,
    false,
    check: () => ComparableExpr(position.length).isBiggerThanValue(0),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _projectionMeta = const VerificationMeta(
    'projection',
  );
  @override
  late final GeneratedColumn<String> projection = GeneratedColumn<String>(
    'projection',
    aliasedName,
    false,
    check: () =>
        projection.isIn(const <String>['supported', 'deleted', 'unsupported']),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    taskListId,
    parentTaskId,
    remoteId,
    title,
    notes,
    status,
    dueEpochDay,
    position,
    projection,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'tasks';
  @override
  VerificationContext validateIntegrity(
    Insertable<TaskCacheRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('task_list_id')) {
      context.handle(
        _taskListIdMeta,
        taskListId.isAcceptableOrUnknown(
          data['task_list_id']!,
          _taskListIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_taskListIdMeta);
    }
    if (data.containsKey('parent_task_id')) {
      context.handle(
        _parentTaskIdMeta,
        parentTaskId.isAcceptableOrUnknown(
          data['parent_task_id']!,
          _parentTaskIdMeta,
        ),
      );
    }
    if (data.containsKey('remote_id')) {
      context.handle(
        _remoteIdMeta,
        remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta),
      );
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
    if (data.containsKey('due_epoch_day')) {
      context.handle(
        _dueEpochDayMeta,
        dueEpochDay.isAcceptableOrUnknown(
          data['due_epoch_day']!,
          _dueEpochDayMeta,
        ),
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
    if (data.containsKey('projection')) {
      context.handle(
        _projectionMeta,
        projection.isAcceptableOrUnknown(data['projection']!, _projectionMeta),
      );
    } else if (isInserting) {
      context.missing(_projectionMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, id},
    {accountId, remoteId},
    {accountId, taskListId, id},
  ];
  @override
  TaskCacheRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TaskCacheRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      taskListId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}task_list_id'],
      )!,
      parentTaskId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}parent_task_id'],
      ),
      remoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_id'],
      ),
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
      dueEpochDay: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}due_epoch_day'],
      ),
      position: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}position'],
      )!,
      projection: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}projection'],
      )!,
    );
  }

  @override
  $TaskCacheRowsTable createAlias(String alias) {
    return $TaskCacheRowsTable(attachedDatabase, alias);
  }
}

class TaskCacheRow extends DataClass implements Insertable<TaskCacheRow> {
  final int id;
  final int accountId;
  final int taskListId;
  final int? parentTaskId;
  final String? remoteId;
  final String title;
  final String? notes;
  final String status;
  final int? dueEpochDay;
  final String position;
  final String projection;
  const TaskCacheRow({
    required this.id,
    required this.accountId,
    required this.taskListId,
    this.parentTaskId,
    this.remoteId,
    required this.title,
    this.notes,
    required this.status,
    this.dueEpochDay,
    required this.position,
    required this.projection,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['account_id'] = Variable<int>(accountId);
    map['task_list_id'] = Variable<int>(taskListId);
    if (!nullToAbsent || parentTaskId != null) {
      map['parent_task_id'] = Variable<int>(parentTaskId);
    }
    if (!nullToAbsent || remoteId != null) {
      map['remote_id'] = Variable<String>(remoteId);
    }
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || notes != null) {
      map['notes'] = Variable<String>(notes);
    }
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || dueEpochDay != null) {
      map['due_epoch_day'] = Variable<int>(dueEpochDay);
    }
    map['position'] = Variable<String>(position);
    map['projection'] = Variable<String>(projection);
    return map;
  }

  TaskCacheRowsCompanion toCompanion(bool nullToAbsent) {
    return TaskCacheRowsCompanion(
      id: Value(id),
      accountId: Value(accountId),
      taskListId: Value(taskListId),
      parentTaskId: parentTaskId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentTaskId),
      remoteId: remoteId == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteId),
      title: Value(title),
      notes: notes == null && nullToAbsent
          ? const Value.absent()
          : Value(notes),
      status: Value(status),
      dueEpochDay: dueEpochDay == null && nullToAbsent
          ? const Value.absent()
          : Value(dueEpochDay),
      position: Value(position),
      projection: Value(projection),
    );
  }

  factory TaskCacheRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TaskCacheRow(
      id: serializer.fromJson<int>(json['id']),
      accountId: serializer.fromJson<int>(json['accountId']),
      taskListId: serializer.fromJson<int>(json['taskListId']),
      parentTaskId: serializer.fromJson<int?>(json['parentTaskId']),
      remoteId: serializer.fromJson<String?>(json['remoteId']),
      title: serializer.fromJson<String>(json['title']),
      notes: serializer.fromJson<String?>(json['notes']),
      status: serializer.fromJson<String>(json['status']),
      dueEpochDay: serializer.fromJson<int?>(json['dueEpochDay']),
      position: serializer.fromJson<String>(json['position']),
      projection: serializer.fromJson<String>(json['projection']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'accountId': serializer.toJson<int>(accountId),
      'taskListId': serializer.toJson<int>(taskListId),
      'parentTaskId': serializer.toJson<int?>(parentTaskId),
      'remoteId': serializer.toJson<String?>(remoteId),
      'title': serializer.toJson<String>(title),
      'notes': serializer.toJson<String?>(notes),
      'status': serializer.toJson<String>(status),
      'dueEpochDay': serializer.toJson<int?>(dueEpochDay),
      'position': serializer.toJson<String>(position),
      'projection': serializer.toJson<String>(projection),
    };
  }

  TaskCacheRow copyWith({
    int? id,
    int? accountId,
    int? taskListId,
    Value<int?> parentTaskId = const Value.absent(),
    Value<String?> remoteId = const Value.absent(),
    String? title,
    Value<String?> notes = const Value.absent(),
    String? status,
    Value<int?> dueEpochDay = const Value.absent(),
    String? position,
    String? projection,
  }) => TaskCacheRow(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    taskListId: taskListId ?? this.taskListId,
    parentTaskId: parentTaskId.present ? parentTaskId.value : this.parentTaskId,
    remoteId: remoteId.present ? remoteId.value : this.remoteId,
    title: title ?? this.title,
    notes: notes.present ? notes.value : this.notes,
    status: status ?? this.status,
    dueEpochDay: dueEpochDay.present ? dueEpochDay.value : this.dueEpochDay,
    position: position ?? this.position,
    projection: projection ?? this.projection,
  );
  TaskCacheRow copyWithCompanion(TaskCacheRowsCompanion data) {
    return TaskCacheRow(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      taskListId: data.taskListId.present
          ? data.taskListId.value
          : this.taskListId,
      parentTaskId: data.parentTaskId.present
          ? data.parentTaskId.value
          : this.parentTaskId,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      title: data.title.present ? data.title.value : this.title,
      notes: data.notes.present ? data.notes.value : this.notes,
      status: data.status.present ? data.status.value : this.status,
      dueEpochDay: data.dueEpochDay.present
          ? data.dueEpochDay.value
          : this.dueEpochDay,
      position: data.position.present ? data.position.value : this.position,
      projection: data.projection.present
          ? data.projection.value
          : this.projection,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TaskCacheRow(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('taskListId: $taskListId, ')
          ..write('parentTaskId: $parentTaskId, ')
          ..write('remoteId: $remoteId, ')
          ..write('title: $title, ')
          ..write('notes: $notes, ')
          ..write('status: $status, ')
          ..write('dueEpochDay: $dueEpochDay, ')
          ..write('position: $position, ')
          ..write('projection: $projection')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    taskListId,
    parentTaskId,
    remoteId,
    title,
    notes,
    status,
    dueEpochDay,
    position,
    projection,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TaskCacheRow &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.taskListId == this.taskListId &&
          other.parentTaskId == this.parentTaskId &&
          other.remoteId == this.remoteId &&
          other.title == this.title &&
          other.notes == this.notes &&
          other.status == this.status &&
          other.dueEpochDay == this.dueEpochDay &&
          other.position == this.position &&
          other.projection == this.projection);
}

class TaskCacheRowsCompanion extends UpdateCompanion<TaskCacheRow> {
  final Value<int> id;
  final Value<int> accountId;
  final Value<int> taskListId;
  final Value<int?> parentTaskId;
  final Value<String?> remoteId;
  final Value<String> title;
  final Value<String?> notes;
  final Value<String> status;
  final Value<int?> dueEpochDay;
  final Value<String> position;
  final Value<String> projection;
  const TaskCacheRowsCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.taskListId = const Value.absent(),
    this.parentTaskId = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.title = const Value.absent(),
    this.notes = const Value.absent(),
    this.status = const Value.absent(),
    this.dueEpochDay = const Value.absent(),
    this.position = const Value.absent(),
    this.projection = const Value.absent(),
  });
  TaskCacheRowsCompanion.insert({
    this.id = const Value.absent(),
    required int accountId,
    required int taskListId,
    this.parentTaskId = const Value.absent(),
    this.remoteId = const Value.absent(),
    required String title,
    this.notes = const Value.absent(),
    required String status,
    this.dueEpochDay = const Value.absent(),
    required String position,
    required String projection,
  }) : accountId = Value(accountId),
       taskListId = Value(taskListId),
       title = Value(title),
       status = Value(status),
       position = Value(position),
       projection = Value(projection);
  static Insertable<TaskCacheRow> custom({
    Expression<int>? id,
    Expression<int>? accountId,
    Expression<int>? taskListId,
    Expression<int>? parentTaskId,
    Expression<String>? remoteId,
    Expression<String>? title,
    Expression<String>? notes,
    Expression<String>? status,
    Expression<int>? dueEpochDay,
    Expression<String>? position,
    Expression<String>? projection,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (taskListId != null) 'task_list_id': taskListId,
      if (parentTaskId != null) 'parent_task_id': parentTaskId,
      if (remoteId != null) 'remote_id': remoteId,
      if (title != null) 'title': title,
      if (notes != null) 'notes': notes,
      if (status != null) 'status': status,
      if (dueEpochDay != null) 'due_epoch_day': dueEpochDay,
      if (position != null) 'position': position,
      if (projection != null) 'projection': projection,
    });
  }

  TaskCacheRowsCompanion copyWith({
    Value<int>? id,
    Value<int>? accountId,
    Value<int>? taskListId,
    Value<int?>? parentTaskId,
    Value<String?>? remoteId,
    Value<String>? title,
    Value<String?>? notes,
    Value<String>? status,
    Value<int?>? dueEpochDay,
    Value<String>? position,
    Value<String>? projection,
  }) {
    return TaskCacheRowsCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      taskListId: taskListId ?? this.taskListId,
      parentTaskId: parentTaskId ?? this.parentTaskId,
      remoteId: remoteId ?? this.remoteId,
      title: title ?? this.title,
      notes: notes ?? this.notes,
      status: status ?? this.status,
      dueEpochDay: dueEpochDay ?? this.dueEpochDay,
      position: position ?? this.position,
      projection: projection ?? this.projection,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (taskListId.present) {
      map['task_list_id'] = Variable<int>(taskListId.value);
    }
    if (parentTaskId.present) {
      map['parent_task_id'] = Variable<int>(parentTaskId.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
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
    if (dueEpochDay.present) {
      map['due_epoch_day'] = Variable<int>(dueEpochDay.value);
    }
    if (position.present) {
      map['position'] = Variable<String>(position.value);
    }
    if (projection.present) {
      map['projection'] = Variable<String>(projection.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TaskCacheRowsCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('taskListId: $taskListId, ')
          ..write('parentTaskId: $parentTaskId, ')
          ..write('remoteId: $remoteId, ')
          ..write('title: $title, ')
          ..write('notes: $notes, ')
          ..write('status: $status, ')
          ..write('dueEpochDay: $dueEpochDay, ')
          ..write('position: $position, ')
          ..write('projection: $projection')
          ..write(')'))
        .toString();
  }
}

class $TaskListRemoteBasesTable extends TaskListRemoteBases
    with TableInfo<$TaskListRemoteBasesTable, TaskListRemoteBase> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TaskListRemoteBasesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _taskListIdMeta = const VerificationMeta(
    'taskListId',
  );
  @override
  late final GeneratedColumn<int> taskListId = GeneratedColumn<int>(
    'task_list_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _remoteIdMeta = const VerificationMeta(
    'remoteId',
  );
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
    'remote_id',
    aliasedName,
    false,
    check: () => ComparableExpr(remoteId.length).isBiggerThanValue(0),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _etagMeta = const VerificationMeta('etag');
  @override
  late final GeneratedColumn<String> etag = GeneratedColumn<String>(
    'etag',
    aliasedName,
    true,
    check: () =>
        etag.isNull() | ComparableExpr(etag.length).isBiggerThanValue(0),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _remoteUpdatedAtMeta = const VerificationMeta(
    'remoteUpdatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> remoteUpdatedAt =
      GeneratedColumn<DateTime>(
        'remote_updated_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _deletedMeta = const VerificationMeta(
    'deleted',
  );
  @override
  late final GeneratedColumn<bool> deleted = GeneratedColumn<bool>(
    'deleted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("deleted" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _observedPublicationIdMeta =
      const VerificationMeta('observedPublicationId');
  @override
  late final GeneratedColumn<String> observedPublicationId =
      GeneratedColumn<String>(
        'observed_publication_id',
        aliasedName,
        false,
        check: () =>
            ComparableExpr(observedPublicationId.length).isBiggerThanValue(0),
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    taskListId,
    remoteId,
    title,
    etag,
    remoteUpdatedAt,
    deleted,
    observedPublicationId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'task_list_remote_bases';
  @override
  VerificationContext validateIntegrity(
    Insertable<TaskListRemoteBase> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('task_list_id')) {
      context.handle(
        _taskListIdMeta,
        taskListId.isAcceptableOrUnknown(
          data['task_list_id']!,
          _taskListIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_taskListIdMeta);
    }
    if (data.containsKey('remote_id')) {
      context.handle(
        _remoteIdMeta,
        remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta),
      );
    } else if (isInserting) {
      context.missing(_remoteIdMeta);
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
    if (data.containsKey('remote_updated_at')) {
      context.handle(
        _remoteUpdatedAtMeta,
        remoteUpdatedAt.isAcceptableOrUnknown(
          data['remote_updated_at']!,
          _remoteUpdatedAtMeta,
        ),
      );
    }
    if (data.containsKey('deleted')) {
      context.handle(
        _deletedMeta,
        deleted.isAcceptableOrUnknown(data['deleted']!, _deletedMeta),
      );
    }
    if (data.containsKey('observed_publication_id')) {
      context.handle(
        _observedPublicationIdMeta,
        observedPublicationId.isAcceptableOrUnknown(
          data['observed_publication_id']!,
          _observedPublicationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_observedPublicationIdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId, taskListId};
  @override
  TaskListRemoteBase map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TaskListRemoteBase(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      taskListId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}task_list_id'],
      )!,
      remoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      etag: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}etag'],
      ),
      remoteUpdatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}remote_updated_at'],
      ),
      deleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}deleted'],
      )!,
      observedPublicationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}observed_publication_id'],
      )!,
    );
  }

  @override
  $TaskListRemoteBasesTable createAlias(String alias) {
    return $TaskListRemoteBasesTable(attachedDatabase, alias);
  }
}

class TaskListRemoteBase extends DataClass
    implements Insertable<TaskListRemoteBase> {
  final int accountId;
  final int taskListId;
  final String remoteId;
  final String title;
  final String? etag;
  final DateTime? remoteUpdatedAt;
  final bool deleted;
  final String observedPublicationId;
  const TaskListRemoteBase({
    required this.accountId,
    required this.taskListId,
    required this.remoteId,
    required this.title,
    this.etag,
    this.remoteUpdatedAt,
    required this.deleted,
    required this.observedPublicationId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<int>(accountId);
    map['task_list_id'] = Variable<int>(taskListId);
    map['remote_id'] = Variable<String>(remoteId);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || etag != null) {
      map['etag'] = Variable<String>(etag);
    }
    if (!nullToAbsent || remoteUpdatedAt != null) {
      map['remote_updated_at'] = Variable<DateTime>(remoteUpdatedAt);
    }
    map['deleted'] = Variable<bool>(deleted);
    map['observed_publication_id'] = Variable<String>(observedPublicationId);
    return map;
  }

  TaskListRemoteBasesCompanion toCompanion(bool nullToAbsent) {
    return TaskListRemoteBasesCompanion(
      accountId: Value(accountId),
      taskListId: Value(taskListId),
      remoteId: Value(remoteId),
      title: Value(title),
      etag: etag == null && nullToAbsent ? const Value.absent() : Value(etag),
      remoteUpdatedAt: remoteUpdatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteUpdatedAt),
      deleted: Value(deleted),
      observedPublicationId: Value(observedPublicationId),
    );
  }

  factory TaskListRemoteBase.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TaskListRemoteBase(
      accountId: serializer.fromJson<int>(json['accountId']),
      taskListId: serializer.fromJson<int>(json['taskListId']),
      remoteId: serializer.fromJson<String>(json['remoteId']),
      title: serializer.fromJson<String>(json['title']),
      etag: serializer.fromJson<String?>(json['etag']),
      remoteUpdatedAt: serializer.fromJson<DateTime?>(json['remoteUpdatedAt']),
      deleted: serializer.fromJson<bool>(json['deleted']),
      observedPublicationId: serializer.fromJson<String>(
        json['observedPublicationId'],
      ),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<int>(accountId),
      'taskListId': serializer.toJson<int>(taskListId),
      'remoteId': serializer.toJson<String>(remoteId),
      'title': serializer.toJson<String>(title),
      'etag': serializer.toJson<String?>(etag),
      'remoteUpdatedAt': serializer.toJson<DateTime?>(remoteUpdatedAt),
      'deleted': serializer.toJson<bool>(deleted),
      'observedPublicationId': serializer.toJson<String>(observedPublicationId),
    };
  }

  TaskListRemoteBase copyWith({
    int? accountId,
    int? taskListId,
    String? remoteId,
    String? title,
    Value<String?> etag = const Value.absent(),
    Value<DateTime?> remoteUpdatedAt = const Value.absent(),
    bool? deleted,
    String? observedPublicationId,
  }) => TaskListRemoteBase(
    accountId: accountId ?? this.accountId,
    taskListId: taskListId ?? this.taskListId,
    remoteId: remoteId ?? this.remoteId,
    title: title ?? this.title,
    etag: etag.present ? etag.value : this.etag,
    remoteUpdatedAt: remoteUpdatedAt.present
        ? remoteUpdatedAt.value
        : this.remoteUpdatedAt,
    deleted: deleted ?? this.deleted,
    observedPublicationId: observedPublicationId ?? this.observedPublicationId,
  );
  TaskListRemoteBase copyWithCompanion(TaskListRemoteBasesCompanion data) {
    return TaskListRemoteBase(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      taskListId: data.taskListId.present
          ? data.taskListId.value
          : this.taskListId,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      title: data.title.present ? data.title.value : this.title,
      etag: data.etag.present ? data.etag.value : this.etag,
      remoteUpdatedAt: data.remoteUpdatedAt.present
          ? data.remoteUpdatedAt.value
          : this.remoteUpdatedAt,
      deleted: data.deleted.present ? data.deleted.value : this.deleted,
      observedPublicationId: data.observedPublicationId.present
          ? data.observedPublicationId.value
          : this.observedPublicationId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TaskListRemoteBase(')
          ..write('accountId: $accountId, ')
          ..write('taskListId: $taskListId, ')
          ..write('remoteId: $remoteId, ')
          ..write('title: $title, ')
          ..write('etag: $etag, ')
          ..write('remoteUpdatedAt: $remoteUpdatedAt, ')
          ..write('deleted: $deleted, ')
          ..write('observedPublicationId: $observedPublicationId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    accountId,
    taskListId,
    remoteId,
    title,
    etag,
    remoteUpdatedAt,
    deleted,
    observedPublicationId,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TaskListRemoteBase &&
          other.accountId == this.accountId &&
          other.taskListId == this.taskListId &&
          other.remoteId == this.remoteId &&
          other.title == this.title &&
          other.etag == this.etag &&
          other.remoteUpdatedAt == this.remoteUpdatedAt &&
          other.deleted == this.deleted &&
          other.observedPublicationId == this.observedPublicationId);
}

class TaskListRemoteBasesCompanion extends UpdateCompanion<TaskListRemoteBase> {
  final Value<int> accountId;
  final Value<int> taskListId;
  final Value<String> remoteId;
  final Value<String> title;
  final Value<String?> etag;
  final Value<DateTime?> remoteUpdatedAt;
  final Value<bool> deleted;
  final Value<String> observedPublicationId;
  final Value<int> rowid;
  const TaskListRemoteBasesCompanion({
    this.accountId = const Value.absent(),
    this.taskListId = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.title = const Value.absent(),
    this.etag = const Value.absent(),
    this.remoteUpdatedAt = const Value.absent(),
    this.deleted = const Value.absent(),
    this.observedPublicationId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TaskListRemoteBasesCompanion.insert({
    required int accountId,
    required int taskListId,
    required String remoteId,
    required String title,
    this.etag = const Value.absent(),
    this.remoteUpdatedAt = const Value.absent(),
    this.deleted = const Value.absent(),
    required String observedPublicationId,
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       taskListId = Value(taskListId),
       remoteId = Value(remoteId),
       title = Value(title),
       observedPublicationId = Value(observedPublicationId);
  static Insertable<TaskListRemoteBase> custom({
    Expression<int>? accountId,
    Expression<int>? taskListId,
    Expression<String>? remoteId,
    Expression<String>? title,
    Expression<String>? etag,
    Expression<DateTime>? remoteUpdatedAt,
    Expression<bool>? deleted,
    Expression<String>? observedPublicationId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (taskListId != null) 'task_list_id': taskListId,
      if (remoteId != null) 'remote_id': remoteId,
      if (title != null) 'title': title,
      if (etag != null) 'etag': etag,
      if (remoteUpdatedAt != null) 'remote_updated_at': remoteUpdatedAt,
      if (deleted != null) 'deleted': deleted,
      if (observedPublicationId != null)
        'observed_publication_id': observedPublicationId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TaskListRemoteBasesCompanion copyWith({
    Value<int>? accountId,
    Value<int>? taskListId,
    Value<String>? remoteId,
    Value<String>? title,
    Value<String?>? etag,
    Value<DateTime?>? remoteUpdatedAt,
    Value<bool>? deleted,
    Value<String>? observedPublicationId,
    Value<int>? rowid,
  }) {
    return TaskListRemoteBasesCompanion(
      accountId: accountId ?? this.accountId,
      taskListId: taskListId ?? this.taskListId,
      remoteId: remoteId ?? this.remoteId,
      title: title ?? this.title,
      etag: etag ?? this.etag,
      remoteUpdatedAt: remoteUpdatedAt ?? this.remoteUpdatedAt,
      deleted: deleted ?? this.deleted,
      observedPublicationId:
          observedPublicationId ?? this.observedPublicationId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (taskListId.present) {
      map['task_list_id'] = Variable<int>(taskListId.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (etag.present) {
      map['etag'] = Variable<String>(etag.value);
    }
    if (remoteUpdatedAt.present) {
      map['remote_updated_at'] = Variable<DateTime>(remoteUpdatedAt.value);
    }
    if (deleted.present) {
      map['deleted'] = Variable<bool>(deleted.value);
    }
    if (observedPublicationId.present) {
      map['observed_publication_id'] = Variable<String>(
        observedPublicationId.value,
      );
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TaskListRemoteBasesCompanion(')
          ..write('accountId: $accountId, ')
          ..write('taskListId: $taskListId, ')
          ..write('remoteId: $remoteId, ')
          ..write('title: $title, ')
          ..write('etag: $etag, ')
          ..write('remoteUpdatedAt: $remoteUpdatedAt, ')
          ..write('deleted: $deleted, ')
          ..write('observedPublicationId: $observedPublicationId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TaskRemoteBasesTable extends TaskRemoteBases
    with TableInfo<$TaskRemoteBasesTable, TaskRemoteBase> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TaskRemoteBasesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _taskIdMeta = const VerificationMeta('taskId');
  @override
  late final GeneratedColumn<int> taskId = GeneratedColumn<int>(
    'task_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _taskListIdMeta = const VerificationMeta(
    'taskListId',
  );
  @override
  late final GeneratedColumn<int> taskListId = GeneratedColumn<int>(
    'task_list_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _parentTaskIdMeta = const VerificationMeta(
    'parentTaskId',
  );
  @override
  late final GeneratedColumn<int> parentTaskId = GeneratedColumn<int>(
    'parent_task_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _remoteIdMeta = const VerificationMeta(
    'remoteId',
  );
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
    'remote_id',
    aliasedName,
    false,
    check: () => ComparableExpr(remoteId.length).isBiggerThanValue(0),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
    'notes',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    true,
    check: () =>
        status.isNull() |
        status.isIn(const <String>['needs_action', 'completed']),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dueEpochDayMeta = const VerificationMeta(
    'dueEpochDay',
  );
  @override
  late final GeneratedColumn<int> dueEpochDay = GeneratedColumn<int>(
    'due_epoch_day',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _positionMeta = const VerificationMeta(
    'position',
  );
  @override
  late final GeneratedColumn<String> position = GeneratedColumn<String>(
    'position',
    aliasedName,
    true,
    check: () =>
        position.isNull() |
        ComparableExpr(position.length).isBiggerThanValue(0),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _completedAtMeta = const VerificationMeta(
    'completedAt',
  );
  @override
  late final GeneratedColumn<DateTime> completedAt = GeneratedColumn<DateTime>(
    'completed_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _hiddenMeta = const VerificationMeta('hidden');
  @override
  late final GeneratedColumn<bool> hidden = GeneratedColumn<bool>(
    'hidden',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("hidden" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _deletedMeta = const VerificationMeta(
    'deleted',
  );
  @override
  late final GeneratedColumn<bool> deleted = GeneratedColumn<bool>(
    'deleted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("deleted" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _etagMeta = const VerificationMeta('etag');
  @override
  late final GeneratedColumn<String> etag = GeneratedColumn<String>(
    'etag',
    aliasedName,
    true,
    check: () =>
        etag.isNull() | ComparableExpr(etag.length).isBiggerThanValue(0),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _remoteUpdatedAtMeta = const VerificationMeta(
    'remoteUpdatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> remoteUpdatedAt =
      GeneratedColumn<DateTime>(
        'remote_updated_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _selfLinkMeta = const VerificationMeta(
    'selfLink',
  );
  @override
  late final GeneratedColumn<String> selfLink = GeneratedColumn<String>(
    'self_link',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _linksJsonMeta = const VerificationMeta(
    'linksJson',
  );
  @override
  late final GeneratedColumn<String> linksJson = GeneratedColumn<String>(
    'links_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _webViewLinkMeta = const VerificationMeta(
    'webViewLink',
  );
  @override
  late final GeneratedColumn<String> webViewLink = GeneratedColumn<String>(
    'web_view_link',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _observedPublicationIdMeta =
      const VerificationMeta('observedPublicationId');
  @override
  late final GeneratedColumn<String> observedPublicationId =
      GeneratedColumn<String>(
        'observed_publication_id',
        aliasedName,
        false,
        check: () =>
            ComparableExpr(observedPublicationId.length).isBiggerThanValue(0),
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    taskId,
    taskListId,
    parentTaskId,
    remoteId,
    title,
    notes,
    status,
    dueEpochDay,
    position,
    completedAt,
    hidden,
    deleted,
    etag,
    remoteUpdatedAt,
    selfLink,
    linksJson,
    webViewLink,
    observedPublicationId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'task_remote_bases';
  @override
  VerificationContext validateIntegrity(
    Insertable<TaskRemoteBase> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('task_id')) {
      context.handle(
        _taskIdMeta,
        taskId.isAcceptableOrUnknown(data['task_id']!, _taskIdMeta),
      );
    } else if (isInserting) {
      context.missing(_taskIdMeta);
    }
    if (data.containsKey('task_list_id')) {
      context.handle(
        _taskListIdMeta,
        taskListId.isAcceptableOrUnknown(
          data['task_list_id']!,
          _taskListIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_taskListIdMeta);
    }
    if (data.containsKey('parent_task_id')) {
      context.handle(
        _parentTaskIdMeta,
        parentTaskId.isAcceptableOrUnknown(
          data['parent_task_id']!,
          _parentTaskIdMeta,
        ),
      );
    }
    if (data.containsKey('remote_id')) {
      context.handle(
        _remoteIdMeta,
        remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta),
      );
    } else if (isInserting) {
      context.missing(_remoteIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
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
    }
    if (data.containsKey('due_epoch_day')) {
      context.handle(
        _dueEpochDayMeta,
        dueEpochDay.isAcceptableOrUnknown(
          data['due_epoch_day']!,
          _dueEpochDayMeta,
        ),
      );
    }
    if (data.containsKey('position')) {
      context.handle(
        _positionMeta,
        position.isAcceptableOrUnknown(data['position']!, _positionMeta),
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
    if (data.containsKey('hidden')) {
      context.handle(
        _hiddenMeta,
        hidden.isAcceptableOrUnknown(data['hidden']!, _hiddenMeta),
      );
    }
    if (data.containsKey('deleted')) {
      context.handle(
        _deletedMeta,
        deleted.isAcceptableOrUnknown(data['deleted']!, _deletedMeta),
      );
    }
    if (data.containsKey('etag')) {
      context.handle(
        _etagMeta,
        etag.isAcceptableOrUnknown(data['etag']!, _etagMeta),
      );
    }
    if (data.containsKey('remote_updated_at')) {
      context.handle(
        _remoteUpdatedAtMeta,
        remoteUpdatedAt.isAcceptableOrUnknown(
          data['remote_updated_at']!,
          _remoteUpdatedAtMeta,
        ),
      );
    }
    if (data.containsKey('self_link')) {
      context.handle(
        _selfLinkMeta,
        selfLink.isAcceptableOrUnknown(data['self_link']!, _selfLinkMeta),
      );
    }
    if (data.containsKey('links_json')) {
      context.handle(
        _linksJsonMeta,
        linksJson.isAcceptableOrUnknown(data['links_json']!, _linksJsonMeta),
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
    if (data.containsKey('observed_publication_id')) {
      context.handle(
        _observedPublicationIdMeta,
        observedPublicationId.isAcceptableOrUnknown(
          data['observed_publication_id']!,
          _observedPublicationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_observedPublicationIdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId, taskId};
  @override
  TaskRemoteBase map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TaskRemoteBase(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      taskId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}task_id'],
      )!,
      taskListId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}task_list_id'],
      )!,
      parentTaskId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}parent_task_id'],
      ),
      remoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      ),
      notes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notes'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      ),
      dueEpochDay: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}due_epoch_day'],
      ),
      position: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}position'],
      ),
      completedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}completed_at'],
      ),
      hidden: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}hidden'],
      )!,
      deleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}deleted'],
      )!,
      etag: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}etag'],
      ),
      remoteUpdatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}remote_updated_at'],
      ),
      selfLink: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}self_link'],
      ),
      linksJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}links_json'],
      )!,
      webViewLink: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}web_view_link'],
      ),
      observedPublicationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}observed_publication_id'],
      )!,
    );
  }

  @override
  $TaskRemoteBasesTable createAlias(String alias) {
    return $TaskRemoteBasesTable(attachedDatabase, alias);
  }
}

class TaskRemoteBase extends DataClass implements Insertable<TaskRemoteBase> {
  final int accountId;
  final int taskId;
  final int taskListId;
  final int? parentTaskId;
  final String remoteId;
  final String? title;
  final String? notes;
  final String? status;
  final int? dueEpochDay;
  final String? position;
  final DateTime? completedAt;
  final bool hidden;
  final bool deleted;
  final String? etag;
  final DateTime? remoteUpdatedAt;
  final String? selfLink;
  final String linksJson;
  final String? webViewLink;
  final String observedPublicationId;
  const TaskRemoteBase({
    required this.accountId,
    required this.taskId,
    required this.taskListId,
    this.parentTaskId,
    required this.remoteId,
    this.title,
    this.notes,
    this.status,
    this.dueEpochDay,
    this.position,
    this.completedAt,
    required this.hidden,
    required this.deleted,
    this.etag,
    this.remoteUpdatedAt,
    this.selfLink,
    required this.linksJson,
    this.webViewLink,
    required this.observedPublicationId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<int>(accountId);
    map['task_id'] = Variable<int>(taskId);
    map['task_list_id'] = Variable<int>(taskListId);
    if (!nullToAbsent || parentTaskId != null) {
      map['parent_task_id'] = Variable<int>(parentTaskId);
    }
    map['remote_id'] = Variable<String>(remoteId);
    if (!nullToAbsent || title != null) {
      map['title'] = Variable<String>(title);
    }
    if (!nullToAbsent || notes != null) {
      map['notes'] = Variable<String>(notes);
    }
    if (!nullToAbsent || status != null) {
      map['status'] = Variable<String>(status);
    }
    if (!nullToAbsent || dueEpochDay != null) {
      map['due_epoch_day'] = Variable<int>(dueEpochDay);
    }
    if (!nullToAbsent || position != null) {
      map['position'] = Variable<String>(position);
    }
    if (!nullToAbsent || completedAt != null) {
      map['completed_at'] = Variable<DateTime>(completedAt);
    }
    map['hidden'] = Variable<bool>(hidden);
    map['deleted'] = Variable<bool>(deleted);
    if (!nullToAbsent || etag != null) {
      map['etag'] = Variable<String>(etag);
    }
    if (!nullToAbsent || remoteUpdatedAt != null) {
      map['remote_updated_at'] = Variable<DateTime>(remoteUpdatedAt);
    }
    if (!nullToAbsent || selfLink != null) {
      map['self_link'] = Variable<String>(selfLink);
    }
    map['links_json'] = Variable<String>(linksJson);
    if (!nullToAbsent || webViewLink != null) {
      map['web_view_link'] = Variable<String>(webViewLink);
    }
    map['observed_publication_id'] = Variable<String>(observedPublicationId);
    return map;
  }

  TaskRemoteBasesCompanion toCompanion(bool nullToAbsent) {
    return TaskRemoteBasesCompanion(
      accountId: Value(accountId),
      taskId: Value(taskId),
      taskListId: Value(taskListId),
      parentTaskId: parentTaskId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentTaskId),
      remoteId: Value(remoteId),
      title: title == null && nullToAbsent
          ? const Value.absent()
          : Value(title),
      notes: notes == null && nullToAbsent
          ? const Value.absent()
          : Value(notes),
      status: status == null && nullToAbsent
          ? const Value.absent()
          : Value(status),
      dueEpochDay: dueEpochDay == null && nullToAbsent
          ? const Value.absent()
          : Value(dueEpochDay),
      position: position == null && nullToAbsent
          ? const Value.absent()
          : Value(position),
      completedAt: completedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(completedAt),
      hidden: Value(hidden),
      deleted: Value(deleted),
      etag: etag == null && nullToAbsent ? const Value.absent() : Value(etag),
      remoteUpdatedAt: remoteUpdatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteUpdatedAt),
      selfLink: selfLink == null && nullToAbsent
          ? const Value.absent()
          : Value(selfLink),
      linksJson: Value(linksJson),
      webViewLink: webViewLink == null && nullToAbsent
          ? const Value.absent()
          : Value(webViewLink),
      observedPublicationId: Value(observedPublicationId),
    );
  }

  factory TaskRemoteBase.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TaskRemoteBase(
      accountId: serializer.fromJson<int>(json['accountId']),
      taskId: serializer.fromJson<int>(json['taskId']),
      taskListId: serializer.fromJson<int>(json['taskListId']),
      parentTaskId: serializer.fromJson<int?>(json['parentTaskId']),
      remoteId: serializer.fromJson<String>(json['remoteId']),
      title: serializer.fromJson<String?>(json['title']),
      notes: serializer.fromJson<String?>(json['notes']),
      status: serializer.fromJson<String?>(json['status']),
      dueEpochDay: serializer.fromJson<int?>(json['dueEpochDay']),
      position: serializer.fromJson<String?>(json['position']),
      completedAt: serializer.fromJson<DateTime?>(json['completedAt']),
      hidden: serializer.fromJson<bool>(json['hidden']),
      deleted: serializer.fromJson<bool>(json['deleted']),
      etag: serializer.fromJson<String?>(json['etag']),
      remoteUpdatedAt: serializer.fromJson<DateTime?>(json['remoteUpdatedAt']),
      selfLink: serializer.fromJson<String?>(json['selfLink']),
      linksJson: serializer.fromJson<String>(json['linksJson']),
      webViewLink: serializer.fromJson<String?>(json['webViewLink']),
      observedPublicationId: serializer.fromJson<String>(
        json['observedPublicationId'],
      ),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<int>(accountId),
      'taskId': serializer.toJson<int>(taskId),
      'taskListId': serializer.toJson<int>(taskListId),
      'parentTaskId': serializer.toJson<int?>(parentTaskId),
      'remoteId': serializer.toJson<String>(remoteId),
      'title': serializer.toJson<String?>(title),
      'notes': serializer.toJson<String?>(notes),
      'status': serializer.toJson<String?>(status),
      'dueEpochDay': serializer.toJson<int?>(dueEpochDay),
      'position': serializer.toJson<String?>(position),
      'completedAt': serializer.toJson<DateTime?>(completedAt),
      'hidden': serializer.toJson<bool>(hidden),
      'deleted': serializer.toJson<bool>(deleted),
      'etag': serializer.toJson<String?>(etag),
      'remoteUpdatedAt': serializer.toJson<DateTime?>(remoteUpdatedAt),
      'selfLink': serializer.toJson<String?>(selfLink),
      'linksJson': serializer.toJson<String>(linksJson),
      'webViewLink': serializer.toJson<String?>(webViewLink),
      'observedPublicationId': serializer.toJson<String>(observedPublicationId),
    };
  }

  TaskRemoteBase copyWith({
    int? accountId,
    int? taskId,
    int? taskListId,
    Value<int?> parentTaskId = const Value.absent(),
    String? remoteId,
    Value<String?> title = const Value.absent(),
    Value<String?> notes = const Value.absent(),
    Value<String?> status = const Value.absent(),
    Value<int?> dueEpochDay = const Value.absent(),
    Value<String?> position = const Value.absent(),
    Value<DateTime?> completedAt = const Value.absent(),
    bool? hidden,
    bool? deleted,
    Value<String?> etag = const Value.absent(),
    Value<DateTime?> remoteUpdatedAt = const Value.absent(),
    Value<String?> selfLink = const Value.absent(),
    String? linksJson,
    Value<String?> webViewLink = const Value.absent(),
    String? observedPublicationId,
  }) => TaskRemoteBase(
    accountId: accountId ?? this.accountId,
    taskId: taskId ?? this.taskId,
    taskListId: taskListId ?? this.taskListId,
    parentTaskId: parentTaskId.present ? parentTaskId.value : this.parentTaskId,
    remoteId: remoteId ?? this.remoteId,
    title: title.present ? title.value : this.title,
    notes: notes.present ? notes.value : this.notes,
    status: status.present ? status.value : this.status,
    dueEpochDay: dueEpochDay.present ? dueEpochDay.value : this.dueEpochDay,
    position: position.present ? position.value : this.position,
    completedAt: completedAt.present ? completedAt.value : this.completedAt,
    hidden: hidden ?? this.hidden,
    deleted: deleted ?? this.deleted,
    etag: etag.present ? etag.value : this.etag,
    remoteUpdatedAt: remoteUpdatedAt.present
        ? remoteUpdatedAt.value
        : this.remoteUpdatedAt,
    selfLink: selfLink.present ? selfLink.value : this.selfLink,
    linksJson: linksJson ?? this.linksJson,
    webViewLink: webViewLink.present ? webViewLink.value : this.webViewLink,
    observedPublicationId: observedPublicationId ?? this.observedPublicationId,
  );
  TaskRemoteBase copyWithCompanion(TaskRemoteBasesCompanion data) {
    return TaskRemoteBase(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      taskId: data.taskId.present ? data.taskId.value : this.taskId,
      taskListId: data.taskListId.present
          ? data.taskListId.value
          : this.taskListId,
      parentTaskId: data.parentTaskId.present
          ? data.parentTaskId.value
          : this.parentTaskId,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      title: data.title.present ? data.title.value : this.title,
      notes: data.notes.present ? data.notes.value : this.notes,
      status: data.status.present ? data.status.value : this.status,
      dueEpochDay: data.dueEpochDay.present
          ? data.dueEpochDay.value
          : this.dueEpochDay,
      position: data.position.present ? data.position.value : this.position,
      completedAt: data.completedAt.present
          ? data.completedAt.value
          : this.completedAt,
      hidden: data.hidden.present ? data.hidden.value : this.hidden,
      deleted: data.deleted.present ? data.deleted.value : this.deleted,
      etag: data.etag.present ? data.etag.value : this.etag,
      remoteUpdatedAt: data.remoteUpdatedAt.present
          ? data.remoteUpdatedAt.value
          : this.remoteUpdatedAt,
      selfLink: data.selfLink.present ? data.selfLink.value : this.selfLink,
      linksJson: data.linksJson.present ? data.linksJson.value : this.linksJson,
      webViewLink: data.webViewLink.present
          ? data.webViewLink.value
          : this.webViewLink,
      observedPublicationId: data.observedPublicationId.present
          ? data.observedPublicationId.value
          : this.observedPublicationId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TaskRemoteBase(')
          ..write('accountId: $accountId, ')
          ..write('taskId: $taskId, ')
          ..write('taskListId: $taskListId, ')
          ..write('parentTaskId: $parentTaskId, ')
          ..write('remoteId: $remoteId, ')
          ..write('title: $title, ')
          ..write('notes: $notes, ')
          ..write('status: $status, ')
          ..write('dueEpochDay: $dueEpochDay, ')
          ..write('position: $position, ')
          ..write('completedAt: $completedAt, ')
          ..write('hidden: $hidden, ')
          ..write('deleted: $deleted, ')
          ..write('etag: $etag, ')
          ..write('remoteUpdatedAt: $remoteUpdatedAt, ')
          ..write('selfLink: $selfLink, ')
          ..write('linksJson: $linksJson, ')
          ..write('webViewLink: $webViewLink, ')
          ..write('observedPublicationId: $observedPublicationId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    accountId,
    taskId,
    taskListId,
    parentTaskId,
    remoteId,
    title,
    notes,
    status,
    dueEpochDay,
    position,
    completedAt,
    hidden,
    deleted,
    etag,
    remoteUpdatedAt,
    selfLink,
    linksJson,
    webViewLink,
    observedPublicationId,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TaskRemoteBase &&
          other.accountId == this.accountId &&
          other.taskId == this.taskId &&
          other.taskListId == this.taskListId &&
          other.parentTaskId == this.parentTaskId &&
          other.remoteId == this.remoteId &&
          other.title == this.title &&
          other.notes == this.notes &&
          other.status == this.status &&
          other.dueEpochDay == this.dueEpochDay &&
          other.position == this.position &&
          other.completedAt == this.completedAt &&
          other.hidden == this.hidden &&
          other.deleted == this.deleted &&
          other.etag == this.etag &&
          other.remoteUpdatedAt == this.remoteUpdatedAt &&
          other.selfLink == this.selfLink &&
          other.linksJson == this.linksJson &&
          other.webViewLink == this.webViewLink &&
          other.observedPublicationId == this.observedPublicationId);
}

class TaskRemoteBasesCompanion extends UpdateCompanion<TaskRemoteBase> {
  final Value<int> accountId;
  final Value<int> taskId;
  final Value<int> taskListId;
  final Value<int?> parentTaskId;
  final Value<String> remoteId;
  final Value<String?> title;
  final Value<String?> notes;
  final Value<String?> status;
  final Value<int?> dueEpochDay;
  final Value<String?> position;
  final Value<DateTime?> completedAt;
  final Value<bool> hidden;
  final Value<bool> deleted;
  final Value<String?> etag;
  final Value<DateTime?> remoteUpdatedAt;
  final Value<String?> selfLink;
  final Value<String> linksJson;
  final Value<String?> webViewLink;
  final Value<String> observedPublicationId;
  final Value<int> rowid;
  const TaskRemoteBasesCompanion({
    this.accountId = const Value.absent(),
    this.taskId = const Value.absent(),
    this.taskListId = const Value.absent(),
    this.parentTaskId = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.title = const Value.absent(),
    this.notes = const Value.absent(),
    this.status = const Value.absent(),
    this.dueEpochDay = const Value.absent(),
    this.position = const Value.absent(),
    this.completedAt = const Value.absent(),
    this.hidden = const Value.absent(),
    this.deleted = const Value.absent(),
    this.etag = const Value.absent(),
    this.remoteUpdatedAt = const Value.absent(),
    this.selfLink = const Value.absent(),
    this.linksJson = const Value.absent(),
    this.webViewLink = const Value.absent(),
    this.observedPublicationId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TaskRemoteBasesCompanion.insert({
    required int accountId,
    required int taskId,
    required int taskListId,
    this.parentTaskId = const Value.absent(),
    required String remoteId,
    this.title = const Value.absent(),
    this.notes = const Value.absent(),
    this.status = const Value.absent(),
    this.dueEpochDay = const Value.absent(),
    this.position = const Value.absent(),
    this.completedAt = const Value.absent(),
    this.hidden = const Value.absent(),
    this.deleted = const Value.absent(),
    this.etag = const Value.absent(),
    this.remoteUpdatedAt = const Value.absent(),
    this.selfLink = const Value.absent(),
    this.linksJson = const Value.absent(),
    this.webViewLink = const Value.absent(),
    required String observedPublicationId,
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       taskId = Value(taskId),
       taskListId = Value(taskListId),
       remoteId = Value(remoteId),
       observedPublicationId = Value(observedPublicationId);
  static Insertable<TaskRemoteBase> custom({
    Expression<int>? accountId,
    Expression<int>? taskId,
    Expression<int>? taskListId,
    Expression<int>? parentTaskId,
    Expression<String>? remoteId,
    Expression<String>? title,
    Expression<String>? notes,
    Expression<String>? status,
    Expression<int>? dueEpochDay,
    Expression<String>? position,
    Expression<DateTime>? completedAt,
    Expression<bool>? hidden,
    Expression<bool>? deleted,
    Expression<String>? etag,
    Expression<DateTime>? remoteUpdatedAt,
    Expression<String>? selfLink,
    Expression<String>? linksJson,
    Expression<String>? webViewLink,
    Expression<String>? observedPublicationId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (taskId != null) 'task_id': taskId,
      if (taskListId != null) 'task_list_id': taskListId,
      if (parentTaskId != null) 'parent_task_id': parentTaskId,
      if (remoteId != null) 'remote_id': remoteId,
      if (title != null) 'title': title,
      if (notes != null) 'notes': notes,
      if (status != null) 'status': status,
      if (dueEpochDay != null) 'due_epoch_day': dueEpochDay,
      if (position != null) 'position': position,
      if (completedAt != null) 'completed_at': completedAt,
      if (hidden != null) 'hidden': hidden,
      if (deleted != null) 'deleted': deleted,
      if (etag != null) 'etag': etag,
      if (remoteUpdatedAt != null) 'remote_updated_at': remoteUpdatedAt,
      if (selfLink != null) 'self_link': selfLink,
      if (linksJson != null) 'links_json': linksJson,
      if (webViewLink != null) 'web_view_link': webViewLink,
      if (observedPublicationId != null)
        'observed_publication_id': observedPublicationId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TaskRemoteBasesCompanion copyWith({
    Value<int>? accountId,
    Value<int>? taskId,
    Value<int>? taskListId,
    Value<int?>? parentTaskId,
    Value<String>? remoteId,
    Value<String?>? title,
    Value<String?>? notes,
    Value<String?>? status,
    Value<int?>? dueEpochDay,
    Value<String?>? position,
    Value<DateTime?>? completedAt,
    Value<bool>? hidden,
    Value<bool>? deleted,
    Value<String?>? etag,
    Value<DateTime?>? remoteUpdatedAt,
    Value<String?>? selfLink,
    Value<String>? linksJson,
    Value<String?>? webViewLink,
    Value<String>? observedPublicationId,
    Value<int>? rowid,
  }) {
    return TaskRemoteBasesCompanion(
      accountId: accountId ?? this.accountId,
      taskId: taskId ?? this.taskId,
      taskListId: taskListId ?? this.taskListId,
      parentTaskId: parentTaskId ?? this.parentTaskId,
      remoteId: remoteId ?? this.remoteId,
      title: title ?? this.title,
      notes: notes ?? this.notes,
      status: status ?? this.status,
      dueEpochDay: dueEpochDay ?? this.dueEpochDay,
      position: position ?? this.position,
      completedAt: completedAt ?? this.completedAt,
      hidden: hidden ?? this.hidden,
      deleted: deleted ?? this.deleted,
      etag: etag ?? this.etag,
      remoteUpdatedAt: remoteUpdatedAt ?? this.remoteUpdatedAt,
      selfLink: selfLink ?? this.selfLink,
      linksJson: linksJson ?? this.linksJson,
      webViewLink: webViewLink ?? this.webViewLink,
      observedPublicationId:
          observedPublicationId ?? this.observedPublicationId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (taskId.present) {
      map['task_id'] = Variable<int>(taskId.value);
    }
    if (taskListId.present) {
      map['task_list_id'] = Variable<int>(taskListId.value);
    }
    if (parentTaskId.present) {
      map['parent_task_id'] = Variable<int>(parentTaskId.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
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
    if (dueEpochDay.present) {
      map['due_epoch_day'] = Variable<int>(dueEpochDay.value);
    }
    if (position.present) {
      map['position'] = Variable<String>(position.value);
    }
    if (completedAt.present) {
      map['completed_at'] = Variable<DateTime>(completedAt.value);
    }
    if (hidden.present) {
      map['hidden'] = Variable<bool>(hidden.value);
    }
    if (deleted.present) {
      map['deleted'] = Variable<bool>(deleted.value);
    }
    if (etag.present) {
      map['etag'] = Variable<String>(etag.value);
    }
    if (remoteUpdatedAt.present) {
      map['remote_updated_at'] = Variable<DateTime>(remoteUpdatedAt.value);
    }
    if (selfLink.present) {
      map['self_link'] = Variable<String>(selfLink.value);
    }
    if (linksJson.present) {
      map['links_json'] = Variable<String>(linksJson.value);
    }
    if (webViewLink.present) {
      map['web_view_link'] = Variable<String>(webViewLink.value);
    }
    if (observedPublicationId.present) {
      map['observed_publication_id'] = Variable<String>(
        observedPublicationId.value,
      );
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TaskRemoteBasesCompanion(')
          ..write('accountId: $accountId, ')
          ..write('taskId: $taskId, ')
          ..write('taskListId: $taskListId, ')
          ..write('parentTaskId: $parentTaskId, ')
          ..write('remoteId: $remoteId, ')
          ..write('title: $title, ')
          ..write('notes: $notes, ')
          ..write('status: $status, ')
          ..write('dueEpochDay: $dueEpochDay, ')
          ..write('position: $position, ')
          ..write('completedAt: $completedAt, ')
          ..write('hidden: $hidden, ')
          ..write('deleted: $deleted, ')
          ..write('etag: $etag, ')
          ..write('remoteUpdatedAt: $remoteUpdatedAt, ')
          ..write('selfLink: $selfLink, ')
          ..write('linksJson: $linksJson, ')
          ..write('webViewLink: $webViewLink, ')
          ..write('observedPublicationId: $observedPublicationId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ScopeCompletenessRowsTable extends ScopeCompletenessRows
    with TableInfo<$ScopeCompletenessRowsTable, ScopeCompletenessRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ScopeCompletenessRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _scopeKindMeta = const VerificationMeta(
    'scopeKind',
  );
  @override
  late final GeneratedColumn<String> scopeKind = GeneratedColumn<String>(
    'scope_kind',
    aliasedName,
    false,
    check: () => scopeKind.isIn(const <String>['task_lists', 'tasks']),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _scopeKeyMeta = const VerificationMeta(
    'scopeKey',
  );
  @override
  late final GeneratedColumn<String> scopeKey = GeneratedColumn<String>(
    'scope_key',
    aliasedName,
    false,
    check: () => ComparableExpr(scopeKey.length).isBiggerThanValue(0),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _taskListIdMeta = const VerificationMeta(
    'taskListId',
  );
  @override
  late final GeneratedColumn<int> taskListId = GeneratedColumn<int>(
    'task_list_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _publicationIdMeta = const VerificationMeta(
    'publicationId',
  );
  @override
  late final GeneratedColumn<String> publicationId = GeneratedColumn<String>(
    'publication_id',
    aliasedName,
    false,
    check: () => ComparableExpr(publicationId.length).isBiggerThanValue(0),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nextPageTokenMeta = const VerificationMeta(
    'nextPageToken',
  );
  @override
  late final GeneratedColumn<String> nextPageToken = GeneratedColumn<String>(
    'next_page_token',
    aliasedName,
    true,
    check: () =>
        nextPageToken.isNull() |
        ComparableExpr(nextPageToken.length).isBiggerThanValue(0),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _collectionEtagMeta = const VerificationMeta(
    'collectionEtag',
  );
  @override
  late final GeneratedColumn<String> collectionEtag = GeneratedColumn<String>(
    'collection_etag',
    aliasedName,
    true,
    check: () =>
        collectionEtag.isNull() |
        ComparableExpr(collectionEtag.length).isBiggerThanValue(0),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _isCompleteMeta = const VerificationMeta(
    'isComplete',
  );
  @override
  late final GeneratedColumn<bool> isComplete = GeneratedColumn<bool>(
    'is_complete',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_complete" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    scopeKind,
    scopeKey,
    taskListId,
    publicationId,
    nextPageToken,
    collectionEtag,
    isComplete,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'scope_completeness';
  @override
  VerificationContext validateIntegrity(
    Insertable<ScopeCompletenessRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('scope_kind')) {
      context.handle(
        _scopeKindMeta,
        scopeKind.isAcceptableOrUnknown(data['scope_kind']!, _scopeKindMeta),
      );
    } else if (isInserting) {
      context.missing(_scopeKindMeta);
    }
    if (data.containsKey('scope_key')) {
      context.handle(
        _scopeKeyMeta,
        scopeKey.isAcceptableOrUnknown(data['scope_key']!, _scopeKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_scopeKeyMeta);
    }
    if (data.containsKey('task_list_id')) {
      context.handle(
        _taskListIdMeta,
        taskListId.isAcceptableOrUnknown(
          data['task_list_id']!,
          _taskListIdMeta,
        ),
      );
    }
    if (data.containsKey('publication_id')) {
      context.handle(
        _publicationIdMeta,
        publicationId.isAcceptableOrUnknown(
          data['publication_id']!,
          _publicationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_publicationIdMeta);
    }
    if (data.containsKey('next_page_token')) {
      context.handle(
        _nextPageTokenMeta,
        nextPageToken.isAcceptableOrUnknown(
          data['next_page_token']!,
          _nextPageTokenMeta,
        ),
      );
    }
    if (data.containsKey('collection_etag')) {
      context.handle(
        _collectionEtagMeta,
        collectionEtag.isAcceptableOrUnknown(
          data['collection_etag']!,
          _collectionEtagMeta,
        ),
      );
    }
    if (data.containsKey('is_complete')) {
      context.handle(
        _isCompleteMeta,
        isComplete.isAcceptableOrUnknown(data['is_complete']!, _isCompleteMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ScopeCompletenessRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ScopeCompletenessRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      scopeKind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}scope_kind'],
      )!,
      scopeKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}scope_key'],
      )!,
      taskListId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}task_list_id'],
      ),
      publicationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}publication_id'],
      )!,
      nextPageToken: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}next_page_token'],
      ),
      collectionEtag: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}collection_etag'],
      ),
      isComplete: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_complete'],
      )!,
    );
  }

  @override
  $ScopeCompletenessRowsTable createAlias(String alias) {
    return $ScopeCompletenessRowsTable(attachedDatabase, alias);
  }
}

class ScopeCompletenessRow extends DataClass
    implements Insertable<ScopeCompletenessRow> {
  final int id;
  final int accountId;
  final String scopeKind;
  final String scopeKey;
  final int? taskListId;
  final String publicationId;
  final String? nextPageToken;
  final String? collectionEtag;
  final bool isComplete;
  const ScopeCompletenessRow({
    required this.id,
    required this.accountId,
    required this.scopeKind,
    required this.scopeKey,
    this.taskListId,
    required this.publicationId,
    this.nextPageToken,
    this.collectionEtag,
    required this.isComplete,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['account_id'] = Variable<int>(accountId);
    map['scope_kind'] = Variable<String>(scopeKind);
    map['scope_key'] = Variable<String>(scopeKey);
    if (!nullToAbsent || taskListId != null) {
      map['task_list_id'] = Variable<int>(taskListId);
    }
    map['publication_id'] = Variable<String>(publicationId);
    if (!nullToAbsent || nextPageToken != null) {
      map['next_page_token'] = Variable<String>(nextPageToken);
    }
    if (!nullToAbsent || collectionEtag != null) {
      map['collection_etag'] = Variable<String>(collectionEtag);
    }
    map['is_complete'] = Variable<bool>(isComplete);
    return map;
  }

  ScopeCompletenessRowsCompanion toCompanion(bool nullToAbsent) {
    return ScopeCompletenessRowsCompanion(
      id: Value(id),
      accountId: Value(accountId),
      scopeKind: Value(scopeKind),
      scopeKey: Value(scopeKey),
      taskListId: taskListId == null && nullToAbsent
          ? const Value.absent()
          : Value(taskListId),
      publicationId: Value(publicationId),
      nextPageToken: nextPageToken == null && nullToAbsent
          ? const Value.absent()
          : Value(nextPageToken),
      collectionEtag: collectionEtag == null && nullToAbsent
          ? const Value.absent()
          : Value(collectionEtag),
      isComplete: Value(isComplete),
    );
  }

  factory ScopeCompletenessRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ScopeCompletenessRow(
      id: serializer.fromJson<int>(json['id']),
      accountId: serializer.fromJson<int>(json['accountId']),
      scopeKind: serializer.fromJson<String>(json['scopeKind']),
      scopeKey: serializer.fromJson<String>(json['scopeKey']),
      taskListId: serializer.fromJson<int?>(json['taskListId']),
      publicationId: serializer.fromJson<String>(json['publicationId']),
      nextPageToken: serializer.fromJson<String?>(json['nextPageToken']),
      collectionEtag: serializer.fromJson<String?>(json['collectionEtag']),
      isComplete: serializer.fromJson<bool>(json['isComplete']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'accountId': serializer.toJson<int>(accountId),
      'scopeKind': serializer.toJson<String>(scopeKind),
      'scopeKey': serializer.toJson<String>(scopeKey),
      'taskListId': serializer.toJson<int?>(taskListId),
      'publicationId': serializer.toJson<String>(publicationId),
      'nextPageToken': serializer.toJson<String?>(nextPageToken),
      'collectionEtag': serializer.toJson<String?>(collectionEtag),
      'isComplete': serializer.toJson<bool>(isComplete),
    };
  }

  ScopeCompletenessRow copyWith({
    int? id,
    int? accountId,
    String? scopeKind,
    String? scopeKey,
    Value<int?> taskListId = const Value.absent(),
    String? publicationId,
    Value<String?> nextPageToken = const Value.absent(),
    Value<String?> collectionEtag = const Value.absent(),
    bool? isComplete,
  }) => ScopeCompletenessRow(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    scopeKind: scopeKind ?? this.scopeKind,
    scopeKey: scopeKey ?? this.scopeKey,
    taskListId: taskListId.present ? taskListId.value : this.taskListId,
    publicationId: publicationId ?? this.publicationId,
    nextPageToken: nextPageToken.present
        ? nextPageToken.value
        : this.nextPageToken,
    collectionEtag: collectionEtag.present
        ? collectionEtag.value
        : this.collectionEtag,
    isComplete: isComplete ?? this.isComplete,
  );
  ScopeCompletenessRow copyWithCompanion(ScopeCompletenessRowsCompanion data) {
    return ScopeCompletenessRow(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      scopeKind: data.scopeKind.present ? data.scopeKind.value : this.scopeKind,
      scopeKey: data.scopeKey.present ? data.scopeKey.value : this.scopeKey,
      taskListId: data.taskListId.present
          ? data.taskListId.value
          : this.taskListId,
      publicationId: data.publicationId.present
          ? data.publicationId.value
          : this.publicationId,
      nextPageToken: data.nextPageToken.present
          ? data.nextPageToken.value
          : this.nextPageToken,
      collectionEtag: data.collectionEtag.present
          ? data.collectionEtag.value
          : this.collectionEtag,
      isComplete: data.isComplete.present
          ? data.isComplete.value
          : this.isComplete,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ScopeCompletenessRow(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('scopeKind: $scopeKind, ')
          ..write('scopeKey: $scopeKey, ')
          ..write('taskListId: $taskListId, ')
          ..write('publicationId: $publicationId, ')
          ..write('nextPageToken: $nextPageToken, ')
          ..write('collectionEtag: $collectionEtag, ')
          ..write('isComplete: $isComplete')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    scopeKind,
    scopeKey,
    taskListId,
    publicationId,
    nextPageToken,
    collectionEtag,
    isComplete,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ScopeCompletenessRow &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.scopeKind == this.scopeKind &&
          other.scopeKey == this.scopeKey &&
          other.taskListId == this.taskListId &&
          other.publicationId == this.publicationId &&
          other.nextPageToken == this.nextPageToken &&
          other.collectionEtag == this.collectionEtag &&
          other.isComplete == this.isComplete);
}

class ScopeCompletenessRowsCompanion
    extends UpdateCompanion<ScopeCompletenessRow> {
  final Value<int> id;
  final Value<int> accountId;
  final Value<String> scopeKind;
  final Value<String> scopeKey;
  final Value<int?> taskListId;
  final Value<String> publicationId;
  final Value<String?> nextPageToken;
  final Value<String?> collectionEtag;
  final Value<bool> isComplete;
  const ScopeCompletenessRowsCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.scopeKind = const Value.absent(),
    this.scopeKey = const Value.absent(),
    this.taskListId = const Value.absent(),
    this.publicationId = const Value.absent(),
    this.nextPageToken = const Value.absent(),
    this.collectionEtag = const Value.absent(),
    this.isComplete = const Value.absent(),
  });
  ScopeCompletenessRowsCompanion.insert({
    this.id = const Value.absent(),
    required int accountId,
    required String scopeKind,
    required String scopeKey,
    this.taskListId = const Value.absent(),
    required String publicationId,
    this.nextPageToken = const Value.absent(),
    this.collectionEtag = const Value.absent(),
    this.isComplete = const Value.absent(),
  }) : accountId = Value(accountId),
       scopeKind = Value(scopeKind),
       scopeKey = Value(scopeKey),
       publicationId = Value(publicationId);
  static Insertable<ScopeCompletenessRow> custom({
    Expression<int>? id,
    Expression<int>? accountId,
    Expression<String>? scopeKind,
    Expression<String>? scopeKey,
    Expression<int>? taskListId,
    Expression<String>? publicationId,
    Expression<String>? nextPageToken,
    Expression<String>? collectionEtag,
    Expression<bool>? isComplete,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (scopeKind != null) 'scope_kind': scopeKind,
      if (scopeKey != null) 'scope_key': scopeKey,
      if (taskListId != null) 'task_list_id': taskListId,
      if (publicationId != null) 'publication_id': publicationId,
      if (nextPageToken != null) 'next_page_token': nextPageToken,
      if (collectionEtag != null) 'collection_etag': collectionEtag,
      if (isComplete != null) 'is_complete': isComplete,
    });
  }

  ScopeCompletenessRowsCompanion copyWith({
    Value<int>? id,
    Value<int>? accountId,
    Value<String>? scopeKind,
    Value<String>? scopeKey,
    Value<int?>? taskListId,
    Value<String>? publicationId,
    Value<String?>? nextPageToken,
    Value<String?>? collectionEtag,
    Value<bool>? isComplete,
  }) {
    return ScopeCompletenessRowsCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      scopeKind: scopeKind ?? this.scopeKind,
      scopeKey: scopeKey ?? this.scopeKey,
      taskListId: taskListId ?? this.taskListId,
      publicationId: publicationId ?? this.publicationId,
      nextPageToken: nextPageToken ?? this.nextPageToken,
      collectionEtag: collectionEtag ?? this.collectionEtag,
      isComplete: isComplete ?? this.isComplete,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (scopeKind.present) {
      map['scope_kind'] = Variable<String>(scopeKind.value);
    }
    if (scopeKey.present) {
      map['scope_key'] = Variable<String>(scopeKey.value);
    }
    if (taskListId.present) {
      map['task_list_id'] = Variable<int>(taskListId.value);
    }
    if (publicationId.present) {
      map['publication_id'] = Variable<String>(publicationId.value);
    }
    if (nextPageToken.present) {
      map['next_page_token'] = Variable<String>(nextPageToken.value);
    }
    if (collectionEtag.present) {
      map['collection_etag'] = Variable<String>(collectionEtag.value);
    }
    if (isComplete.present) {
      map['is_complete'] = Variable<bool>(isComplete.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ScopeCompletenessRowsCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('scopeKind: $scopeKind, ')
          ..write('scopeKey: $scopeKey, ')
          ..write('taskListId: $taskListId, ')
          ..write('publicationId: $publicationId, ')
          ..write('nextPageToken: $nextPageToken, ')
          ..write('collectionEtag: $collectionEtag, ')
          ..write('isComplete: $isComplete')
          ..write(')'))
        .toString();
  }
}

class $AccountPreferenceRowsTable extends AccountPreferenceRows
    with TableInfo<$AccountPreferenceRowsTable, AccountPreferenceRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AccountPreferenceRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _syncEnabledMeta = const VerificationMeta(
    'syncEnabled',
  );
  @override
  late final GeneratedColumn<bool> syncEnabled = GeneratedColumn<bool>(
    'sync_enabled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("sync_enabled" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _defaultTaskListIdMeta = const VerificationMeta(
    'defaultTaskListId',
  );
  @override
  late final GeneratedColumn<int> defaultTaskListId = GeneratedColumn<int>(
    'default_task_list_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    syncEnabled,
    defaultTaskListId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'account_preferences';
  @override
  VerificationContext validateIntegrity(
    Insertable<AccountPreferenceRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    }
    if (data.containsKey('sync_enabled')) {
      context.handle(
        _syncEnabledMeta,
        syncEnabled.isAcceptableOrUnknown(
          data['sync_enabled']!,
          _syncEnabledMeta,
        ),
      );
    }
    if (data.containsKey('default_task_list_id')) {
      context.handle(
        _defaultTaskListIdMeta,
        defaultTaskListId.isAcceptableOrUnknown(
          data['default_task_list_id']!,
          _defaultTaskListIdMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId};
  @override
  AccountPreferenceRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AccountPreferenceRow(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      syncEnabled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}sync_enabled'],
      )!,
      defaultTaskListId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}default_task_list_id'],
      ),
    );
  }

  @override
  $AccountPreferenceRowsTable createAlias(String alias) {
    return $AccountPreferenceRowsTable(attachedDatabase, alias);
  }
}

class AccountPreferenceRow extends DataClass
    implements Insertable<AccountPreferenceRow> {
  final int accountId;
  final bool syncEnabled;
  final int? defaultTaskListId;
  const AccountPreferenceRow({
    required this.accountId,
    required this.syncEnabled,
    this.defaultTaskListId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<int>(accountId);
    map['sync_enabled'] = Variable<bool>(syncEnabled);
    if (!nullToAbsent || defaultTaskListId != null) {
      map['default_task_list_id'] = Variable<int>(defaultTaskListId);
    }
    return map;
  }

  AccountPreferenceRowsCompanion toCompanion(bool nullToAbsent) {
    return AccountPreferenceRowsCompanion(
      accountId: Value(accountId),
      syncEnabled: Value(syncEnabled),
      defaultTaskListId: defaultTaskListId == null && nullToAbsent
          ? const Value.absent()
          : Value(defaultTaskListId),
    );
  }

  factory AccountPreferenceRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AccountPreferenceRow(
      accountId: serializer.fromJson<int>(json['accountId']),
      syncEnabled: serializer.fromJson<bool>(json['syncEnabled']),
      defaultTaskListId: serializer.fromJson<int?>(json['defaultTaskListId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<int>(accountId),
      'syncEnabled': serializer.toJson<bool>(syncEnabled),
      'defaultTaskListId': serializer.toJson<int?>(defaultTaskListId),
    };
  }

  AccountPreferenceRow copyWith({
    int? accountId,
    bool? syncEnabled,
    Value<int?> defaultTaskListId = const Value.absent(),
  }) => AccountPreferenceRow(
    accountId: accountId ?? this.accountId,
    syncEnabled: syncEnabled ?? this.syncEnabled,
    defaultTaskListId: defaultTaskListId.present
        ? defaultTaskListId.value
        : this.defaultTaskListId,
  );
  AccountPreferenceRow copyWithCompanion(AccountPreferenceRowsCompanion data) {
    return AccountPreferenceRow(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      syncEnabled: data.syncEnabled.present
          ? data.syncEnabled.value
          : this.syncEnabled,
      defaultTaskListId: data.defaultTaskListId.present
          ? data.defaultTaskListId.value
          : this.defaultTaskListId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AccountPreferenceRow(')
          ..write('accountId: $accountId, ')
          ..write('syncEnabled: $syncEnabled, ')
          ..write('defaultTaskListId: $defaultTaskListId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(accountId, syncEnabled, defaultTaskListId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AccountPreferenceRow &&
          other.accountId == this.accountId &&
          other.syncEnabled == this.syncEnabled &&
          other.defaultTaskListId == this.defaultTaskListId);
}

class AccountPreferenceRowsCompanion
    extends UpdateCompanion<AccountPreferenceRow> {
  final Value<int> accountId;
  final Value<bool> syncEnabled;
  final Value<int?> defaultTaskListId;
  const AccountPreferenceRowsCompanion({
    this.accountId = const Value.absent(),
    this.syncEnabled = const Value.absent(),
    this.defaultTaskListId = const Value.absent(),
  });
  AccountPreferenceRowsCompanion.insert({
    this.accountId = const Value.absent(),
    this.syncEnabled = const Value.absent(),
    this.defaultTaskListId = const Value.absent(),
  });
  static Insertable<AccountPreferenceRow> custom({
    Expression<int>? accountId,
    Expression<bool>? syncEnabled,
    Expression<int>? defaultTaskListId,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (syncEnabled != null) 'sync_enabled': syncEnabled,
      if (defaultTaskListId != null) 'default_task_list_id': defaultTaskListId,
    });
  }

  AccountPreferenceRowsCompanion copyWith({
    Value<int>? accountId,
    Value<bool>? syncEnabled,
    Value<int?>? defaultTaskListId,
  }) {
    return AccountPreferenceRowsCompanion(
      accountId: accountId ?? this.accountId,
      syncEnabled: syncEnabled ?? this.syncEnabled,
      defaultTaskListId: defaultTaskListId ?? this.defaultTaskListId,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (syncEnabled.present) {
      map['sync_enabled'] = Variable<bool>(syncEnabled.value);
    }
    if (defaultTaskListId.present) {
      map['default_task_list_id'] = Variable<int>(defaultTaskListId.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AccountPreferenceRowsCompanion(')
          ..write('accountId: $accountId, ')
          ..write('syncEnabled: $syncEnabled, ')
          ..write('defaultTaskListId: $defaultTaskListId')
          ..write(')'))
        .toString();
  }
}

class $TaskListPreferenceRowsTable extends TaskListPreferenceRows
    with TableInfo<$TaskListPreferenceRowsTable, TaskListPreferenceRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TaskListPreferenceRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _taskListIdMeta = const VerificationMeta(
    'taskListId',
  );
  @override
  late final GeneratedColumn<int> taskListId = GeneratedColumn<int>(
    'task_list_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sidebarOrderMeta = const VerificationMeta(
    'sidebarOrder',
  );
  @override
  late final GeneratedColumn<int> sidebarOrder = GeneratedColumn<int>(
    'sidebar_order',
    aliasedName,
    true,
    check: () =>
        sidebarOrder.isNull() |
        ComparableExpr(sidebarOrder).isBiggerOrEqualValue(0),
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _excludedFromSmartViewsMeta =
      const VerificationMeta('excludedFromSmartViews');
  @override
  late final GeneratedColumn<bool> excludedFromSmartViews =
      GeneratedColumn<bool>(
        'excluded_from_smart_views',
        aliasedName,
        false,
        type: DriftSqlType.bool,
        requiredDuringInsert: false,
        defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("excluded_from_smart_views" IN (0, 1))',
        ),
        defaultValue: const Constant(false),
      );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    taskListId,
    sidebarOrder,
    excludedFromSmartViews,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'task_list_preferences';
  @override
  VerificationContext validateIntegrity(
    Insertable<TaskListPreferenceRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('task_list_id')) {
      context.handle(
        _taskListIdMeta,
        taskListId.isAcceptableOrUnknown(
          data['task_list_id']!,
          _taskListIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_taskListIdMeta);
    }
    if (data.containsKey('sidebar_order')) {
      context.handle(
        _sidebarOrderMeta,
        sidebarOrder.isAcceptableOrUnknown(
          data['sidebar_order']!,
          _sidebarOrderMeta,
        ),
      );
    }
    if (data.containsKey('excluded_from_smart_views')) {
      context.handle(
        _excludedFromSmartViewsMeta,
        excludedFromSmartViews.isAcceptableOrUnknown(
          data['excluded_from_smart_views']!,
          _excludedFromSmartViewsMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId, taskListId};
  @override
  TaskListPreferenceRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TaskListPreferenceRow(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      taskListId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}task_list_id'],
      )!,
      sidebarOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sidebar_order'],
      ),
      excludedFromSmartViews: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}excluded_from_smart_views'],
      )!,
    );
  }

  @override
  $TaskListPreferenceRowsTable createAlias(String alias) {
    return $TaskListPreferenceRowsTable(attachedDatabase, alias);
  }
}

class TaskListPreferenceRow extends DataClass
    implements Insertable<TaskListPreferenceRow> {
  final int accountId;
  final int taskListId;
  final int? sidebarOrder;
  final bool excludedFromSmartViews;
  const TaskListPreferenceRow({
    required this.accountId,
    required this.taskListId,
    this.sidebarOrder,
    required this.excludedFromSmartViews,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<int>(accountId);
    map['task_list_id'] = Variable<int>(taskListId);
    if (!nullToAbsent || sidebarOrder != null) {
      map['sidebar_order'] = Variable<int>(sidebarOrder);
    }
    map['excluded_from_smart_views'] = Variable<bool>(excludedFromSmartViews);
    return map;
  }

  TaskListPreferenceRowsCompanion toCompanion(bool nullToAbsent) {
    return TaskListPreferenceRowsCompanion(
      accountId: Value(accountId),
      taskListId: Value(taskListId),
      sidebarOrder: sidebarOrder == null && nullToAbsent
          ? const Value.absent()
          : Value(sidebarOrder),
      excludedFromSmartViews: Value(excludedFromSmartViews),
    );
  }

  factory TaskListPreferenceRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TaskListPreferenceRow(
      accountId: serializer.fromJson<int>(json['accountId']),
      taskListId: serializer.fromJson<int>(json['taskListId']),
      sidebarOrder: serializer.fromJson<int?>(json['sidebarOrder']),
      excludedFromSmartViews: serializer.fromJson<bool>(
        json['excludedFromSmartViews'],
      ),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<int>(accountId),
      'taskListId': serializer.toJson<int>(taskListId),
      'sidebarOrder': serializer.toJson<int?>(sidebarOrder),
      'excludedFromSmartViews': serializer.toJson<bool>(excludedFromSmartViews),
    };
  }

  TaskListPreferenceRow copyWith({
    int? accountId,
    int? taskListId,
    Value<int?> sidebarOrder = const Value.absent(),
    bool? excludedFromSmartViews,
  }) => TaskListPreferenceRow(
    accountId: accountId ?? this.accountId,
    taskListId: taskListId ?? this.taskListId,
    sidebarOrder: sidebarOrder.present ? sidebarOrder.value : this.sidebarOrder,
    excludedFromSmartViews:
        excludedFromSmartViews ?? this.excludedFromSmartViews,
  );
  TaskListPreferenceRow copyWithCompanion(
    TaskListPreferenceRowsCompanion data,
  ) {
    return TaskListPreferenceRow(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      taskListId: data.taskListId.present
          ? data.taskListId.value
          : this.taskListId,
      sidebarOrder: data.sidebarOrder.present
          ? data.sidebarOrder.value
          : this.sidebarOrder,
      excludedFromSmartViews: data.excludedFromSmartViews.present
          ? data.excludedFromSmartViews.value
          : this.excludedFromSmartViews,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TaskListPreferenceRow(')
          ..write('accountId: $accountId, ')
          ..write('taskListId: $taskListId, ')
          ..write('sidebarOrder: $sidebarOrder, ')
          ..write('excludedFromSmartViews: $excludedFromSmartViews')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(accountId, taskListId, sidebarOrder, excludedFromSmartViews);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TaskListPreferenceRow &&
          other.accountId == this.accountId &&
          other.taskListId == this.taskListId &&
          other.sidebarOrder == this.sidebarOrder &&
          other.excludedFromSmartViews == this.excludedFromSmartViews);
}

class TaskListPreferenceRowsCompanion
    extends UpdateCompanion<TaskListPreferenceRow> {
  final Value<int> accountId;
  final Value<int> taskListId;
  final Value<int?> sidebarOrder;
  final Value<bool> excludedFromSmartViews;
  final Value<int> rowid;
  const TaskListPreferenceRowsCompanion({
    this.accountId = const Value.absent(),
    this.taskListId = const Value.absent(),
    this.sidebarOrder = const Value.absent(),
    this.excludedFromSmartViews = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TaskListPreferenceRowsCompanion.insert({
    required int accountId,
    required int taskListId,
    this.sidebarOrder = const Value.absent(),
    this.excludedFromSmartViews = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       taskListId = Value(taskListId);
  static Insertable<TaskListPreferenceRow> custom({
    Expression<int>? accountId,
    Expression<int>? taskListId,
    Expression<int>? sidebarOrder,
    Expression<bool>? excludedFromSmartViews,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (taskListId != null) 'task_list_id': taskListId,
      if (sidebarOrder != null) 'sidebar_order': sidebarOrder,
      if (excludedFromSmartViews != null)
        'excluded_from_smart_views': excludedFromSmartViews,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TaskListPreferenceRowsCompanion copyWith({
    Value<int>? accountId,
    Value<int>? taskListId,
    Value<int?>? sidebarOrder,
    Value<bool>? excludedFromSmartViews,
    Value<int>? rowid,
  }) {
    return TaskListPreferenceRowsCompanion(
      accountId: accountId ?? this.accountId,
      taskListId: taskListId ?? this.taskListId,
      sidebarOrder: sidebarOrder ?? this.sidebarOrder,
      excludedFromSmartViews:
          excludedFromSmartViews ?? this.excludedFromSmartViews,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (taskListId.present) {
      map['task_list_id'] = Variable<int>(taskListId.value);
    }
    if (sidebarOrder.present) {
      map['sidebar_order'] = Variable<int>(sidebarOrder.value);
    }
    if (excludedFromSmartViews.present) {
      map['excluded_from_smart_views'] = Variable<bool>(
        excludedFromSmartViews.value,
      );
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TaskListPreferenceRowsCompanion(')
          ..write('accountId: $accountId, ')
          ..write('taskListId: $taskListId, ')
          ..write('sidebarOrder: $sidebarOrder, ')
          ..write('excludedFromSmartViews: $excludedFromSmartViews, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ViewPreferenceRowsTable extends ViewPreferenceRows
    with TableInfo<$ViewPreferenceRowsTable, ViewPreferenceRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ViewPreferenceRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _viewKeyMeta = const VerificationMeta(
    'viewKey',
  );
  @override
  late final GeneratedColumn<String> viewKey = GeneratedColumn<String>(
    'view_key',
    aliasedName,
    false,
    check: () => ComparableExpr(viewKey.length).isBiggerThanValue(0),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortModeMeta = const VerificationMeta(
    'sortMode',
  );
  @override
  late final GeneratedColumn<String> sortMode = GeneratedColumn<String>(
    'sort_mode',
    aliasedName,
    false,
    check: () => sortMode.isIn(const <String>[
      'manual',
      'effective_due',
      'title',
      'created',
    ]),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _showCompletedMeta = const VerificationMeta(
    'showCompleted',
  );
  @override
  late final GeneratedColumn<bool> showCompleted = GeneratedColumn<bool>(
    'show_completed',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("show_completed" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    viewKey,
    sortMode,
    showCompleted,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'view_preferences';
  @override
  VerificationContext validateIntegrity(
    Insertable<ViewPreferenceRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('view_key')) {
      context.handle(
        _viewKeyMeta,
        viewKey.isAcceptableOrUnknown(data['view_key']!, _viewKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_viewKeyMeta);
    }
    if (data.containsKey('sort_mode')) {
      context.handle(
        _sortModeMeta,
        sortMode.isAcceptableOrUnknown(data['sort_mode']!, _sortModeMeta),
      );
    } else if (isInserting) {
      context.missing(_sortModeMeta);
    }
    if (data.containsKey('show_completed')) {
      context.handle(
        _showCompletedMeta,
        showCompleted.isAcceptableOrUnknown(
          data['show_completed']!,
          _showCompletedMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId, viewKey};
  @override
  ViewPreferenceRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ViewPreferenceRow(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      viewKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}view_key'],
      )!,
      sortMode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sort_mode'],
      )!,
      showCompleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}show_completed'],
      )!,
    );
  }

  @override
  $ViewPreferenceRowsTable createAlias(String alias) {
    return $ViewPreferenceRowsTable(attachedDatabase, alias);
  }
}

class ViewPreferenceRow extends DataClass
    implements Insertable<ViewPreferenceRow> {
  final int accountId;
  final String viewKey;
  final String sortMode;
  final bool showCompleted;
  const ViewPreferenceRow({
    required this.accountId,
    required this.viewKey,
    required this.sortMode,
    required this.showCompleted,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<int>(accountId);
    map['view_key'] = Variable<String>(viewKey);
    map['sort_mode'] = Variable<String>(sortMode);
    map['show_completed'] = Variable<bool>(showCompleted);
    return map;
  }

  ViewPreferenceRowsCompanion toCompanion(bool nullToAbsent) {
    return ViewPreferenceRowsCompanion(
      accountId: Value(accountId),
      viewKey: Value(viewKey),
      sortMode: Value(sortMode),
      showCompleted: Value(showCompleted),
    );
  }

  factory ViewPreferenceRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ViewPreferenceRow(
      accountId: serializer.fromJson<int>(json['accountId']),
      viewKey: serializer.fromJson<String>(json['viewKey']),
      sortMode: serializer.fromJson<String>(json['sortMode']),
      showCompleted: serializer.fromJson<bool>(json['showCompleted']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<int>(accountId),
      'viewKey': serializer.toJson<String>(viewKey),
      'sortMode': serializer.toJson<String>(sortMode),
      'showCompleted': serializer.toJson<bool>(showCompleted),
    };
  }

  ViewPreferenceRow copyWith({
    int? accountId,
    String? viewKey,
    String? sortMode,
    bool? showCompleted,
  }) => ViewPreferenceRow(
    accountId: accountId ?? this.accountId,
    viewKey: viewKey ?? this.viewKey,
    sortMode: sortMode ?? this.sortMode,
    showCompleted: showCompleted ?? this.showCompleted,
  );
  ViewPreferenceRow copyWithCompanion(ViewPreferenceRowsCompanion data) {
    return ViewPreferenceRow(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      viewKey: data.viewKey.present ? data.viewKey.value : this.viewKey,
      sortMode: data.sortMode.present ? data.sortMode.value : this.sortMode,
      showCompleted: data.showCompleted.present
          ? data.showCompleted.value
          : this.showCompleted,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ViewPreferenceRow(')
          ..write('accountId: $accountId, ')
          ..write('viewKey: $viewKey, ')
          ..write('sortMode: $sortMode, ')
          ..write('showCompleted: $showCompleted')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(accountId, viewKey, sortMode, showCompleted);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ViewPreferenceRow &&
          other.accountId == this.accountId &&
          other.viewKey == this.viewKey &&
          other.sortMode == this.sortMode &&
          other.showCompleted == this.showCompleted);
}

class ViewPreferenceRowsCompanion extends UpdateCompanion<ViewPreferenceRow> {
  final Value<int> accountId;
  final Value<String> viewKey;
  final Value<String> sortMode;
  final Value<bool> showCompleted;
  final Value<int> rowid;
  const ViewPreferenceRowsCompanion({
    this.accountId = const Value.absent(),
    this.viewKey = const Value.absent(),
    this.sortMode = const Value.absent(),
    this.showCompleted = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ViewPreferenceRowsCompanion.insert({
    required int accountId,
    required String viewKey,
    required String sortMode,
    this.showCompleted = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       viewKey = Value(viewKey),
       sortMode = Value(sortMode);
  static Insertable<ViewPreferenceRow> custom({
    Expression<int>? accountId,
    Expression<String>? viewKey,
    Expression<String>? sortMode,
    Expression<bool>? showCompleted,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (viewKey != null) 'view_key': viewKey,
      if (sortMode != null) 'sort_mode': sortMode,
      if (showCompleted != null) 'show_completed': showCompleted,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ViewPreferenceRowsCompanion copyWith({
    Value<int>? accountId,
    Value<String>? viewKey,
    Value<String>? sortMode,
    Value<bool>? showCompleted,
    Value<int>? rowid,
  }) {
    return ViewPreferenceRowsCompanion(
      accountId: accountId ?? this.accountId,
      viewKey: viewKey ?? this.viewKey,
      sortMode: sortMode ?? this.sortMode,
      showCompleted: showCompleted ?? this.showCompleted,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (viewKey.present) {
      map['view_key'] = Variable<String>(viewKey.value);
    }
    if (sortMode.present) {
      map['sort_mode'] = Variable<String>(sortMode.value);
    }
    if (showCompleted.present) {
      map['show_completed'] = Variable<bool>(showCompleted.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ViewPreferenceRowsCompanion(')
          ..write('accountId: $accountId, ')
          ..write('viewKey: $viewKey, ')
          ..write('sortMode: $sortMode, ')
          ..write('showCompleted: $showCompleted, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $AccountsTable accounts = $AccountsTable(this);
  late final $TaskListCacheRowsTable taskListCacheRows =
      $TaskListCacheRowsTable(this);
  late final $TaskCacheRowsTable taskCacheRows = $TaskCacheRowsTable(this);
  late final $TaskListRemoteBasesTable taskListRemoteBases =
      $TaskListRemoteBasesTable(this);
  late final $TaskRemoteBasesTable taskRemoteBases = $TaskRemoteBasesTable(
    this,
  );
  late final $ScopeCompletenessRowsTable scopeCompletenessRows =
      $ScopeCompletenessRowsTable(this);
  late final $AccountPreferenceRowsTable accountPreferenceRows =
      $AccountPreferenceRowsTable(this);
  late final $TaskListPreferenceRowsTable taskListPreferenceRows =
      $TaskListPreferenceRowsTable(this);
  late final $ViewPreferenceRowsTable viewPreferenceRows =
      $ViewPreferenceRowsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    accounts,
    taskListCacheRows,
    taskCacheRows,
    taskListRemoteBases,
    taskRemoteBases,
    scopeCompletenessRows,
    accountPreferenceRows,
    taskListPreferenceRows,
    viewPreferenceRows,
  ];
}

typedef $$AccountsTableCreateCompanionBuilder =
    AccountsCompanion Function({Value<int> id, required String googleSubject});
typedef $$AccountsTableUpdateCompanionBuilder =
    AccountsCompanion Function({Value<int> id, Value<String> googleSubject});

class $$AccountsTableFilterComposer
    extends Composer<_$AppDatabase, $AccountsTable> {
  $$AccountsTableFilterComposer({
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

  ColumnFilters<String> get googleSubject => $composableBuilder(
    column: $table.googleSubject,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AccountsTableOrderingComposer
    extends Composer<_$AppDatabase, $AccountsTable> {
  $$AccountsTableOrderingComposer({
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

  ColumnOrderings<String> get googleSubject => $composableBuilder(
    column: $table.googleSubject,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AccountsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AccountsTable> {
  $$AccountsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get googleSubject => $composableBuilder(
    column: $table.googleSubject,
    builder: (column) => column,
  );
}

class $$AccountsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AccountsTable,
          Account,
          $$AccountsTableFilterComposer,
          $$AccountsTableOrderingComposer,
          $$AccountsTableAnnotationComposer,
          $$AccountsTableCreateCompanionBuilder,
          $$AccountsTableUpdateCompanionBuilder,
          (Account, BaseReferences<_$AppDatabase, $AccountsTable, Account>),
          Account,
          PrefetchHooks Function()
        > {
  $$AccountsTableTableManager(_$AppDatabase db, $AccountsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AccountsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AccountsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AccountsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> googleSubject = const Value.absent(),
              }) => AccountsCompanion(id: id, googleSubject: googleSubject),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String googleSubject,
              }) => AccountsCompanion.insert(
                id: id,
                googleSubject: googleSubject,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AccountsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AccountsTable,
      Account,
      $$AccountsTableFilterComposer,
      $$AccountsTableOrderingComposer,
      $$AccountsTableAnnotationComposer,
      $$AccountsTableCreateCompanionBuilder,
      $$AccountsTableUpdateCompanionBuilder,
      (Account, BaseReferences<_$AppDatabase, $AccountsTable, Account>),
      Account,
      PrefetchHooks Function()
    >;
typedef $$TaskListCacheRowsTableCreateCompanionBuilder =
    TaskListCacheRowsCompanion Function({
      Value<int> id,
      required int accountId,
      Value<String?> remoteId,
      required String title,
      required String projection,
    });
typedef $$TaskListCacheRowsTableUpdateCompanionBuilder =
    TaskListCacheRowsCompanion Function({
      Value<int> id,
      Value<int> accountId,
      Value<String?> remoteId,
      Value<String> title,
      Value<String> projection,
    });

class $$TaskListCacheRowsTableFilterComposer
    extends Composer<_$AppDatabase, $TaskListCacheRowsTable> {
  $$TaskListCacheRowsTableFilterComposer({
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

  ColumnFilters<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get projection => $composableBuilder(
    column: $table.projection,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TaskListCacheRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $TaskListCacheRowsTable> {
  $$TaskListCacheRowsTableOrderingComposer({
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

  ColumnOrderings<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get projection => $composableBuilder(
    column: $table.projection,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TaskListCacheRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $TaskListCacheRowsTable> {
  $$TaskListCacheRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get projection => $composableBuilder(
    column: $table.projection,
    builder: (column) => column,
  );
}

class $$TaskListCacheRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TaskListCacheRowsTable,
          TaskListCacheRow,
          $$TaskListCacheRowsTableFilterComposer,
          $$TaskListCacheRowsTableOrderingComposer,
          $$TaskListCacheRowsTableAnnotationComposer,
          $$TaskListCacheRowsTableCreateCompanionBuilder,
          $$TaskListCacheRowsTableUpdateCompanionBuilder,
          (
            TaskListCacheRow,
            BaseReferences<
              _$AppDatabase,
              $TaskListCacheRowsTable,
              TaskListCacheRow
            >,
          ),
          TaskListCacheRow,
          PrefetchHooks Function()
        > {
  $$TaskListCacheRowsTableTableManager(
    _$AppDatabase db,
    $TaskListCacheRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TaskListCacheRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TaskListCacheRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TaskListCacheRowsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> accountId = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> projection = const Value.absent(),
              }) => TaskListCacheRowsCompanion(
                id: id,
                accountId: accountId,
                remoteId: remoteId,
                title: title,
                projection: projection,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int accountId,
                Value<String?> remoteId = const Value.absent(),
                required String title,
                required String projection,
              }) => TaskListCacheRowsCompanion.insert(
                id: id,
                accountId: accountId,
                remoteId: remoteId,
                title: title,
                projection: projection,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TaskListCacheRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TaskListCacheRowsTable,
      TaskListCacheRow,
      $$TaskListCacheRowsTableFilterComposer,
      $$TaskListCacheRowsTableOrderingComposer,
      $$TaskListCacheRowsTableAnnotationComposer,
      $$TaskListCacheRowsTableCreateCompanionBuilder,
      $$TaskListCacheRowsTableUpdateCompanionBuilder,
      (
        TaskListCacheRow,
        BaseReferences<
          _$AppDatabase,
          $TaskListCacheRowsTable,
          TaskListCacheRow
        >,
      ),
      TaskListCacheRow,
      PrefetchHooks Function()
    >;
typedef $$TaskCacheRowsTableCreateCompanionBuilder =
    TaskCacheRowsCompanion Function({
      Value<int> id,
      required int accountId,
      required int taskListId,
      Value<int?> parentTaskId,
      Value<String?> remoteId,
      required String title,
      Value<String?> notes,
      required String status,
      Value<int?> dueEpochDay,
      required String position,
      required String projection,
    });
typedef $$TaskCacheRowsTableUpdateCompanionBuilder =
    TaskCacheRowsCompanion Function({
      Value<int> id,
      Value<int> accountId,
      Value<int> taskListId,
      Value<int?> parentTaskId,
      Value<String?> remoteId,
      Value<String> title,
      Value<String?> notes,
      Value<String> status,
      Value<int?> dueEpochDay,
      Value<String> position,
      Value<String> projection,
    });

class $$TaskCacheRowsTableFilterComposer
    extends Composer<_$AppDatabase, $TaskCacheRowsTable> {
  $$TaskCacheRowsTableFilterComposer({
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

  ColumnFilters<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get taskListId => $composableBuilder(
    column: $table.taskListId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get parentTaskId => $composableBuilder(
    column: $table.parentTaskId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
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

  ColumnFilters<int> get dueEpochDay => $composableBuilder(
    column: $table.dueEpochDay,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get projection => $composableBuilder(
    column: $table.projection,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TaskCacheRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $TaskCacheRowsTable> {
  $$TaskCacheRowsTableOrderingComposer({
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

  ColumnOrderings<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get taskListId => $composableBuilder(
    column: $table.taskListId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get parentTaskId => $composableBuilder(
    column: $table.parentTaskId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
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

  ColumnOrderings<int> get dueEpochDay => $composableBuilder(
    column: $table.dueEpochDay,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get projection => $composableBuilder(
    column: $table.projection,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TaskCacheRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $TaskCacheRowsTable> {
  $$TaskCacheRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<int> get taskListId => $composableBuilder(
    column: $table.taskListId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get parentTaskId => $composableBuilder(
    column: $table.parentTaskId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get dueEpochDay => $composableBuilder(
    column: $table.dueEpochDay,
    builder: (column) => column,
  );

  GeneratedColumn<String> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  GeneratedColumn<String> get projection => $composableBuilder(
    column: $table.projection,
    builder: (column) => column,
  );
}

class $$TaskCacheRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TaskCacheRowsTable,
          TaskCacheRow,
          $$TaskCacheRowsTableFilterComposer,
          $$TaskCacheRowsTableOrderingComposer,
          $$TaskCacheRowsTableAnnotationComposer,
          $$TaskCacheRowsTableCreateCompanionBuilder,
          $$TaskCacheRowsTableUpdateCompanionBuilder,
          (
            TaskCacheRow,
            BaseReferences<_$AppDatabase, $TaskCacheRowsTable, TaskCacheRow>,
          ),
          TaskCacheRow,
          PrefetchHooks Function()
        > {
  $$TaskCacheRowsTableTableManager(_$AppDatabase db, $TaskCacheRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TaskCacheRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TaskCacheRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TaskCacheRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> accountId = const Value.absent(),
                Value<int> taskListId = const Value.absent(),
                Value<int?> parentTaskId = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int?> dueEpochDay = const Value.absent(),
                Value<String> position = const Value.absent(),
                Value<String> projection = const Value.absent(),
              }) => TaskCacheRowsCompanion(
                id: id,
                accountId: accountId,
                taskListId: taskListId,
                parentTaskId: parentTaskId,
                remoteId: remoteId,
                title: title,
                notes: notes,
                status: status,
                dueEpochDay: dueEpochDay,
                position: position,
                projection: projection,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int accountId,
                required int taskListId,
                Value<int?> parentTaskId = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                required String title,
                Value<String?> notes = const Value.absent(),
                required String status,
                Value<int?> dueEpochDay = const Value.absent(),
                required String position,
                required String projection,
              }) => TaskCacheRowsCompanion.insert(
                id: id,
                accountId: accountId,
                taskListId: taskListId,
                parentTaskId: parentTaskId,
                remoteId: remoteId,
                title: title,
                notes: notes,
                status: status,
                dueEpochDay: dueEpochDay,
                position: position,
                projection: projection,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TaskCacheRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TaskCacheRowsTable,
      TaskCacheRow,
      $$TaskCacheRowsTableFilterComposer,
      $$TaskCacheRowsTableOrderingComposer,
      $$TaskCacheRowsTableAnnotationComposer,
      $$TaskCacheRowsTableCreateCompanionBuilder,
      $$TaskCacheRowsTableUpdateCompanionBuilder,
      (
        TaskCacheRow,
        BaseReferences<_$AppDatabase, $TaskCacheRowsTable, TaskCacheRow>,
      ),
      TaskCacheRow,
      PrefetchHooks Function()
    >;
typedef $$TaskListRemoteBasesTableCreateCompanionBuilder =
    TaskListRemoteBasesCompanion Function({
      required int accountId,
      required int taskListId,
      required String remoteId,
      required String title,
      Value<String?> etag,
      Value<DateTime?> remoteUpdatedAt,
      Value<bool> deleted,
      required String observedPublicationId,
      Value<int> rowid,
    });
typedef $$TaskListRemoteBasesTableUpdateCompanionBuilder =
    TaskListRemoteBasesCompanion Function({
      Value<int> accountId,
      Value<int> taskListId,
      Value<String> remoteId,
      Value<String> title,
      Value<String?> etag,
      Value<DateTime?> remoteUpdatedAt,
      Value<bool> deleted,
      Value<String> observedPublicationId,
      Value<int> rowid,
    });

class $$TaskListRemoteBasesTableFilterComposer
    extends Composer<_$AppDatabase, $TaskListRemoteBasesTable> {
  $$TaskListRemoteBasesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get taskListId => $composableBuilder(
    column: $table.taskListId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
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

  ColumnFilters<DateTime> get remoteUpdatedAt => $composableBuilder(
    column: $table.remoteUpdatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get observedPublicationId => $composableBuilder(
    column: $table.observedPublicationId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TaskListRemoteBasesTableOrderingComposer
    extends Composer<_$AppDatabase, $TaskListRemoteBasesTable> {
  $$TaskListRemoteBasesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get taskListId => $composableBuilder(
    column: $table.taskListId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
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

  ColumnOrderings<DateTime> get remoteUpdatedAt => $composableBuilder(
    column: $table.remoteUpdatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get observedPublicationId => $composableBuilder(
    column: $table.observedPublicationId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TaskListRemoteBasesTableAnnotationComposer
    extends Composer<_$AppDatabase, $TaskListRemoteBasesTable> {
  $$TaskListRemoteBasesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<int> get taskListId => $composableBuilder(
    column: $table.taskListId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get etag =>
      $composableBuilder(column: $table.etag, builder: (column) => column);

  GeneratedColumn<DateTime> get remoteUpdatedAt => $composableBuilder(
    column: $table.remoteUpdatedAt,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get deleted =>
      $composableBuilder(column: $table.deleted, builder: (column) => column);

  GeneratedColumn<String> get observedPublicationId => $composableBuilder(
    column: $table.observedPublicationId,
    builder: (column) => column,
  );
}

class $$TaskListRemoteBasesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TaskListRemoteBasesTable,
          TaskListRemoteBase,
          $$TaskListRemoteBasesTableFilterComposer,
          $$TaskListRemoteBasesTableOrderingComposer,
          $$TaskListRemoteBasesTableAnnotationComposer,
          $$TaskListRemoteBasesTableCreateCompanionBuilder,
          $$TaskListRemoteBasesTableUpdateCompanionBuilder,
          (
            TaskListRemoteBase,
            BaseReferences<
              _$AppDatabase,
              $TaskListRemoteBasesTable,
              TaskListRemoteBase
            >,
          ),
          TaskListRemoteBase,
          PrefetchHooks Function()
        > {
  $$TaskListRemoteBasesTableTableManager(
    _$AppDatabase db,
    $TaskListRemoteBasesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TaskListRemoteBasesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TaskListRemoteBasesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$TaskListRemoteBasesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> accountId = const Value.absent(),
                Value<int> taskListId = const Value.absent(),
                Value<String> remoteId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> etag = const Value.absent(),
                Value<DateTime?> remoteUpdatedAt = const Value.absent(),
                Value<bool> deleted = const Value.absent(),
                Value<String> observedPublicationId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TaskListRemoteBasesCompanion(
                accountId: accountId,
                taskListId: taskListId,
                remoteId: remoteId,
                title: title,
                etag: etag,
                remoteUpdatedAt: remoteUpdatedAt,
                deleted: deleted,
                observedPublicationId: observedPublicationId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int accountId,
                required int taskListId,
                required String remoteId,
                required String title,
                Value<String?> etag = const Value.absent(),
                Value<DateTime?> remoteUpdatedAt = const Value.absent(),
                Value<bool> deleted = const Value.absent(),
                required String observedPublicationId,
                Value<int> rowid = const Value.absent(),
              }) => TaskListRemoteBasesCompanion.insert(
                accountId: accountId,
                taskListId: taskListId,
                remoteId: remoteId,
                title: title,
                etag: etag,
                remoteUpdatedAt: remoteUpdatedAt,
                deleted: deleted,
                observedPublicationId: observedPublicationId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TaskListRemoteBasesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TaskListRemoteBasesTable,
      TaskListRemoteBase,
      $$TaskListRemoteBasesTableFilterComposer,
      $$TaskListRemoteBasesTableOrderingComposer,
      $$TaskListRemoteBasesTableAnnotationComposer,
      $$TaskListRemoteBasesTableCreateCompanionBuilder,
      $$TaskListRemoteBasesTableUpdateCompanionBuilder,
      (
        TaskListRemoteBase,
        BaseReferences<
          _$AppDatabase,
          $TaskListRemoteBasesTable,
          TaskListRemoteBase
        >,
      ),
      TaskListRemoteBase,
      PrefetchHooks Function()
    >;
typedef $$TaskRemoteBasesTableCreateCompanionBuilder =
    TaskRemoteBasesCompanion Function({
      required int accountId,
      required int taskId,
      required int taskListId,
      Value<int?> parentTaskId,
      required String remoteId,
      Value<String?> title,
      Value<String?> notes,
      Value<String?> status,
      Value<int?> dueEpochDay,
      Value<String?> position,
      Value<DateTime?> completedAt,
      Value<bool> hidden,
      Value<bool> deleted,
      Value<String?> etag,
      Value<DateTime?> remoteUpdatedAt,
      Value<String?> selfLink,
      Value<String> linksJson,
      Value<String?> webViewLink,
      required String observedPublicationId,
      Value<int> rowid,
    });
typedef $$TaskRemoteBasesTableUpdateCompanionBuilder =
    TaskRemoteBasesCompanion Function({
      Value<int> accountId,
      Value<int> taskId,
      Value<int> taskListId,
      Value<int?> parentTaskId,
      Value<String> remoteId,
      Value<String?> title,
      Value<String?> notes,
      Value<String?> status,
      Value<int?> dueEpochDay,
      Value<String?> position,
      Value<DateTime?> completedAt,
      Value<bool> hidden,
      Value<bool> deleted,
      Value<String?> etag,
      Value<DateTime?> remoteUpdatedAt,
      Value<String?> selfLink,
      Value<String> linksJson,
      Value<String?> webViewLink,
      Value<String> observedPublicationId,
      Value<int> rowid,
    });

class $$TaskRemoteBasesTableFilterComposer
    extends Composer<_$AppDatabase, $TaskRemoteBasesTable> {
  $$TaskRemoteBasesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get taskId => $composableBuilder(
    column: $table.taskId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get taskListId => $composableBuilder(
    column: $table.taskListId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get parentTaskId => $composableBuilder(
    column: $table.parentTaskId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
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

  ColumnFilters<int> get dueEpochDay => $composableBuilder(
    column: $table.dueEpochDay,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get completedAt => $composableBuilder(
    column: $table.completedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get hidden => $composableBuilder(
    column: $table.hidden,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get etag => $composableBuilder(
    column: $table.etag,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get remoteUpdatedAt => $composableBuilder(
    column: $table.remoteUpdatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get selfLink => $composableBuilder(
    column: $table.selfLink,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get linksJson => $composableBuilder(
    column: $table.linksJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get webViewLink => $composableBuilder(
    column: $table.webViewLink,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get observedPublicationId => $composableBuilder(
    column: $table.observedPublicationId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TaskRemoteBasesTableOrderingComposer
    extends Composer<_$AppDatabase, $TaskRemoteBasesTable> {
  $$TaskRemoteBasesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get taskId => $composableBuilder(
    column: $table.taskId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get taskListId => $composableBuilder(
    column: $table.taskListId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get parentTaskId => $composableBuilder(
    column: $table.parentTaskId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
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

  ColumnOrderings<int> get dueEpochDay => $composableBuilder(
    column: $table.dueEpochDay,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get completedAt => $composableBuilder(
    column: $table.completedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get hidden => $composableBuilder(
    column: $table.hidden,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get etag => $composableBuilder(
    column: $table.etag,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get remoteUpdatedAt => $composableBuilder(
    column: $table.remoteUpdatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get selfLink => $composableBuilder(
    column: $table.selfLink,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get linksJson => $composableBuilder(
    column: $table.linksJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get webViewLink => $composableBuilder(
    column: $table.webViewLink,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get observedPublicationId => $composableBuilder(
    column: $table.observedPublicationId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TaskRemoteBasesTableAnnotationComposer
    extends Composer<_$AppDatabase, $TaskRemoteBasesTable> {
  $$TaskRemoteBasesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<int> get taskId =>
      $composableBuilder(column: $table.taskId, builder: (column) => column);

  GeneratedColumn<int> get taskListId => $composableBuilder(
    column: $table.taskListId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get parentTaskId => $composableBuilder(
    column: $table.parentTaskId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get dueEpochDay => $composableBuilder(
    column: $table.dueEpochDay,
    builder: (column) => column,
  );

  GeneratedColumn<String> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  GeneratedColumn<DateTime> get completedAt => $composableBuilder(
    column: $table.completedAt,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get hidden =>
      $composableBuilder(column: $table.hidden, builder: (column) => column);

  GeneratedColumn<bool> get deleted =>
      $composableBuilder(column: $table.deleted, builder: (column) => column);

  GeneratedColumn<String> get etag =>
      $composableBuilder(column: $table.etag, builder: (column) => column);

  GeneratedColumn<DateTime> get remoteUpdatedAt => $composableBuilder(
    column: $table.remoteUpdatedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get selfLink =>
      $composableBuilder(column: $table.selfLink, builder: (column) => column);

  GeneratedColumn<String> get linksJson =>
      $composableBuilder(column: $table.linksJson, builder: (column) => column);

  GeneratedColumn<String> get webViewLink => $composableBuilder(
    column: $table.webViewLink,
    builder: (column) => column,
  );

  GeneratedColumn<String> get observedPublicationId => $composableBuilder(
    column: $table.observedPublicationId,
    builder: (column) => column,
  );
}

class $$TaskRemoteBasesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TaskRemoteBasesTable,
          TaskRemoteBase,
          $$TaskRemoteBasesTableFilterComposer,
          $$TaskRemoteBasesTableOrderingComposer,
          $$TaskRemoteBasesTableAnnotationComposer,
          $$TaskRemoteBasesTableCreateCompanionBuilder,
          $$TaskRemoteBasesTableUpdateCompanionBuilder,
          (
            TaskRemoteBase,
            BaseReferences<
              _$AppDatabase,
              $TaskRemoteBasesTable,
              TaskRemoteBase
            >,
          ),
          TaskRemoteBase,
          PrefetchHooks Function()
        > {
  $$TaskRemoteBasesTableTableManager(
    _$AppDatabase db,
    $TaskRemoteBasesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TaskRemoteBasesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TaskRemoteBasesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TaskRemoteBasesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> accountId = const Value.absent(),
                Value<int> taskId = const Value.absent(),
                Value<int> taskListId = const Value.absent(),
                Value<int?> parentTaskId = const Value.absent(),
                Value<String> remoteId = const Value.absent(),
                Value<String?> title = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<String?> status = const Value.absent(),
                Value<int?> dueEpochDay = const Value.absent(),
                Value<String?> position = const Value.absent(),
                Value<DateTime?> completedAt = const Value.absent(),
                Value<bool> hidden = const Value.absent(),
                Value<bool> deleted = const Value.absent(),
                Value<String?> etag = const Value.absent(),
                Value<DateTime?> remoteUpdatedAt = const Value.absent(),
                Value<String?> selfLink = const Value.absent(),
                Value<String> linksJson = const Value.absent(),
                Value<String?> webViewLink = const Value.absent(),
                Value<String> observedPublicationId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TaskRemoteBasesCompanion(
                accountId: accountId,
                taskId: taskId,
                taskListId: taskListId,
                parentTaskId: parentTaskId,
                remoteId: remoteId,
                title: title,
                notes: notes,
                status: status,
                dueEpochDay: dueEpochDay,
                position: position,
                completedAt: completedAt,
                hidden: hidden,
                deleted: deleted,
                etag: etag,
                remoteUpdatedAt: remoteUpdatedAt,
                selfLink: selfLink,
                linksJson: linksJson,
                webViewLink: webViewLink,
                observedPublicationId: observedPublicationId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int accountId,
                required int taskId,
                required int taskListId,
                Value<int?> parentTaskId = const Value.absent(),
                required String remoteId,
                Value<String?> title = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<String?> status = const Value.absent(),
                Value<int?> dueEpochDay = const Value.absent(),
                Value<String?> position = const Value.absent(),
                Value<DateTime?> completedAt = const Value.absent(),
                Value<bool> hidden = const Value.absent(),
                Value<bool> deleted = const Value.absent(),
                Value<String?> etag = const Value.absent(),
                Value<DateTime?> remoteUpdatedAt = const Value.absent(),
                Value<String?> selfLink = const Value.absent(),
                Value<String> linksJson = const Value.absent(),
                Value<String?> webViewLink = const Value.absent(),
                required String observedPublicationId,
                Value<int> rowid = const Value.absent(),
              }) => TaskRemoteBasesCompanion.insert(
                accountId: accountId,
                taskId: taskId,
                taskListId: taskListId,
                parentTaskId: parentTaskId,
                remoteId: remoteId,
                title: title,
                notes: notes,
                status: status,
                dueEpochDay: dueEpochDay,
                position: position,
                completedAt: completedAt,
                hidden: hidden,
                deleted: deleted,
                etag: etag,
                remoteUpdatedAt: remoteUpdatedAt,
                selfLink: selfLink,
                linksJson: linksJson,
                webViewLink: webViewLink,
                observedPublicationId: observedPublicationId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TaskRemoteBasesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TaskRemoteBasesTable,
      TaskRemoteBase,
      $$TaskRemoteBasesTableFilterComposer,
      $$TaskRemoteBasesTableOrderingComposer,
      $$TaskRemoteBasesTableAnnotationComposer,
      $$TaskRemoteBasesTableCreateCompanionBuilder,
      $$TaskRemoteBasesTableUpdateCompanionBuilder,
      (
        TaskRemoteBase,
        BaseReferences<_$AppDatabase, $TaskRemoteBasesTable, TaskRemoteBase>,
      ),
      TaskRemoteBase,
      PrefetchHooks Function()
    >;
typedef $$ScopeCompletenessRowsTableCreateCompanionBuilder =
    ScopeCompletenessRowsCompanion Function({
      Value<int> id,
      required int accountId,
      required String scopeKind,
      required String scopeKey,
      Value<int?> taskListId,
      required String publicationId,
      Value<String?> nextPageToken,
      Value<String?> collectionEtag,
      Value<bool> isComplete,
    });
typedef $$ScopeCompletenessRowsTableUpdateCompanionBuilder =
    ScopeCompletenessRowsCompanion Function({
      Value<int> id,
      Value<int> accountId,
      Value<String> scopeKind,
      Value<String> scopeKey,
      Value<int?> taskListId,
      Value<String> publicationId,
      Value<String?> nextPageToken,
      Value<String?> collectionEtag,
      Value<bool> isComplete,
    });

class $$ScopeCompletenessRowsTableFilterComposer
    extends Composer<_$AppDatabase, $ScopeCompletenessRowsTable> {
  $$ScopeCompletenessRowsTableFilterComposer({
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

  ColumnFilters<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get scopeKind => $composableBuilder(
    column: $table.scopeKind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get scopeKey => $composableBuilder(
    column: $table.scopeKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get taskListId => $composableBuilder(
    column: $table.taskListId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get publicationId => $composableBuilder(
    column: $table.publicationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get nextPageToken => $composableBuilder(
    column: $table.nextPageToken,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get collectionEtag => $composableBuilder(
    column: $table.collectionEtag,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isComplete => $composableBuilder(
    column: $table.isComplete,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ScopeCompletenessRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $ScopeCompletenessRowsTable> {
  $$ScopeCompletenessRowsTableOrderingComposer({
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

  ColumnOrderings<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get scopeKind => $composableBuilder(
    column: $table.scopeKind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get scopeKey => $composableBuilder(
    column: $table.scopeKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get taskListId => $composableBuilder(
    column: $table.taskListId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get publicationId => $composableBuilder(
    column: $table.publicationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get nextPageToken => $composableBuilder(
    column: $table.nextPageToken,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get collectionEtag => $composableBuilder(
    column: $table.collectionEtag,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isComplete => $composableBuilder(
    column: $table.isComplete,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ScopeCompletenessRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ScopeCompletenessRowsTable> {
  $$ScopeCompletenessRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<String> get scopeKind =>
      $composableBuilder(column: $table.scopeKind, builder: (column) => column);

  GeneratedColumn<String> get scopeKey =>
      $composableBuilder(column: $table.scopeKey, builder: (column) => column);

  GeneratedColumn<int> get taskListId => $composableBuilder(
    column: $table.taskListId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get publicationId => $composableBuilder(
    column: $table.publicationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get nextPageToken => $composableBuilder(
    column: $table.nextPageToken,
    builder: (column) => column,
  );

  GeneratedColumn<String> get collectionEtag => $composableBuilder(
    column: $table.collectionEtag,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isComplete => $composableBuilder(
    column: $table.isComplete,
    builder: (column) => column,
  );
}

class $$ScopeCompletenessRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ScopeCompletenessRowsTable,
          ScopeCompletenessRow,
          $$ScopeCompletenessRowsTableFilterComposer,
          $$ScopeCompletenessRowsTableOrderingComposer,
          $$ScopeCompletenessRowsTableAnnotationComposer,
          $$ScopeCompletenessRowsTableCreateCompanionBuilder,
          $$ScopeCompletenessRowsTableUpdateCompanionBuilder,
          (
            ScopeCompletenessRow,
            BaseReferences<
              _$AppDatabase,
              $ScopeCompletenessRowsTable,
              ScopeCompletenessRow
            >,
          ),
          ScopeCompletenessRow,
          PrefetchHooks Function()
        > {
  $$ScopeCompletenessRowsTableTableManager(
    _$AppDatabase db,
    $ScopeCompletenessRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ScopeCompletenessRowsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$ScopeCompletenessRowsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$ScopeCompletenessRowsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> accountId = const Value.absent(),
                Value<String> scopeKind = const Value.absent(),
                Value<String> scopeKey = const Value.absent(),
                Value<int?> taskListId = const Value.absent(),
                Value<String> publicationId = const Value.absent(),
                Value<String?> nextPageToken = const Value.absent(),
                Value<String?> collectionEtag = const Value.absent(),
                Value<bool> isComplete = const Value.absent(),
              }) => ScopeCompletenessRowsCompanion(
                id: id,
                accountId: accountId,
                scopeKind: scopeKind,
                scopeKey: scopeKey,
                taskListId: taskListId,
                publicationId: publicationId,
                nextPageToken: nextPageToken,
                collectionEtag: collectionEtag,
                isComplete: isComplete,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int accountId,
                required String scopeKind,
                required String scopeKey,
                Value<int?> taskListId = const Value.absent(),
                required String publicationId,
                Value<String?> nextPageToken = const Value.absent(),
                Value<String?> collectionEtag = const Value.absent(),
                Value<bool> isComplete = const Value.absent(),
              }) => ScopeCompletenessRowsCompanion.insert(
                id: id,
                accountId: accountId,
                scopeKind: scopeKind,
                scopeKey: scopeKey,
                taskListId: taskListId,
                publicationId: publicationId,
                nextPageToken: nextPageToken,
                collectionEtag: collectionEtag,
                isComplete: isComplete,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ScopeCompletenessRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ScopeCompletenessRowsTable,
      ScopeCompletenessRow,
      $$ScopeCompletenessRowsTableFilterComposer,
      $$ScopeCompletenessRowsTableOrderingComposer,
      $$ScopeCompletenessRowsTableAnnotationComposer,
      $$ScopeCompletenessRowsTableCreateCompanionBuilder,
      $$ScopeCompletenessRowsTableUpdateCompanionBuilder,
      (
        ScopeCompletenessRow,
        BaseReferences<
          _$AppDatabase,
          $ScopeCompletenessRowsTable,
          ScopeCompletenessRow
        >,
      ),
      ScopeCompletenessRow,
      PrefetchHooks Function()
    >;
typedef $$AccountPreferenceRowsTableCreateCompanionBuilder =
    AccountPreferenceRowsCompanion Function({
      Value<int> accountId,
      Value<bool> syncEnabled,
      Value<int?> defaultTaskListId,
    });
typedef $$AccountPreferenceRowsTableUpdateCompanionBuilder =
    AccountPreferenceRowsCompanion Function({
      Value<int> accountId,
      Value<bool> syncEnabled,
      Value<int?> defaultTaskListId,
    });

class $$AccountPreferenceRowsTableFilterComposer
    extends Composer<_$AppDatabase, $AccountPreferenceRowsTable> {
  $$AccountPreferenceRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get syncEnabled => $composableBuilder(
    column: $table.syncEnabled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get defaultTaskListId => $composableBuilder(
    column: $table.defaultTaskListId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AccountPreferenceRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $AccountPreferenceRowsTable> {
  $$AccountPreferenceRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get syncEnabled => $composableBuilder(
    column: $table.syncEnabled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get defaultTaskListId => $composableBuilder(
    column: $table.defaultTaskListId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AccountPreferenceRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AccountPreferenceRowsTable> {
  $$AccountPreferenceRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<bool> get syncEnabled => $composableBuilder(
    column: $table.syncEnabled,
    builder: (column) => column,
  );

  GeneratedColumn<int> get defaultTaskListId => $composableBuilder(
    column: $table.defaultTaskListId,
    builder: (column) => column,
  );
}

class $$AccountPreferenceRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AccountPreferenceRowsTable,
          AccountPreferenceRow,
          $$AccountPreferenceRowsTableFilterComposer,
          $$AccountPreferenceRowsTableOrderingComposer,
          $$AccountPreferenceRowsTableAnnotationComposer,
          $$AccountPreferenceRowsTableCreateCompanionBuilder,
          $$AccountPreferenceRowsTableUpdateCompanionBuilder,
          (
            AccountPreferenceRow,
            BaseReferences<
              _$AppDatabase,
              $AccountPreferenceRowsTable,
              AccountPreferenceRow
            >,
          ),
          AccountPreferenceRow,
          PrefetchHooks Function()
        > {
  $$AccountPreferenceRowsTableTableManager(
    _$AppDatabase db,
    $AccountPreferenceRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AccountPreferenceRowsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$AccountPreferenceRowsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$AccountPreferenceRowsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> accountId = const Value.absent(),
                Value<bool> syncEnabled = const Value.absent(),
                Value<int?> defaultTaskListId = const Value.absent(),
              }) => AccountPreferenceRowsCompanion(
                accountId: accountId,
                syncEnabled: syncEnabled,
                defaultTaskListId: defaultTaskListId,
              ),
          createCompanionCallback:
              ({
                Value<int> accountId = const Value.absent(),
                Value<bool> syncEnabled = const Value.absent(),
                Value<int?> defaultTaskListId = const Value.absent(),
              }) => AccountPreferenceRowsCompanion.insert(
                accountId: accountId,
                syncEnabled: syncEnabled,
                defaultTaskListId: defaultTaskListId,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AccountPreferenceRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AccountPreferenceRowsTable,
      AccountPreferenceRow,
      $$AccountPreferenceRowsTableFilterComposer,
      $$AccountPreferenceRowsTableOrderingComposer,
      $$AccountPreferenceRowsTableAnnotationComposer,
      $$AccountPreferenceRowsTableCreateCompanionBuilder,
      $$AccountPreferenceRowsTableUpdateCompanionBuilder,
      (
        AccountPreferenceRow,
        BaseReferences<
          _$AppDatabase,
          $AccountPreferenceRowsTable,
          AccountPreferenceRow
        >,
      ),
      AccountPreferenceRow,
      PrefetchHooks Function()
    >;
typedef $$TaskListPreferenceRowsTableCreateCompanionBuilder =
    TaskListPreferenceRowsCompanion Function({
      required int accountId,
      required int taskListId,
      Value<int?> sidebarOrder,
      Value<bool> excludedFromSmartViews,
      Value<int> rowid,
    });
typedef $$TaskListPreferenceRowsTableUpdateCompanionBuilder =
    TaskListPreferenceRowsCompanion Function({
      Value<int> accountId,
      Value<int> taskListId,
      Value<int?> sidebarOrder,
      Value<bool> excludedFromSmartViews,
      Value<int> rowid,
    });

class $$TaskListPreferenceRowsTableFilterComposer
    extends Composer<_$AppDatabase, $TaskListPreferenceRowsTable> {
  $$TaskListPreferenceRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get taskListId => $composableBuilder(
    column: $table.taskListId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sidebarOrder => $composableBuilder(
    column: $table.sidebarOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get excludedFromSmartViews => $composableBuilder(
    column: $table.excludedFromSmartViews,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TaskListPreferenceRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $TaskListPreferenceRowsTable> {
  $$TaskListPreferenceRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get taskListId => $composableBuilder(
    column: $table.taskListId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sidebarOrder => $composableBuilder(
    column: $table.sidebarOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get excludedFromSmartViews => $composableBuilder(
    column: $table.excludedFromSmartViews,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TaskListPreferenceRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $TaskListPreferenceRowsTable> {
  $$TaskListPreferenceRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<int> get taskListId => $composableBuilder(
    column: $table.taskListId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sidebarOrder => $composableBuilder(
    column: $table.sidebarOrder,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get excludedFromSmartViews => $composableBuilder(
    column: $table.excludedFromSmartViews,
    builder: (column) => column,
  );
}

class $$TaskListPreferenceRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TaskListPreferenceRowsTable,
          TaskListPreferenceRow,
          $$TaskListPreferenceRowsTableFilterComposer,
          $$TaskListPreferenceRowsTableOrderingComposer,
          $$TaskListPreferenceRowsTableAnnotationComposer,
          $$TaskListPreferenceRowsTableCreateCompanionBuilder,
          $$TaskListPreferenceRowsTableUpdateCompanionBuilder,
          (
            TaskListPreferenceRow,
            BaseReferences<
              _$AppDatabase,
              $TaskListPreferenceRowsTable,
              TaskListPreferenceRow
            >,
          ),
          TaskListPreferenceRow,
          PrefetchHooks Function()
        > {
  $$TaskListPreferenceRowsTableTableManager(
    _$AppDatabase db,
    $TaskListPreferenceRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TaskListPreferenceRowsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$TaskListPreferenceRowsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$TaskListPreferenceRowsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> accountId = const Value.absent(),
                Value<int> taskListId = const Value.absent(),
                Value<int?> sidebarOrder = const Value.absent(),
                Value<bool> excludedFromSmartViews = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TaskListPreferenceRowsCompanion(
                accountId: accountId,
                taskListId: taskListId,
                sidebarOrder: sidebarOrder,
                excludedFromSmartViews: excludedFromSmartViews,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int accountId,
                required int taskListId,
                Value<int?> sidebarOrder = const Value.absent(),
                Value<bool> excludedFromSmartViews = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TaskListPreferenceRowsCompanion.insert(
                accountId: accountId,
                taskListId: taskListId,
                sidebarOrder: sidebarOrder,
                excludedFromSmartViews: excludedFromSmartViews,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TaskListPreferenceRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TaskListPreferenceRowsTable,
      TaskListPreferenceRow,
      $$TaskListPreferenceRowsTableFilterComposer,
      $$TaskListPreferenceRowsTableOrderingComposer,
      $$TaskListPreferenceRowsTableAnnotationComposer,
      $$TaskListPreferenceRowsTableCreateCompanionBuilder,
      $$TaskListPreferenceRowsTableUpdateCompanionBuilder,
      (
        TaskListPreferenceRow,
        BaseReferences<
          _$AppDatabase,
          $TaskListPreferenceRowsTable,
          TaskListPreferenceRow
        >,
      ),
      TaskListPreferenceRow,
      PrefetchHooks Function()
    >;
typedef $$ViewPreferenceRowsTableCreateCompanionBuilder =
    ViewPreferenceRowsCompanion Function({
      required int accountId,
      required String viewKey,
      required String sortMode,
      Value<bool> showCompleted,
      Value<int> rowid,
    });
typedef $$ViewPreferenceRowsTableUpdateCompanionBuilder =
    ViewPreferenceRowsCompanion Function({
      Value<int> accountId,
      Value<String> viewKey,
      Value<String> sortMode,
      Value<bool> showCompleted,
      Value<int> rowid,
    });

class $$ViewPreferenceRowsTableFilterComposer
    extends Composer<_$AppDatabase, $ViewPreferenceRowsTable> {
  $$ViewPreferenceRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get viewKey => $composableBuilder(
    column: $table.viewKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sortMode => $composableBuilder(
    column: $table.sortMode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get showCompleted => $composableBuilder(
    column: $table.showCompleted,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ViewPreferenceRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $ViewPreferenceRowsTable> {
  $$ViewPreferenceRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get viewKey => $composableBuilder(
    column: $table.viewKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sortMode => $composableBuilder(
    column: $table.sortMode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get showCompleted => $composableBuilder(
    column: $table.showCompleted,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ViewPreferenceRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ViewPreferenceRowsTable> {
  $$ViewPreferenceRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<String> get viewKey =>
      $composableBuilder(column: $table.viewKey, builder: (column) => column);

  GeneratedColumn<String> get sortMode =>
      $composableBuilder(column: $table.sortMode, builder: (column) => column);

  GeneratedColumn<bool> get showCompleted => $composableBuilder(
    column: $table.showCompleted,
    builder: (column) => column,
  );
}

class $$ViewPreferenceRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ViewPreferenceRowsTable,
          ViewPreferenceRow,
          $$ViewPreferenceRowsTableFilterComposer,
          $$ViewPreferenceRowsTableOrderingComposer,
          $$ViewPreferenceRowsTableAnnotationComposer,
          $$ViewPreferenceRowsTableCreateCompanionBuilder,
          $$ViewPreferenceRowsTableUpdateCompanionBuilder,
          (
            ViewPreferenceRow,
            BaseReferences<
              _$AppDatabase,
              $ViewPreferenceRowsTable,
              ViewPreferenceRow
            >,
          ),
          ViewPreferenceRow,
          PrefetchHooks Function()
        > {
  $$ViewPreferenceRowsTableTableManager(
    _$AppDatabase db,
    $ViewPreferenceRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ViewPreferenceRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ViewPreferenceRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ViewPreferenceRowsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> accountId = const Value.absent(),
                Value<String> viewKey = const Value.absent(),
                Value<String> sortMode = const Value.absent(),
                Value<bool> showCompleted = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ViewPreferenceRowsCompanion(
                accountId: accountId,
                viewKey: viewKey,
                sortMode: sortMode,
                showCompleted: showCompleted,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int accountId,
                required String viewKey,
                required String sortMode,
                Value<bool> showCompleted = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ViewPreferenceRowsCompanion.insert(
                accountId: accountId,
                viewKey: viewKey,
                sortMode: sortMode,
                showCompleted: showCompleted,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ViewPreferenceRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ViewPreferenceRowsTable,
      ViewPreferenceRow,
      $$ViewPreferenceRowsTableFilterComposer,
      $$ViewPreferenceRowsTableOrderingComposer,
      $$ViewPreferenceRowsTableAnnotationComposer,
      $$ViewPreferenceRowsTableCreateCompanionBuilder,
      $$ViewPreferenceRowsTableUpdateCompanionBuilder,
      (
        ViewPreferenceRow,
        BaseReferences<
          _$AppDatabase,
          $ViewPreferenceRowsTable,
          ViewPreferenceRow
        >,
      ),
      ViewPreferenceRow,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$AccountsTableTableManager get accounts =>
      $$AccountsTableTableManager(_db, _db.accounts);
  $$TaskListCacheRowsTableTableManager get taskListCacheRows =>
      $$TaskListCacheRowsTableTableManager(_db, _db.taskListCacheRows);
  $$TaskCacheRowsTableTableManager get taskCacheRows =>
      $$TaskCacheRowsTableTableManager(_db, _db.taskCacheRows);
  $$TaskListRemoteBasesTableTableManager get taskListRemoteBases =>
      $$TaskListRemoteBasesTableTableManager(_db, _db.taskListRemoteBases);
  $$TaskRemoteBasesTableTableManager get taskRemoteBases =>
      $$TaskRemoteBasesTableTableManager(_db, _db.taskRemoteBases);
  $$ScopeCompletenessRowsTableTableManager get scopeCompletenessRows =>
      $$ScopeCompletenessRowsTableTableManager(_db, _db.scopeCompletenessRows);
  $$AccountPreferenceRowsTableTableManager get accountPreferenceRows =>
      $$AccountPreferenceRowsTableTableManager(_db, _db.accountPreferenceRows);
  $$TaskListPreferenceRowsTableTableManager get taskListPreferenceRows =>
      $$TaskListPreferenceRowsTableTableManager(
        _db,
        _db.taskListPreferenceRows,
      );
  $$ViewPreferenceRowsTableTableManager get viewPreferenceRows =>
      $$ViewPreferenceRowsTableTableManager(_db, _db.viewPreferenceRows);
}
