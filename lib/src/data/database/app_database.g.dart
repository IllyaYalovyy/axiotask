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
  static const VerificationMeta _nextLocalCausalSequenceMeta =
      const VerificationMeta('nextLocalCausalSequence');
  @override
  late final GeneratedColumn<int> nextLocalCausalSequence =
      GeneratedColumn<int>(
        'next_local_causal_sequence',
        aliasedName,
        false,
        check: () =>
            ComparableExpr(nextLocalCausalSequence).isBiggerThanValue(0),
        type: DriftSqlType.int,
        requiredDuringInsert: false,
        defaultValue: const Constant(1),
      );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    syncEnabled,
    defaultTaskListId,
    nextLocalCausalSequence,
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
    if (data.containsKey('next_local_causal_sequence')) {
      context.handle(
        _nextLocalCausalSequenceMeta,
        nextLocalCausalSequence.isAcceptableOrUnknown(
          data['next_local_causal_sequence']!,
          _nextLocalCausalSequenceMeta,
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
      nextLocalCausalSequence: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}next_local_causal_sequence'],
      )!,
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
  final int nextLocalCausalSequence;
  const AccountPreferenceRow({
    required this.accountId,
    required this.syncEnabled,
    this.defaultTaskListId,
    required this.nextLocalCausalSequence,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<int>(accountId);
    map['sync_enabled'] = Variable<bool>(syncEnabled);
    if (!nullToAbsent || defaultTaskListId != null) {
      map['default_task_list_id'] = Variable<int>(defaultTaskListId);
    }
    map['next_local_causal_sequence'] = Variable<int>(nextLocalCausalSequence);
    return map;
  }

  AccountPreferenceRowsCompanion toCompanion(bool nullToAbsent) {
    return AccountPreferenceRowsCompanion(
      accountId: Value(accountId),
      syncEnabled: Value(syncEnabled),
      defaultTaskListId: defaultTaskListId == null && nullToAbsent
          ? const Value.absent()
          : Value(defaultTaskListId),
      nextLocalCausalSequence: Value(nextLocalCausalSequence),
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
      nextLocalCausalSequence: serializer.fromJson<int>(
        json['nextLocalCausalSequence'],
      ),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<int>(accountId),
      'syncEnabled': serializer.toJson<bool>(syncEnabled),
      'defaultTaskListId': serializer.toJson<int?>(defaultTaskListId),
      'nextLocalCausalSequence': serializer.toJson<int>(
        nextLocalCausalSequence,
      ),
    };
  }

  AccountPreferenceRow copyWith({
    int? accountId,
    bool? syncEnabled,
    Value<int?> defaultTaskListId = const Value.absent(),
    int? nextLocalCausalSequence,
  }) => AccountPreferenceRow(
    accountId: accountId ?? this.accountId,
    syncEnabled: syncEnabled ?? this.syncEnabled,
    defaultTaskListId: defaultTaskListId.present
        ? defaultTaskListId.value
        : this.defaultTaskListId,
    nextLocalCausalSequence:
        nextLocalCausalSequence ?? this.nextLocalCausalSequence,
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
      nextLocalCausalSequence: data.nextLocalCausalSequence.present
          ? data.nextLocalCausalSequence.value
          : this.nextLocalCausalSequence,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AccountPreferenceRow(')
          ..write('accountId: $accountId, ')
          ..write('syncEnabled: $syncEnabled, ')
          ..write('defaultTaskListId: $defaultTaskListId, ')
          ..write('nextLocalCausalSequence: $nextLocalCausalSequence')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    accountId,
    syncEnabled,
    defaultTaskListId,
    nextLocalCausalSequence,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AccountPreferenceRow &&
          other.accountId == this.accountId &&
          other.syncEnabled == this.syncEnabled &&
          other.defaultTaskListId == this.defaultTaskListId &&
          other.nextLocalCausalSequence == this.nextLocalCausalSequence);
}

class AccountPreferenceRowsCompanion
    extends UpdateCompanion<AccountPreferenceRow> {
  final Value<int> accountId;
  final Value<bool> syncEnabled;
  final Value<int?> defaultTaskListId;
  final Value<int> nextLocalCausalSequence;
  const AccountPreferenceRowsCompanion({
    this.accountId = const Value.absent(),
    this.syncEnabled = const Value.absent(),
    this.defaultTaskListId = const Value.absent(),
    this.nextLocalCausalSequence = const Value.absent(),
  });
  AccountPreferenceRowsCompanion.insert({
    this.accountId = const Value.absent(),
    this.syncEnabled = const Value.absent(),
    this.defaultTaskListId = const Value.absent(),
    this.nextLocalCausalSequence = const Value.absent(),
  });
  static Insertable<AccountPreferenceRow> custom({
    Expression<int>? accountId,
    Expression<bool>? syncEnabled,
    Expression<int>? defaultTaskListId,
    Expression<int>? nextLocalCausalSequence,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (syncEnabled != null) 'sync_enabled': syncEnabled,
      if (defaultTaskListId != null) 'default_task_list_id': defaultTaskListId,
      if (nextLocalCausalSequence != null)
        'next_local_causal_sequence': nextLocalCausalSequence,
    });
  }

  AccountPreferenceRowsCompanion copyWith({
    Value<int>? accountId,
    Value<bool>? syncEnabled,
    Value<int?>? defaultTaskListId,
    Value<int>? nextLocalCausalSequence,
  }) {
    return AccountPreferenceRowsCompanion(
      accountId: accountId ?? this.accountId,
      syncEnabled: syncEnabled ?? this.syncEnabled,
      defaultTaskListId: defaultTaskListId ?? this.defaultTaskListId,
      nextLocalCausalSequence:
          nextLocalCausalSequence ?? this.nextLocalCausalSequence,
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
    if (nextLocalCausalSequence.present) {
      map['next_local_causal_sequence'] = Variable<int>(
        nextLocalCausalSequence.value,
      );
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AccountPreferenceRowsCompanion(')
          ..write('accountId: $accountId, ')
          ..write('syncEnabled: $syncEnabled, ')
          ..write('defaultTaskListId: $defaultTaskListId, ')
          ..write('nextLocalCausalSequence: $nextLocalCausalSequence')
          ..write(')'))
        .toString();
  }
}

class $DesiredStateRowsTable extends DesiredStateRows
    with TableInfo<$DesiredStateRowsTable, DesiredStateRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DesiredStateRowsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _targetKeyMeta = const VerificationMeta(
    'targetKey',
  );
  @override
  late final GeneratedColumn<String> targetKey = GeneratedColumn<String>(
    'target_key',
    aliasedName,
    false,
    check: () => ComparableExpr(targetKey.length).isBiggerThanValue(0),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _resourceTypeMeta = const VerificationMeta(
    'resourceType',
  );
  @override
  late final GeneratedColumn<String> resourceType = GeneratedColumn<String>(
    'resource_type',
    aliasedName,
    false,
    check: () => resourceType.isIn(const <String>['task_list', 'task']),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _targetTaskListIdMeta = const VerificationMeta(
    'targetTaskListId',
  );
  @override
  late final GeneratedColumn<int> targetTaskListId = GeneratedColumn<int>(
    'target_task_list_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _targetTaskIdMeta = const VerificationMeta(
    'targetTaskId',
  );
  @override
  late final GeneratedColumn<int> targetTaskId = GeneratedColumn<int>(
    'target_task_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _desiredLifecycleMeta = const VerificationMeta(
    'desiredLifecycle',
  );
  @override
  late final GeneratedColumn<String> desiredLifecycle = GeneratedColumn<String>(
    'desired_lifecycle',
    aliasedName,
    false,
    check: () => desiredLifecycle.isIn(const <String>['present', 'deleted']),
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
  static const VerificationMeta _desiredTaskListIdMeta = const VerificationMeta(
    'desiredTaskListId',
  );
  @override
  late final GeneratedColumn<int> desiredTaskListId = GeneratedColumn<int>(
    'desired_task_list_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _desiredParentTaskIdMeta =
      const VerificationMeta('desiredParentTaskId');
  @override
  late final GeneratedColumn<int> desiredParentTaskId = GeneratedColumn<int>(
    'desired_parent_task_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _desiredPreviousTaskIdMeta =
      const VerificationMeta('desiredPreviousTaskId');
  @override
  late final GeneratedColumn<int> desiredPreviousTaskId = GeneratedColumn<int>(
    'desired_previous_task_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _contentDirtyMeta = const VerificationMeta(
    'contentDirty',
  );
  @override
  late final GeneratedColumn<bool> contentDirty = GeneratedColumn<bool>(
    'content_dirty',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("content_dirty" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _structureDirtyMeta = const VerificationMeta(
    'structureDirty',
  );
  @override
  late final GeneratedColumn<bool> structureDirty = GeneratedColumn<bool>(
    'structure_dirty',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("structure_dirty" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _lifecycleDirtyMeta = const VerificationMeta(
    'lifecycleDirty',
  );
  @override
  late final GeneratedColumn<bool> lifecycleDirty = GeneratedColumn<bool>(
    'lifecycle_dirty',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("lifecycle_dirty" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _localModifiedAtMeta = const VerificationMeta(
    'localModifiedAt',
  );
  @override
  late final GeneratedColumn<DateTime> localModifiedAt =
      GeneratedColumn<DateTime>(
        'local_modified_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _notBeforeMeta = const VerificationMeta(
    'notBefore',
  );
  @override
  late final GeneratedColumn<DateTime> notBefore = GeneratedColumn<DateTime>(
    'not_before',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _generationMeta = const VerificationMeta(
    'generation',
  );
  @override
  late final GeneratedColumn<int> generation = GeneratedColumn<int>(
    'generation',
    aliasedName,
    false,
    check: () => ComparableExpr(generation).isBiggerThanValue(0),
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _localCausalSequenceMeta =
      const VerificationMeta('localCausalSequence');
  @override
  late final GeneratedColumn<int> localCausalSequence = GeneratedColumn<int>(
    'local_causal_sequence',
    aliasedName,
    false,
    check: () => ComparableExpr(localCausalSequence).isBiggerThanValue(0),
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
    'state',
    aliasedName,
    false,
    check: () => state.isIn(const <String>[
      'pending',
      'in_flight',
      'uncertain',
      'failed',
      'confirmed',
      'superseded',
    ]),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _baseRemoteIdMeta = const VerificationMeta(
    'baseRemoteId',
  );
  @override
  late final GeneratedColumn<String> baseRemoteId = GeneratedColumn<String>(
    'base_remote_id',
    aliasedName,
    true,
    check: () =>
        baseRemoteId.isNull() |
        ComparableExpr(baseRemoteId.length).isBiggerThanValue(0),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _baseEtagMeta = const VerificationMeta(
    'baseEtag',
  );
  @override
  late final GeneratedColumn<String> baseEtag = GeneratedColumn<String>(
    'base_etag',
    aliasedName,
    true,
    check: () =>
        baseEtag.isNull() |
        ComparableExpr(baseEtag.length).isBiggerThanValue(0),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _baseRemoteUpdatedAtMeta =
      const VerificationMeta('baseRemoteUpdatedAt');
  @override
  late final GeneratedColumn<DateTime> baseRemoteUpdatedAt =
      GeneratedColumn<DateTime>(
        'base_remote_updated_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _baseObservedPublicationIdMeta =
      const VerificationMeta('baseObservedPublicationId');
  @override
  late final GeneratedColumn<String> baseObservedPublicationId =
      GeneratedColumn<String>(
        'base_observed_publication_id',
        aliasedName,
        true,
        check: () =>
            baseObservedPublicationId.isNull() |
            ComparableExpr(
              baseObservedPublicationId.length,
            ).isBiggerThanValue(0),
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _baseTitleMeta = const VerificationMeta(
    'baseTitle',
  );
  @override
  late final GeneratedColumn<String> baseTitle = GeneratedColumn<String>(
    'base_title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _baseNotesMeta = const VerificationMeta(
    'baseNotes',
  );
  @override
  late final GeneratedColumn<String> baseNotes = GeneratedColumn<String>(
    'base_notes',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _baseStatusMeta = const VerificationMeta(
    'baseStatus',
  );
  @override
  late final GeneratedColumn<String> baseStatus = GeneratedColumn<String>(
    'base_status',
    aliasedName,
    true,
    check: () =>
        baseStatus.isNull() |
        baseStatus.isIn(const <String>['needs_action', 'completed']),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _baseDueEpochDayMeta = const VerificationMeta(
    'baseDueEpochDay',
  );
  @override
  late final GeneratedColumn<int> baseDueEpochDay = GeneratedColumn<int>(
    'base_due_epoch_day',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _baseTaskListIdMeta = const VerificationMeta(
    'baseTaskListId',
  );
  @override
  late final GeneratedColumn<int> baseTaskListId = GeneratedColumn<int>(
    'base_task_list_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _baseParentTaskIdMeta = const VerificationMeta(
    'baseParentTaskId',
  );
  @override
  late final GeneratedColumn<int> baseParentTaskId = GeneratedColumn<int>(
    'base_parent_task_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _basePreviousTaskIdMeta =
      const VerificationMeta('basePreviousTaskId');
  @override
  late final GeneratedColumn<int> basePreviousTaskId = GeneratedColumn<int>(
    'base_previous_task_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _basePositionMeta = const VerificationMeta(
    'basePosition',
  );
  @override
  late final GeneratedColumn<String> basePosition = GeneratedColumn<String>(
    'base_position',
    aliasedName,
    true,
    check: () =>
        basePosition.isNull() |
        ComparableExpr(basePosition.length).isBiggerThanValue(0),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _baseSiblingOrderMeta = const VerificationMeta(
    'baseSiblingOrder',
  );
  @override
  late final GeneratedColumn<String> baseSiblingOrder = GeneratedColumn<String>(
    'base_sibling_order',
    aliasedName,
    true,
    check: () =>
        baseSiblingOrder.isNull() |
        ComparableExpr(baseSiblingOrder.length).isBiggerThanValue(0),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _failureCodeMeta = const VerificationMeta(
    'failureCode',
  );
  @override
  late final GeneratedColumn<String> failureCode = GeneratedColumn<String>(
    'failure_code',
    aliasedName,
    true,
    check: () =>
        failureCode.isNull() |
        ComparableExpr(failureCode.length).isBiggerThanValue(0),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastTransitionAtMeta = const VerificationMeta(
    'lastTransitionAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastTransitionAt =
      GeneratedColumn<DateTime>(
        'last_transition_at',
        aliasedName,
        false,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: true,
      );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    targetKey,
    resourceType,
    targetTaskListId,
    targetTaskId,
    desiredLifecycle,
    title,
    notes,
    status,
    dueEpochDay,
    desiredTaskListId,
    desiredParentTaskId,
    desiredPreviousTaskId,
    contentDirty,
    structureDirty,
    lifecycleDirty,
    localModifiedAt,
    notBefore,
    generation,
    localCausalSequence,
    state,
    baseRemoteId,
    baseEtag,
    baseRemoteUpdatedAt,
    baseObservedPublicationId,
    baseTitle,
    baseNotes,
    baseStatus,
    baseDueEpochDay,
    baseTaskListId,
    baseParentTaskId,
    basePreviousTaskId,
    basePosition,
    baseSiblingOrder,
    failureCode,
    createdAt,
    lastTransitionAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'desired_states';
  @override
  VerificationContext validateIntegrity(
    Insertable<DesiredStateRow> instance, {
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
    if (data.containsKey('target_key')) {
      context.handle(
        _targetKeyMeta,
        targetKey.isAcceptableOrUnknown(data['target_key']!, _targetKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_targetKeyMeta);
    }
    if (data.containsKey('resource_type')) {
      context.handle(
        _resourceTypeMeta,
        resourceType.isAcceptableOrUnknown(
          data['resource_type']!,
          _resourceTypeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_resourceTypeMeta);
    }
    if (data.containsKey('target_task_list_id')) {
      context.handle(
        _targetTaskListIdMeta,
        targetTaskListId.isAcceptableOrUnknown(
          data['target_task_list_id']!,
          _targetTaskListIdMeta,
        ),
      );
    }
    if (data.containsKey('target_task_id')) {
      context.handle(
        _targetTaskIdMeta,
        targetTaskId.isAcceptableOrUnknown(
          data['target_task_id']!,
          _targetTaskIdMeta,
        ),
      );
    }
    if (data.containsKey('desired_lifecycle')) {
      context.handle(
        _desiredLifecycleMeta,
        desiredLifecycle.isAcceptableOrUnknown(
          data['desired_lifecycle']!,
          _desiredLifecycleMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_desiredLifecycleMeta);
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
    if (data.containsKey('desired_task_list_id')) {
      context.handle(
        _desiredTaskListIdMeta,
        desiredTaskListId.isAcceptableOrUnknown(
          data['desired_task_list_id']!,
          _desiredTaskListIdMeta,
        ),
      );
    }
    if (data.containsKey('desired_parent_task_id')) {
      context.handle(
        _desiredParentTaskIdMeta,
        desiredParentTaskId.isAcceptableOrUnknown(
          data['desired_parent_task_id']!,
          _desiredParentTaskIdMeta,
        ),
      );
    }
    if (data.containsKey('desired_previous_task_id')) {
      context.handle(
        _desiredPreviousTaskIdMeta,
        desiredPreviousTaskId.isAcceptableOrUnknown(
          data['desired_previous_task_id']!,
          _desiredPreviousTaskIdMeta,
        ),
      );
    }
    if (data.containsKey('content_dirty')) {
      context.handle(
        _contentDirtyMeta,
        contentDirty.isAcceptableOrUnknown(
          data['content_dirty']!,
          _contentDirtyMeta,
        ),
      );
    }
    if (data.containsKey('structure_dirty')) {
      context.handle(
        _structureDirtyMeta,
        structureDirty.isAcceptableOrUnknown(
          data['structure_dirty']!,
          _structureDirtyMeta,
        ),
      );
    }
    if (data.containsKey('lifecycle_dirty')) {
      context.handle(
        _lifecycleDirtyMeta,
        lifecycleDirty.isAcceptableOrUnknown(
          data['lifecycle_dirty']!,
          _lifecycleDirtyMeta,
        ),
      );
    }
    if (data.containsKey('local_modified_at')) {
      context.handle(
        _localModifiedAtMeta,
        localModifiedAt.isAcceptableOrUnknown(
          data['local_modified_at']!,
          _localModifiedAtMeta,
        ),
      );
    }
    if (data.containsKey('not_before')) {
      context.handle(
        _notBeforeMeta,
        notBefore.isAcceptableOrUnknown(data['not_before']!, _notBeforeMeta),
      );
    }
    if (data.containsKey('generation')) {
      context.handle(
        _generationMeta,
        generation.isAcceptableOrUnknown(data['generation']!, _generationMeta),
      );
    } else if (isInserting) {
      context.missing(_generationMeta);
    }
    if (data.containsKey('local_causal_sequence')) {
      context.handle(
        _localCausalSequenceMeta,
        localCausalSequence.isAcceptableOrUnknown(
          data['local_causal_sequence']!,
          _localCausalSequenceMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_localCausalSequenceMeta);
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    } else if (isInserting) {
      context.missing(_stateMeta);
    }
    if (data.containsKey('base_remote_id')) {
      context.handle(
        _baseRemoteIdMeta,
        baseRemoteId.isAcceptableOrUnknown(
          data['base_remote_id']!,
          _baseRemoteIdMeta,
        ),
      );
    }
    if (data.containsKey('base_etag')) {
      context.handle(
        _baseEtagMeta,
        baseEtag.isAcceptableOrUnknown(data['base_etag']!, _baseEtagMeta),
      );
    }
    if (data.containsKey('base_remote_updated_at')) {
      context.handle(
        _baseRemoteUpdatedAtMeta,
        baseRemoteUpdatedAt.isAcceptableOrUnknown(
          data['base_remote_updated_at']!,
          _baseRemoteUpdatedAtMeta,
        ),
      );
    }
    if (data.containsKey('base_observed_publication_id')) {
      context.handle(
        _baseObservedPublicationIdMeta,
        baseObservedPublicationId.isAcceptableOrUnknown(
          data['base_observed_publication_id']!,
          _baseObservedPublicationIdMeta,
        ),
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
    if (data.containsKey('base_status')) {
      context.handle(
        _baseStatusMeta,
        baseStatus.isAcceptableOrUnknown(data['base_status']!, _baseStatusMeta),
      );
    }
    if (data.containsKey('base_due_epoch_day')) {
      context.handle(
        _baseDueEpochDayMeta,
        baseDueEpochDay.isAcceptableOrUnknown(
          data['base_due_epoch_day']!,
          _baseDueEpochDayMeta,
        ),
      );
    }
    if (data.containsKey('base_task_list_id')) {
      context.handle(
        _baseTaskListIdMeta,
        baseTaskListId.isAcceptableOrUnknown(
          data['base_task_list_id']!,
          _baseTaskListIdMeta,
        ),
      );
    }
    if (data.containsKey('base_parent_task_id')) {
      context.handle(
        _baseParentTaskIdMeta,
        baseParentTaskId.isAcceptableOrUnknown(
          data['base_parent_task_id']!,
          _baseParentTaskIdMeta,
        ),
      );
    }
    if (data.containsKey('base_previous_task_id')) {
      context.handle(
        _basePreviousTaskIdMeta,
        basePreviousTaskId.isAcceptableOrUnknown(
          data['base_previous_task_id']!,
          _basePreviousTaskIdMeta,
        ),
      );
    }
    if (data.containsKey('base_position')) {
      context.handle(
        _basePositionMeta,
        basePosition.isAcceptableOrUnknown(
          data['base_position']!,
          _basePositionMeta,
        ),
      );
    }
    if (data.containsKey('base_sibling_order')) {
      context.handle(
        _baseSiblingOrderMeta,
        baseSiblingOrder.isAcceptableOrUnknown(
          data['base_sibling_order']!,
          _baseSiblingOrderMeta,
        ),
      );
    }
    if (data.containsKey('failure_code')) {
      context.handle(
        _failureCodeMeta,
        failureCode.isAcceptableOrUnknown(
          data['failure_code']!,
          _failureCodeMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('last_transition_at')) {
      context.handle(
        _lastTransitionAtMeta,
        lastTransitionAt.isAcceptableOrUnknown(
          data['last_transition_at']!,
          _lastTransitionAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_lastTransitionAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, id},
    {accountId, targetKey},
  ];
  @override
  DesiredStateRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DesiredStateRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      targetKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}target_key'],
      )!,
      resourceType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}resource_type'],
      )!,
      targetTaskListId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}target_task_list_id'],
      ),
      targetTaskId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}target_task_id'],
      ),
      desiredLifecycle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}desired_lifecycle'],
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
      desiredTaskListId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}desired_task_list_id'],
      ),
      desiredParentTaskId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}desired_parent_task_id'],
      ),
      desiredPreviousTaskId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}desired_previous_task_id'],
      ),
      contentDirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}content_dirty'],
      )!,
      structureDirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}structure_dirty'],
      )!,
      lifecycleDirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}lifecycle_dirty'],
      )!,
      localModifiedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}local_modified_at'],
      ),
      notBefore: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}not_before'],
      ),
      generation: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}generation'],
      )!,
      localCausalSequence: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}local_causal_sequence'],
      )!,
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state'],
      )!,
      baseRemoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_remote_id'],
      ),
      baseEtag: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_etag'],
      ),
      baseRemoteUpdatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}base_remote_updated_at'],
      ),
      baseObservedPublicationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_observed_publication_id'],
      ),
      baseTitle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_title'],
      ),
      baseNotes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_notes'],
      ),
      baseStatus: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_status'],
      ),
      baseDueEpochDay: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}base_due_epoch_day'],
      ),
      baseTaskListId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}base_task_list_id'],
      ),
      baseParentTaskId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}base_parent_task_id'],
      ),
      basePreviousTaskId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}base_previous_task_id'],
      ),
      basePosition: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_position'],
      ),
      baseSiblingOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_sibling_order'],
      ),
      failureCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}failure_code'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      lastTransitionAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_transition_at'],
      )!,
    );
  }

  @override
  $DesiredStateRowsTable createAlias(String alias) {
    return $DesiredStateRowsTable(attachedDatabase, alias);
  }
}

class DesiredStateRow extends DataClass implements Insertable<DesiredStateRow> {
  final int id;
  final int accountId;
  final String targetKey;
  final String resourceType;
  final int? targetTaskListId;
  final int? targetTaskId;
  final String desiredLifecycle;
  final String? title;
  final String? notes;
  final String? status;
  final int? dueEpochDay;
  final int? desiredTaskListId;
  final int? desiredParentTaskId;
  final int? desiredPreviousTaskId;
  final bool contentDirty;
  final bool structureDirty;
  final bool lifecycleDirty;
  final DateTime? localModifiedAt;
  final DateTime? notBefore;
  final int generation;
  final int localCausalSequence;
  final String state;
  final String? baseRemoteId;
  final String? baseEtag;
  final DateTime? baseRemoteUpdatedAt;
  final String? baseObservedPublicationId;
  final String? baseTitle;
  final String? baseNotes;
  final String? baseStatus;
  final int? baseDueEpochDay;
  final int? baseTaskListId;
  final int? baseParentTaskId;
  final int? basePreviousTaskId;
  final String? basePosition;
  final String? baseSiblingOrder;
  final String? failureCode;
  final DateTime createdAt;
  final DateTime lastTransitionAt;
  const DesiredStateRow({
    required this.id,
    required this.accountId,
    required this.targetKey,
    required this.resourceType,
    this.targetTaskListId,
    this.targetTaskId,
    required this.desiredLifecycle,
    this.title,
    this.notes,
    this.status,
    this.dueEpochDay,
    this.desiredTaskListId,
    this.desiredParentTaskId,
    this.desiredPreviousTaskId,
    required this.contentDirty,
    required this.structureDirty,
    required this.lifecycleDirty,
    this.localModifiedAt,
    this.notBefore,
    required this.generation,
    required this.localCausalSequence,
    required this.state,
    this.baseRemoteId,
    this.baseEtag,
    this.baseRemoteUpdatedAt,
    this.baseObservedPublicationId,
    this.baseTitle,
    this.baseNotes,
    this.baseStatus,
    this.baseDueEpochDay,
    this.baseTaskListId,
    this.baseParentTaskId,
    this.basePreviousTaskId,
    this.basePosition,
    this.baseSiblingOrder,
    this.failureCode,
    required this.createdAt,
    required this.lastTransitionAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['account_id'] = Variable<int>(accountId);
    map['target_key'] = Variable<String>(targetKey);
    map['resource_type'] = Variable<String>(resourceType);
    if (!nullToAbsent || targetTaskListId != null) {
      map['target_task_list_id'] = Variable<int>(targetTaskListId);
    }
    if (!nullToAbsent || targetTaskId != null) {
      map['target_task_id'] = Variable<int>(targetTaskId);
    }
    map['desired_lifecycle'] = Variable<String>(desiredLifecycle);
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
    if (!nullToAbsent || desiredTaskListId != null) {
      map['desired_task_list_id'] = Variable<int>(desiredTaskListId);
    }
    if (!nullToAbsent || desiredParentTaskId != null) {
      map['desired_parent_task_id'] = Variable<int>(desiredParentTaskId);
    }
    if (!nullToAbsent || desiredPreviousTaskId != null) {
      map['desired_previous_task_id'] = Variable<int>(desiredPreviousTaskId);
    }
    map['content_dirty'] = Variable<bool>(contentDirty);
    map['structure_dirty'] = Variable<bool>(structureDirty);
    map['lifecycle_dirty'] = Variable<bool>(lifecycleDirty);
    if (!nullToAbsent || localModifiedAt != null) {
      map['local_modified_at'] = Variable<DateTime>(localModifiedAt);
    }
    if (!nullToAbsent || notBefore != null) {
      map['not_before'] = Variable<DateTime>(notBefore);
    }
    map['generation'] = Variable<int>(generation);
    map['local_causal_sequence'] = Variable<int>(localCausalSequence);
    map['state'] = Variable<String>(state);
    if (!nullToAbsent || baseRemoteId != null) {
      map['base_remote_id'] = Variable<String>(baseRemoteId);
    }
    if (!nullToAbsent || baseEtag != null) {
      map['base_etag'] = Variable<String>(baseEtag);
    }
    if (!nullToAbsent || baseRemoteUpdatedAt != null) {
      map['base_remote_updated_at'] = Variable<DateTime>(baseRemoteUpdatedAt);
    }
    if (!nullToAbsent || baseObservedPublicationId != null) {
      map['base_observed_publication_id'] = Variable<String>(
        baseObservedPublicationId,
      );
    }
    if (!nullToAbsent || baseTitle != null) {
      map['base_title'] = Variable<String>(baseTitle);
    }
    if (!nullToAbsent || baseNotes != null) {
      map['base_notes'] = Variable<String>(baseNotes);
    }
    if (!nullToAbsent || baseStatus != null) {
      map['base_status'] = Variable<String>(baseStatus);
    }
    if (!nullToAbsent || baseDueEpochDay != null) {
      map['base_due_epoch_day'] = Variable<int>(baseDueEpochDay);
    }
    if (!nullToAbsent || baseTaskListId != null) {
      map['base_task_list_id'] = Variable<int>(baseTaskListId);
    }
    if (!nullToAbsent || baseParentTaskId != null) {
      map['base_parent_task_id'] = Variable<int>(baseParentTaskId);
    }
    if (!nullToAbsent || basePreviousTaskId != null) {
      map['base_previous_task_id'] = Variable<int>(basePreviousTaskId);
    }
    if (!nullToAbsent || basePosition != null) {
      map['base_position'] = Variable<String>(basePosition);
    }
    if (!nullToAbsent || baseSiblingOrder != null) {
      map['base_sibling_order'] = Variable<String>(baseSiblingOrder);
    }
    if (!nullToAbsent || failureCode != null) {
      map['failure_code'] = Variable<String>(failureCode);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['last_transition_at'] = Variable<DateTime>(lastTransitionAt);
    return map;
  }

  DesiredStateRowsCompanion toCompanion(bool nullToAbsent) {
    return DesiredStateRowsCompanion(
      id: Value(id),
      accountId: Value(accountId),
      targetKey: Value(targetKey),
      resourceType: Value(resourceType),
      targetTaskListId: targetTaskListId == null && nullToAbsent
          ? const Value.absent()
          : Value(targetTaskListId),
      targetTaskId: targetTaskId == null && nullToAbsent
          ? const Value.absent()
          : Value(targetTaskId),
      desiredLifecycle: Value(desiredLifecycle),
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
      desiredTaskListId: desiredTaskListId == null && nullToAbsent
          ? const Value.absent()
          : Value(desiredTaskListId),
      desiredParentTaskId: desiredParentTaskId == null && nullToAbsent
          ? const Value.absent()
          : Value(desiredParentTaskId),
      desiredPreviousTaskId: desiredPreviousTaskId == null && nullToAbsent
          ? const Value.absent()
          : Value(desiredPreviousTaskId),
      contentDirty: Value(contentDirty),
      structureDirty: Value(structureDirty),
      lifecycleDirty: Value(lifecycleDirty),
      localModifiedAt: localModifiedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(localModifiedAt),
      notBefore: notBefore == null && nullToAbsent
          ? const Value.absent()
          : Value(notBefore),
      generation: Value(generation),
      localCausalSequence: Value(localCausalSequence),
      state: Value(state),
      baseRemoteId: baseRemoteId == null && nullToAbsent
          ? const Value.absent()
          : Value(baseRemoteId),
      baseEtag: baseEtag == null && nullToAbsent
          ? const Value.absent()
          : Value(baseEtag),
      baseRemoteUpdatedAt: baseRemoteUpdatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(baseRemoteUpdatedAt),
      baseObservedPublicationId:
          baseObservedPublicationId == null && nullToAbsent
          ? const Value.absent()
          : Value(baseObservedPublicationId),
      baseTitle: baseTitle == null && nullToAbsent
          ? const Value.absent()
          : Value(baseTitle),
      baseNotes: baseNotes == null && nullToAbsent
          ? const Value.absent()
          : Value(baseNotes),
      baseStatus: baseStatus == null && nullToAbsent
          ? const Value.absent()
          : Value(baseStatus),
      baseDueEpochDay: baseDueEpochDay == null && nullToAbsent
          ? const Value.absent()
          : Value(baseDueEpochDay),
      baseTaskListId: baseTaskListId == null && nullToAbsent
          ? const Value.absent()
          : Value(baseTaskListId),
      baseParentTaskId: baseParentTaskId == null && nullToAbsent
          ? const Value.absent()
          : Value(baseParentTaskId),
      basePreviousTaskId: basePreviousTaskId == null && nullToAbsent
          ? const Value.absent()
          : Value(basePreviousTaskId),
      basePosition: basePosition == null && nullToAbsent
          ? const Value.absent()
          : Value(basePosition),
      baseSiblingOrder: baseSiblingOrder == null && nullToAbsent
          ? const Value.absent()
          : Value(baseSiblingOrder),
      failureCode: failureCode == null && nullToAbsent
          ? const Value.absent()
          : Value(failureCode),
      createdAt: Value(createdAt),
      lastTransitionAt: Value(lastTransitionAt),
    );
  }

  factory DesiredStateRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DesiredStateRow(
      id: serializer.fromJson<int>(json['id']),
      accountId: serializer.fromJson<int>(json['accountId']),
      targetKey: serializer.fromJson<String>(json['targetKey']),
      resourceType: serializer.fromJson<String>(json['resourceType']),
      targetTaskListId: serializer.fromJson<int?>(json['targetTaskListId']),
      targetTaskId: serializer.fromJson<int?>(json['targetTaskId']),
      desiredLifecycle: serializer.fromJson<String>(json['desiredLifecycle']),
      title: serializer.fromJson<String?>(json['title']),
      notes: serializer.fromJson<String?>(json['notes']),
      status: serializer.fromJson<String?>(json['status']),
      dueEpochDay: serializer.fromJson<int?>(json['dueEpochDay']),
      desiredTaskListId: serializer.fromJson<int?>(json['desiredTaskListId']),
      desiredParentTaskId: serializer.fromJson<int?>(
        json['desiredParentTaskId'],
      ),
      desiredPreviousTaskId: serializer.fromJson<int?>(
        json['desiredPreviousTaskId'],
      ),
      contentDirty: serializer.fromJson<bool>(json['contentDirty']),
      structureDirty: serializer.fromJson<bool>(json['structureDirty']),
      lifecycleDirty: serializer.fromJson<bool>(json['lifecycleDirty']),
      localModifiedAt: serializer.fromJson<DateTime?>(json['localModifiedAt']),
      notBefore: serializer.fromJson<DateTime?>(json['notBefore']),
      generation: serializer.fromJson<int>(json['generation']),
      localCausalSequence: serializer.fromJson<int>(
        json['localCausalSequence'],
      ),
      state: serializer.fromJson<String>(json['state']),
      baseRemoteId: serializer.fromJson<String?>(json['baseRemoteId']),
      baseEtag: serializer.fromJson<String?>(json['baseEtag']),
      baseRemoteUpdatedAt: serializer.fromJson<DateTime?>(
        json['baseRemoteUpdatedAt'],
      ),
      baseObservedPublicationId: serializer.fromJson<String?>(
        json['baseObservedPublicationId'],
      ),
      baseTitle: serializer.fromJson<String?>(json['baseTitle']),
      baseNotes: serializer.fromJson<String?>(json['baseNotes']),
      baseStatus: serializer.fromJson<String?>(json['baseStatus']),
      baseDueEpochDay: serializer.fromJson<int?>(json['baseDueEpochDay']),
      baseTaskListId: serializer.fromJson<int?>(json['baseTaskListId']),
      baseParentTaskId: serializer.fromJson<int?>(json['baseParentTaskId']),
      basePreviousTaskId: serializer.fromJson<int?>(json['basePreviousTaskId']),
      basePosition: serializer.fromJson<String?>(json['basePosition']),
      baseSiblingOrder: serializer.fromJson<String?>(json['baseSiblingOrder']),
      failureCode: serializer.fromJson<String?>(json['failureCode']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      lastTransitionAt: serializer.fromJson<DateTime>(json['lastTransitionAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'accountId': serializer.toJson<int>(accountId),
      'targetKey': serializer.toJson<String>(targetKey),
      'resourceType': serializer.toJson<String>(resourceType),
      'targetTaskListId': serializer.toJson<int?>(targetTaskListId),
      'targetTaskId': serializer.toJson<int?>(targetTaskId),
      'desiredLifecycle': serializer.toJson<String>(desiredLifecycle),
      'title': serializer.toJson<String?>(title),
      'notes': serializer.toJson<String?>(notes),
      'status': serializer.toJson<String?>(status),
      'dueEpochDay': serializer.toJson<int?>(dueEpochDay),
      'desiredTaskListId': serializer.toJson<int?>(desiredTaskListId),
      'desiredParentTaskId': serializer.toJson<int?>(desiredParentTaskId),
      'desiredPreviousTaskId': serializer.toJson<int?>(desiredPreviousTaskId),
      'contentDirty': serializer.toJson<bool>(contentDirty),
      'structureDirty': serializer.toJson<bool>(structureDirty),
      'lifecycleDirty': serializer.toJson<bool>(lifecycleDirty),
      'localModifiedAt': serializer.toJson<DateTime?>(localModifiedAt),
      'notBefore': serializer.toJson<DateTime?>(notBefore),
      'generation': serializer.toJson<int>(generation),
      'localCausalSequence': serializer.toJson<int>(localCausalSequence),
      'state': serializer.toJson<String>(state),
      'baseRemoteId': serializer.toJson<String?>(baseRemoteId),
      'baseEtag': serializer.toJson<String?>(baseEtag),
      'baseRemoteUpdatedAt': serializer.toJson<DateTime?>(baseRemoteUpdatedAt),
      'baseObservedPublicationId': serializer.toJson<String?>(
        baseObservedPublicationId,
      ),
      'baseTitle': serializer.toJson<String?>(baseTitle),
      'baseNotes': serializer.toJson<String?>(baseNotes),
      'baseStatus': serializer.toJson<String?>(baseStatus),
      'baseDueEpochDay': serializer.toJson<int?>(baseDueEpochDay),
      'baseTaskListId': serializer.toJson<int?>(baseTaskListId),
      'baseParentTaskId': serializer.toJson<int?>(baseParentTaskId),
      'basePreviousTaskId': serializer.toJson<int?>(basePreviousTaskId),
      'basePosition': serializer.toJson<String?>(basePosition),
      'baseSiblingOrder': serializer.toJson<String?>(baseSiblingOrder),
      'failureCode': serializer.toJson<String?>(failureCode),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'lastTransitionAt': serializer.toJson<DateTime>(lastTransitionAt),
    };
  }

  DesiredStateRow copyWith({
    int? id,
    int? accountId,
    String? targetKey,
    String? resourceType,
    Value<int?> targetTaskListId = const Value.absent(),
    Value<int?> targetTaskId = const Value.absent(),
    String? desiredLifecycle,
    Value<String?> title = const Value.absent(),
    Value<String?> notes = const Value.absent(),
    Value<String?> status = const Value.absent(),
    Value<int?> dueEpochDay = const Value.absent(),
    Value<int?> desiredTaskListId = const Value.absent(),
    Value<int?> desiredParentTaskId = const Value.absent(),
    Value<int?> desiredPreviousTaskId = const Value.absent(),
    bool? contentDirty,
    bool? structureDirty,
    bool? lifecycleDirty,
    Value<DateTime?> localModifiedAt = const Value.absent(),
    Value<DateTime?> notBefore = const Value.absent(),
    int? generation,
    int? localCausalSequence,
    String? state,
    Value<String?> baseRemoteId = const Value.absent(),
    Value<String?> baseEtag = const Value.absent(),
    Value<DateTime?> baseRemoteUpdatedAt = const Value.absent(),
    Value<String?> baseObservedPublicationId = const Value.absent(),
    Value<String?> baseTitle = const Value.absent(),
    Value<String?> baseNotes = const Value.absent(),
    Value<String?> baseStatus = const Value.absent(),
    Value<int?> baseDueEpochDay = const Value.absent(),
    Value<int?> baseTaskListId = const Value.absent(),
    Value<int?> baseParentTaskId = const Value.absent(),
    Value<int?> basePreviousTaskId = const Value.absent(),
    Value<String?> basePosition = const Value.absent(),
    Value<String?> baseSiblingOrder = const Value.absent(),
    Value<String?> failureCode = const Value.absent(),
    DateTime? createdAt,
    DateTime? lastTransitionAt,
  }) => DesiredStateRow(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    targetKey: targetKey ?? this.targetKey,
    resourceType: resourceType ?? this.resourceType,
    targetTaskListId: targetTaskListId.present
        ? targetTaskListId.value
        : this.targetTaskListId,
    targetTaskId: targetTaskId.present ? targetTaskId.value : this.targetTaskId,
    desiredLifecycle: desiredLifecycle ?? this.desiredLifecycle,
    title: title.present ? title.value : this.title,
    notes: notes.present ? notes.value : this.notes,
    status: status.present ? status.value : this.status,
    dueEpochDay: dueEpochDay.present ? dueEpochDay.value : this.dueEpochDay,
    desiredTaskListId: desiredTaskListId.present
        ? desiredTaskListId.value
        : this.desiredTaskListId,
    desiredParentTaskId: desiredParentTaskId.present
        ? desiredParentTaskId.value
        : this.desiredParentTaskId,
    desiredPreviousTaskId: desiredPreviousTaskId.present
        ? desiredPreviousTaskId.value
        : this.desiredPreviousTaskId,
    contentDirty: contentDirty ?? this.contentDirty,
    structureDirty: structureDirty ?? this.structureDirty,
    lifecycleDirty: lifecycleDirty ?? this.lifecycleDirty,
    localModifiedAt: localModifiedAt.present
        ? localModifiedAt.value
        : this.localModifiedAt,
    notBefore: notBefore.present ? notBefore.value : this.notBefore,
    generation: generation ?? this.generation,
    localCausalSequence: localCausalSequence ?? this.localCausalSequence,
    state: state ?? this.state,
    baseRemoteId: baseRemoteId.present ? baseRemoteId.value : this.baseRemoteId,
    baseEtag: baseEtag.present ? baseEtag.value : this.baseEtag,
    baseRemoteUpdatedAt: baseRemoteUpdatedAt.present
        ? baseRemoteUpdatedAt.value
        : this.baseRemoteUpdatedAt,
    baseObservedPublicationId: baseObservedPublicationId.present
        ? baseObservedPublicationId.value
        : this.baseObservedPublicationId,
    baseTitle: baseTitle.present ? baseTitle.value : this.baseTitle,
    baseNotes: baseNotes.present ? baseNotes.value : this.baseNotes,
    baseStatus: baseStatus.present ? baseStatus.value : this.baseStatus,
    baseDueEpochDay: baseDueEpochDay.present
        ? baseDueEpochDay.value
        : this.baseDueEpochDay,
    baseTaskListId: baseTaskListId.present
        ? baseTaskListId.value
        : this.baseTaskListId,
    baseParentTaskId: baseParentTaskId.present
        ? baseParentTaskId.value
        : this.baseParentTaskId,
    basePreviousTaskId: basePreviousTaskId.present
        ? basePreviousTaskId.value
        : this.basePreviousTaskId,
    basePosition: basePosition.present ? basePosition.value : this.basePosition,
    baseSiblingOrder: baseSiblingOrder.present
        ? baseSiblingOrder.value
        : this.baseSiblingOrder,
    failureCode: failureCode.present ? failureCode.value : this.failureCode,
    createdAt: createdAt ?? this.createdAt,
    lastTransitionAt: lastTransitionAt ?? this.lastTransitionAt,
  );
  DesiredStateRow copyWithCompanion(DesiredStateRowsCompanion data) {
    return DesiredStateRow(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      targetKey: data.targetKey.present ? data.targetKey.value : this.targetKey,
      resourceType: data.resourceType.present
          ? data.resourceType.value
          : this.resourceType,
      targetTaskListId: data.targetTaskListId.present
          ? data.targetTaskListId.value
          : this.targetTaskListId,
      targetTaskId: data.targetTaskId.present
          ? data.targetTaskId.value
          : this.targetTaskId,
      desiredLifecycle: data.desiredLifecycle.present
          ? data.desiredLifecycle.value
          : this.desiredLifecycle,
      title: data.title.present ? data.title.value : this.title,
      notes: data.notes.present ? data.notes.value : this.notes,
      status: data.status.present ? data.status.value : this.status,
      dueEpochDay: data.dueEpochDay.present
          ? data.dueEpochDay.value
          : this.dueEpochDay,
      desiredTaskListId: data.desiredTaskListId.present
          ? data.desiredTaskListId.value
          : this.desiredTaskListId,
      desiredParentTaskId: data.desiredParentTaskId.present
          ? data.desiredParentTaskId.value
          : this.desiredParentTaskId,
      desiredPreviousTaskId: data.desiredPreviousTaskId.present
          ? data.desiredPreviousTaskId.value
          : this.desiredPreviousTaskId,
      contentDirty: data.contentDirty.present
          ? data.contentDirty.value
          : this.contentDirty,
      structureDirty: data.structureDirty.present
          ? data.structureDirty.value
          : this.structureDirty,
      lifecycleDirty: data.lifecycleDirty.present
          ? data.lifecycleDirty.value
          : this.lifecycleDirty,
      localModifiedAt: data.localModifiedAt.present
          ? data.localModifiedAt.value
          : this.localModifiedAt,
      notBefore: data.notBefore.present ? data.notBefore.value : this.notBefore,
      generation: data.generation.present
          ? data.generation.value
          : this.generation,
      localCausalSequence: data.localCausalSequence.present
          ? data.localCausalSequence.value
          : this.localCausalSequence,
      state: data.state.present ? data.state.value : this.state,
      baseRemoteId: data.baseRemoteId.present
          ? data.baseRemoteId.value
          : this.baseRemoteId,
      baseEtag: data.baseEtag.present ? data.baseEtag.value : this.baseEtag,
      baseRemoteUpdatedAt: data.baseRemoteUpdatedAt.present
          ? data.baseRemoteUpdatedAt.value
          : this.baseRemoteUpdatedAt,
      baseObservedPublicationId: data.baseObservedPublicationId.present
          ? data.baseObservedPublicationId.value
          : this.baseObservedPublicationId,
      baseTitle: data.baseTitle.present ? data.baseTitle.value : this.baseTitle,
      baseNotes: data.baseNotes.present ? data.baseNotes.value : this.baseNotes,
      baseStatus: data.baseStatus.present
          ? data.baseStatus.value
          : this.baseStatus,
      baseDueEpochDay: data.baseDueEpochDay.present
          ? data.baseDueEpochDay.value
          : this.baseDueEpochDay,
      baseTaskListId: data.baseTaskListId.present
          ? data.baseTaskListId.value
          : this.baseTaskListId,
      baseParentTaskId: data.baseParentTaskId.present
          ? data.baseParentTaskId.value
          : this.baseParentTaskId,
      basePreviousTaskId: data.basePreviousTaskId.present
          ? data.basePreviousTaskId.value
          : this.basePreviousTaskId,
      basePosition: data.basePosition.present
          ? data.basePosition.value
          : this.basePosition,
      baseSiblingOrder: data.baseSiblingOrder.present
          ? data.baseSiblingOrder.value
          : this.baseSiblingOrder,
      failureCode: data.failureCode.present
          ? data.failureCode.value
          : this.failureCode,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      lastTransitionAt: data.lastTransitionAt.present
          ? data.lastTransitionAt.value
          : this.lastTransitionAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DesiredStateRow(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('targetKey: $targetKey, ')
          ..write('resourceType: $resourceType, ')
          ..write('targetTaskListId: $targetTaskListId, ')
          ..write('targetTaskId: $targetTaskId, ')
          ..write('desiredLifecycle: $desiredLifecycle, ')
          ..write('title: $title, ')
          ..write('notes: $notes, ')
          ..write('status: $status, ')
          ..write('dueEpochDay: $dueEpochDay, ')
          ..write('desiredTaskListId: $desiredTaskListId, ')
          ..write('desiredParentTaskId: $desiredParentTaskId, ')
          ..write('desiredPreviousTaskId: $desiredPreviousTaskId, ')
          ..write('contentDirty: $contentDirty, ')
          ..write('structureDirty: $structureDirty, ')
          ..write('lifecycleDirty: $lifecycleDirty, ')
          ..write('localModifiedAt: $localModifiedAt, ')
          ..write('notBefore: $notBefore, ')
          ..write('generation: $generation, ')
          ..write('localCausalSequence: $localCausalSequence, ')
          ..write('state: $state, ')
          ..write('baseRemoteId: $baseRemoteId, ')
          ..write('baseEtag: $baseEtag, ')
          ..write('baseRemoteUpdatedAt: $baseRemoteUpdatedAt, ')
          ..write('baseObservedPublicationId: $baseObservedPublicationId, ')
          ..write('baseTitle: $baseTitle, ')
          ..write('baseNotes: $baseNotes, ')
          ..write('baseStatus: $baseStatus, ')
          ..write('baseDueEpochDay: $baseDueEpochDay, ')
          ..write('baseTaskListId: $baseTaskListId, ')
          ..write('baseParentTaskId: $baseParentTaskId, ')
          ..write('basePreviousTaskId: $basePreviousTaskId, ')
          ..write('basePosition: $basePosition, ')
          ..write('baseSiblingOrder: $baseSiblingOrder, ')
          ..write('failureCode: $failureCode, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastTransitionAt: $lastTransitionAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    accountId,
    targetKey,
    resourceType,
    targetTaskListId,
    targetTaskId,
    desiredLifecycle,
    title,
    notes,
    status,
    dueEpochDay,
    desiredTaskListId,
    desiredParentTaskId,
    desiredPreviousTaskId,
    contentDirty,
    structureDirty,
    lifecycleDirty,
    localModifiedAt,
    notBefore,
    generation,
    localCausalSequence,
    state,
    baseRemoteId,
    baseEtag,
    baseRemoteUpdatedAt,
    baseObservedPublicationId,
    baseTitle,
    baseNotes,
    baseStatus,
    baseDueEpochDay,
    baseTaskListId,
    baseParentTaskId,
    basePreviousTaskId,
    basePosition,
    baseSiblingOrder,
    failureCode,
    createdAt,
    lastTransitionAt,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DesiredStateRow &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.targetKey == this.targetKey &&
          other.resourceType == this.resourceType &&
          other.targetTaskListId == this.targetTaskListId &&
          other.targetTaskId == this.targetTaskId &&
          other.desiredLifecycle == this.desiredLifecycle &&
          other.title == this.title &&
          other.notes == this.notes &&
          other.status == this.status &&
          other.dueEpochDay == this.dueEpochDay &&
          other.desiredTaskListId == this.desiredTaskListId &&
          other.desiredParentTaskId == this.desiredParentTaskId &&
          other.desiredPreviousTaskId == this.desiredPreviousTaskId &&
          other.contentDirty == this.contentDirty &&
          other.structureDirty == this.structureDirty &&
          other.lifecycleDirty == this.lifecycleDirty &&
          other.localModifiedAt == this.localModifiedAt &&
          other.notBefore == this.notBefore &&
          other.generation == this.generation &&
          other.localCausalSequence == this.localCausalSequence &&
          other.state == this.state &&
          other.baseRemoteId == this.baseRemoteId &&
          other.baseEtag == this.baseEtag &&
          other.baseRemoteUpdatedAt == this.baseRemoteUpdatedAt &&
          other.baseObservedPublicationId == this.baseObservedPublicationId &&
          other.baseTitle == this.baseTitle &&
          other.baseNotes == this.baseNotes &&
          other.baseStatus == this.baseStatus &&
          other.baseDueEpochDay == this.baseDueEpochDay &&
          other.baseTaskListId == this.baseTaskListId &&
          other.baseParentTaskId == this.baseParentTaskId &&
          other.basePreviousTaskId == this.basePreviousTaskId &&
          other.basePosition == this.basePosition &&
          other.baseSiblingOrder == this.baseSiblingOrder &&
          other.failureCode == this.failureCode &&
          other.createdAt == this.createdAt &&
          other.lastTransitionAt == this.lastTransitionAt);
}

class DesiredStateRowsCompanion extends UpdateCompanion<DesiredStateRow> {
  final Value<int> id;
  final Value<int> accountId;
  final Value<String> targetKey;
  final Value<String> resourceType;
  final Value<int?> targetTaskListId;
  final Value<int?> targetTaskId;
  final Value<String> desiredLifecycle;
  final Value<String?> title;
  final Value<String?> notes;
  final Value<String?> status;
  final Value<int?> dueEpochDay;
  final Value<int?> desiredTaskListId;
  final Value<int?> desiredParentTaskId;
  final Value<int?> desiredPreviousTaskId;
  final Value<bool> contentDirty;
  final Value<bool> structureDirty;
  final Value<bool> lifecycleDirty;
  final Value<DateTime?> localModifiedAt;
  final Value<DateTime?> notBefore;
  final Value<int> generation;
  final Value<int> localCausalSequence;
  final Value<String> state;
  final Value<String?> baseRemoteId;
  final Value<String?> baseEtag;
  final Value<DateTime?> baseRemoteUpdatedAt;
  final Value<String?> baseObservedPublicationId;
  final Value<String?> baseTitle;
  final Value<String?> baseNotes;
  final Value<String?> baseStatus;
  final Value<int?> baseDueEpochDay;
  final Value<int?> baseTaskListId;
  final Value<int?> baseParentTaskId;
  final Value<int?> basePreviousTaskId;
  final Value<String?> basePosition;
  final Value<String?> baseSiblingOrder;
  final Value<String?> failureCode;
  final Value<DateTime> createdAt;
  final Value<DateTime> lastTransitionAt;
  const DesiredStateRowsCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.targetKey = const Value.absent(),
    this.resourceType = const Value.absent(),
    this.targetTaskListId = const Value.absent(),
    this.targetTaskId = const Value.absent(),
    this.desiredLifecycle = const Value.absent(),
    this.title = const Value.absent(),
    this.notes = const Value.absent(),
    this.status = const Value.absent(),
    this.dueEpochDay = const Value.absent(),
    this.desiredTaskListId = const Value.absent(),
    this.desiredParentTaskId = const Value.absent(),
    this.desiredPreviousTaskId = const Value.absent(),
    this.contentDirty = const Value.absent(),
    this.structureDirty = const Value.absent(),
    this.lifecycleDirty = const Value.absent(),
    this.localModifiedAt = const Value.absent(),
    this.notBefore = const Value.absent(),
    this.generation = const Value.absent(),
    this.localCausalSequence = const Value.absent(),
    this.state = const Value.absent(),
    this.baseRemoteId = const Value.absent(),
    this.baseEtag = const Value.absent(),
    this.baseRemoteUpdatedAt = const Value.absent(),
    this.baseObservedPublicationId = const Value.absent(),
    this.baseTitle = const Value.absent(),
    this.baseNotes = const Value.absent(),
    this.baseStatus = const Value.absent(),
    this.baseDueEpochDay = const Value.absent(),
    this.baseTaskListId = const Value.absent(),
    this.baseParentTaskId = const Value.absent(),
    this.basePreviousTaskId = const Value.absent(),
    this.basePosition = const Value.absent(),
    this.baseSiblingOrder = const Value.absent(),
    this.failureCode = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.lastTransitionAt = const Value.absent(),
  });
  DesiredStateRowsCompanion.insert({
    this.id = const Value.absent(),
    required int accountId,
    required String targetKey,
    required String resourceType,
    this.targetTaskListId = const Value.absent(),
    this.targetTaskId = const Value.absent(),
    required String desiredLifecycle,
    this.title = const Value.absent(),
    this.notes = const Value.absent(),
    this.status = const Value.absent(),
    this.dueEpochDay = const Value.absent(),
    this.desiredTaskListId = const Value.absent(),
    this.desiredParentTaskId = const Value.absent(),
    this.desiredPreviousTaskId = const Value.absent(),
    this.contentDirty = const Value.absent(),
    this.structureDirty = const Value.absent(),
    this.lifecycleDirty = const Value.absent(),
    this.localModifiedAt = const Value.absent(),
    this.notBefore = const Value.absent(),
    required int generation,
    required int localCausalSequence,
    required String state,
    this.baseRemoteId = const Value.absent(),
    this.baseEtag = const Value.absent(),
    this.baseRemoteUpdatedAt = const Value.absent(),
    this.baseObservedPublicationId = const Value.absent(),
    this.baseTitle = const Value.absent(),
    this.baseNotes = const Value.absent(),
    this.baseStatus = const Value.absent(),
    this.baseDueEpochDay = const Value.absent(),
    this.baseTaskListId = const Value.absent(),
    this.baseParentTaskId = const Value.absent(),
    this.basePreviousTaskId = const Value.absent(),
    this.basePosition = const Value.absent(),
    this.baseSiblingOrder = const Value.absent(),
    this.failureCode = const Value.absent(),
    required DateTime createdAt,
    required DateTime lastTransitionAt,
  }) : accountId = Value(accountId),
       targetKey = Value(targetKey),
       resourceType = Value(resourceType),
       desiredLifecycle = Value(desiredLifecycle),
       generation = Value(generation),
       localCausalSequence = Value(localCausalSequence),
       state = Value(state),
       createdAt = Value(createdAt),
       lastTransitionAt = Value(lastTransitionAt);
  static Insertable<DesiredStateRow> custom({
    Expression<int>? id,
    Expression<int>? accountId,
    Expression<String>? targetKey,
    Expression<String>? resourceType,
    Expression<int>? targetTaskListId,
    Expression<int>? targetTaskId,
    Expression<String>? desiredLifecycle,
    Expression<String>? title,
    Expression<String>? notes,
    Expression<String>? status,
    Expression<int>? dueEpochDay,
    Expression<int>? desiredTaskListId,
    Expression<int>? desiredParentTaskId,
    Expression<int>? desiredPreviousTaskId,
    Expression<bool>? contentDirty,
    Expression<bool>? structureDirty,
    Expression<bool>? lifecycleDirty,
    Expression<DateTime>? localModifiedAt,
    Expression<DateTime>? notBefore,
    Expression<int>? generation,
    Expression<int>? localCausalSequence,
    Expression<String>? state,
    Expression<String>? baseRemoteId,
    Expression<String>? baseEtag,
    Expression<DateTime>? baseRemoteUpdatedAt,
    Expression<String>? baseObservedPublicationId,
    Expression<String>? baseTitle,
    Expression<String>? baseNotes,
    Expression<String>? baseStatus,
    Expression<int>? baseDueEpochDay,
    Expression<int>? baseTaskListId,
    Expression<int>? baseParentTaskId,
    Expression<int>? basePreviousTaskId,
    Expression<String>? basePosition,
    Expression<String>? baseSiblingOrder,
    Expression<String>? failureCode,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? lastTransitionAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (targetKey != null) 'target_key': targetKey,
      if (resourceType != null) 'resource_type': resourceType,
      if (targetTaskListId != null) 'target_task_list_id': targetTaskListId,
      if (targetTaskId != null) 'target_task_id': targetTaskId,
      if (desiredLifecycle != null) 'desired_lifecycle': desiredLifecycle,
      if (title != null) 'title': title,
      if (notes != null) 'notes': notes,
      if (status != null) 'status': status,
      if (dueEpochDay != null) 'due_epoch_day': dueEpochDay,
      if (desiredTaskListId != null) 'desired_task_list_id': desiredTaskListId,
      if (desiredParentTaskId != null)
        'desired_parent_task_id': desiredParentTaskId,
      if (desiredPreviousTaskId != null)
        'desired_previous_task_id': desiredPreviousTaskId,
      if (contentDirty != null) 'content_dirty': contentDirty,
      if (structureDirty != null) 'structure_dirty': structureDirty,
      if (lifecycleDirty != null) 'lifecycle_dirty': lifecycleDirty,
      if (localModifiedAt != null) 'local_modified_at': localModifiedAt,
      if (notBefore != null) 'not_before': notBefore,
      if (generation != null) 'generation': generation,
      if (localCausalSequence != null)
        'local_causal_sequence': localCausalSequence,
      if (state != null) 'state': state,
      if (baseRemoteId != null) 'base_remote_id': baseRemoteId,
      if (baseEtag != null) 'base_etag': baseEtag,
      if (baseRemoteUpdatedAt != null)
        'base_remote_updated_at': baseRemoteUpdatedAt,
      if (baseObservedPublicationId != null)
        'base_observed_publication_id': baseObservedPublicationId,
      if (baseTitle != null) 'base_title': baseTitle,
      if (baseNotes != null) 'base_notes': baseNotes,
      if (baseStatus != null) 'base_status': baseStatus,
      if (baseDueEpochDay != null) 'base_due_epoch_day': baseDueEpochDay,
      if (baseTaskListId != null) 'base_task_list_id': baseTaskListId,
      if (baseParentTaskId != null) 'base_parent_task_id': baseParentTaskId,
      if (basePreviousTaskId != null)
        'base_previous_task_id': basePreviousTaskId,
      if (basePosition != null) 'base_position': basePosition,
      if (baseSiblingOrder != null) 'base_sibling_order': baseSiblingOrder,
      if (failureCode != null) 'failure_code': failureCode,
      if (createdAt != null) 'created_at': createdAt,
      if (lastTransitionAt != null) 'last_transition_at': lastTransitionAt,
    });
  }

  DesiredStateRowsCompanion copyWith({
    Value<int>? id,
    Value<int>? accountId,
    Value<String>? targetKey,
    Value<String>? resourceType,
    Value<int?>? targetTaskListId,
    Value<int?>? targetTaskId,
    Value<String>? desiredLifecycle,
    Value<String?>? title,
    Value<String?>? notes,
    Value<String?>? status,
    Value<int?>? dueEpochDay,
    Value<int?>? desiredTaskListId,
    Value<int?>? desiredParentTaskId,
    Value<int?>? desiredPreviousTaskId,
    Value<bool>? contentDirty,
    Value<bool>? structureDirty,
    Value<bool>? lifecycleDirty,
    Value<DateTime?>? localModifiedAt,
    Value<DateTime?>? notBefore,
    Value<int>? generation,
    Value<int>? localCausalSequence,
    Value<String>? state,
    Value<String?>? baseRemoteId,
    Value<String?>? baseEtag,
    Value<DateTime?>? baseRemoteUpdatedAt,
    Value<String?>? baseObservedPublicationId,
    Value<String?>? baseTitle,
    Value<String?>? baseNotes,
    Value<String?>? baseStatus,
    Value<int?>? baseDueEpochDay,
    Value<int?>? baseTaskListId,
    Value<int?>? baseParentTaskId,
    Value<int?>? basePreviousTaskId,
    Value<String?>? basePosition,
    Value<String?>? baseSiblingOrder,
    Value<String?>? failureCode,
    Value<DateTime>? createdAt,
    Value<DateTime>? lastTransitionAt,
  }) {
    return DesiredStateRowsCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      targetKey: targetKey ?? this.targetKey,
      resourceType: resourceType ?? this.resourceType,
      targetTaskListId: targetTaskListId ?? this.targetTaskListId,
      targetTaskId: targetTaskId ?? this.targetTaskId,
      desiredLifecycle: desiredLifecycle ?? this.desiredLifecycle,
      title: title ?? this.title,
      notes: notes ?? this.notes,
      status: status ?? this.status,
      dueEpochDay: dueEpochDay ?? this.dueEpochDay,
      desiredTaskListId: desiredTaskListId ?? this.desiredTaskListId,
      desiredParentTaskId: desiredParentTaskId ?? this.desiredParentTaskId,
      desiredPreviousTaskId:
          desiredPreviousTaskId ?? this.desiredPreviousTaskId,
      contentDirty: contentDirty ?? this.contentDirty,
      structureDirty: structureDirty ?? this.structureDirty,
      lifecycleDirty: lifecycleDirty ?? this.lifecycleDirty,
      localModifiedAt: localModifiedAt ?? this.localModifiedAt,
      notBefore: notBefore ?? this.notBefore,
      generation: generation ?? this.generation,
      localCausalSequence: localCausalSequence ?? this.localCausalSequence,
      state: state ?? this.state,
      baseRemoteId: baseRemoteId ?? this.baseRemoteId,
      baseEtag: baseEtag ?? this.baseEtag,
      baseRemoteUpdatedAt: baseRemoteUpdatedAt ?? this.baseRemoteUpdatedAt,
      baseObservedPublicationId:
          baseObservedPublicationId ?? this.baseObservedPublicationId,
      baseTitle: baseTitle ?? this.baseTitle,
      baseNotes: baseNotes ?? this.baseNotes,
      baseStatus: baseStatus ?? this.baseStatus,
      baseDueEpochDay: baseDueEpochDay ?? this.baseDueEpochDay,
      baseTaskListId: baseTaskListId ?? this.baseTaskListId,
      baseParentTaskId: baseParentTaskId ?? this.baseParentTaskId,
      basePreviousTaskId: basePreviousTaskId ?? this.basePreviousTaskId,
      basePosition: basePosition ?? this.basePosition,
      baseSiblingOrder: baseSiblingOrder ?? this.baseSiblingOrder,
      failureCode: failureCode ?? this.failureCode,
      createdAt: createdAt ?? this.createdAt,
      lastTransitionAt: lastTransitionAt ?? this.lastTransitionAt,
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
    if (targetKey.present) {
      map['target_key'] = Variable<String>(targetKey.value);
    }
    if (resourceType.present) {
      map['resource_type'] = Variable<String>(resourceType.value);
    }
    if (targetTaskListId.present) {
      map['target_task_list_id'] = Variable<int>(targetTaskListId.value);
    }
    if (targetTaskId.present) {
      map['target_task_id'] = Variable<int>(targetTaskId.value);
    }
    if (desiredLifecycle.present) {
      map['desired_lifecycle'] = Variable<String>(desiredLifecycle.value);
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
    if (desiredTaskListId.present) {
      map['desired_task_list_id'] = Variable<int>(desiredTaskListId.value);
    }
    if (desiredParentTaskId.present) {
      map['desired_parent_task_id'] = Variable<int>(desiredParentTaskId.value);
    }
    if (desiredPreviousTaskId.present) {
      map['desired_previous_task_id'] = Variable<int>(
        desiredPreviousTaskId.value,
      );
    }
    if (contentDirty.present) {
      map['content_dirty'] = Variable<bool>(contentDirty.value);
    }
    if (structureDirty.present) {
      map['structure_dirty'] = Variable<bool>(structureDirty.value);
    }
    if (lifecycleDirty.present) {
      map['lifecycle_dirty'] = Variable<bool>(lifecycleDirty.value);
    }
    if (localModifiedAt.present) {
      map['local_modified_at'] = Variable<DateTime>(localModifiedAt.value);
    }
    if (notBefore.present) {
      map['not_before'] = Variable<DateTime>(notBefore.value);
    }
    if (generation.present) {
      map['generation'] = Variable<int>(generation.value);
    }
    if (localCausalSequence.present) {
      map['local_causal_sequence'] = Variable<int>(localCausalSequence.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (baseRemoteId.present) {
      map['base_remote_id'] = Variable<String>(baseRemoteId.value);
    }
    if (baseEtag.present) {
      map['base_etag'] = Variable<String>(baseEtag.value);
    }
    if (baseRemoteUpdatedAt.present) {
      map['base_remote_updated_at'] = Variable<DateTime>(
        baseRemoteUpdatedAt.value,
      );
    }
    if (baseObservedPublicationId.present) {
      map['base_observed_publication_id'] = Variable<String>(
        baseObservedPublicationId.value,
      );
    }
    if (baseTitle.present) {
      map['base_title'] = Variable<String>(baseTitle.value);
    }
    if (baseNotes.present) {
      map['base_notes'] = Variable<String>(baseNotes.value);
    }
    if (baseStatus.present) {
      map['base_status'] = Variable<String>(baseStatus.value);
    }
    if (baseDueEpochDay.present) {
      map['base_due_epoch_day'] = Variable<int>(baseDueEpochDay.value);
    }
    if (baseTaskListId.present) {
      map['base_task_list_id'] = Variable<int>(baseTaskListId.value);
    }
    if (baseParentTaskId.present) {
      map['base_parent_task_id'] = Variable<int>(baseParentTaskId.value);
    }
    if (basePreviousTaskId.present) {
      map['base_previous_task_id'] = Variable<int>(basePreviousTaskId.value);
    }
    if (basePosition.present) {
      map['base_position'] = Variable<String>(basePosition.value);
    }
    if (baseSiblingOrder.present) {
      map['base_sibling_order'] = Variable<String>(baseSiblingOrder.value);
    }
    if (failureCode.present) {
      map['failure_code'] = Variable<String>(failureCode.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (lastTransitionAt.present) {
      map['last_transition_at'] = Variable<DateTime>(lastTransitionAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DesiredStateRowsCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('targetKey: $targetKey, ')
          ..write('resourceType: $resourceType, ')
          ..write('targetTaskListId: $targetTaskListId, ')
          ..write('targetTaskId: $targetTaskId, ')
          ..write('desiredLifecycle: $desiredLifecycle, ')
          ..write('title: $title, ')
          ..write('notes: $notes, ')
          ..write('status: $status, ')
          ..write('dueEpochDay: $dueEpochDay, ')
          ..write('desiredTaskListId: $desiredTaskListId, ')
          ..write('desiredParentTaskId: $desiredParentTaskId, ')
          ..write('desiredPreviousTaskId: $desiredPreviousTaskId, ')
          ..write('contentDirty: $contentDirty, ')
          ..write('structureDirty: $structureDirty, ')
          ..write('lifecycleDirty: $lifecycleDirty, ')
          ..write('localModifiedAt: $localModifiedAt, ')
          ..write('notBefore: $notBefore, ')
          ..write('generation: $generation, ')
          ..write('localCausalSequence: $localCausalSequence, ')
          ..write('state: $state, ')
          ..write('baseRemoteId: $baseRemoteId, ')
          ..write('baseEtag: $baseEtag, ')
          ..write('baseRemoteUpdatedAt: $baseRemoteUpdatedAt, ')
          ..write('baseObservedPublicationId: $baseObservedPublicationId, ')
          ..write('baseTitle: $baseTitle, ')
          ..write('baseNotes: $baseNotes, ')
          ..write('baseStatus: $baseStatus, ')
          ..write('baseDueEpochDay: $baseDueEpochDay, ')
          ..write('baseTaskListId: $baseTaskListId, ')
          ..write('baseParentTaskId: $baseParentTaskId, ')
          ..write('basePreviousTaskId: $basePreviousTaskId, ')
          ..write('basePosition: $basePosition, ')
          ..write('baseSiblingOrder: $baseSiblingOrder, ')
          ..write('failureCode: $failureCode, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastTransitionAt: $lastTransitionAt')
          ..write(')'))
        .toString();
  }
}

class $DesiredStateDependencyRowsTable extends DesiredStateDependencyRows
    with
        TableInfo<$DesiredStateDependencyRowsTable, DesiredStateDependencyRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DesiredStateDependencyRowsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _desiredStateIdMeta = const VerificationMeta(
    'desiredStateId',
  );
  @override
  late final GeneratedColumn<int> desiredStateId = GeneratedColumn<int>(
    'desired_state_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dependencyKindMeta = const VerificationMeta(
    'dependencyKind',
  );
  @override
  late final GeneratedColumn<String> dependencyKind = GeneratedColumn<String>(
    'dependency_kind',
    aliasedName,
    false,
    check: () => dependencyKind.isIn(const <String>[
      'task_list',
      'parent_task',
      'previous_task',
    ]),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dependsOnTaskListIdMeta =
      const VerificationMeta('dependsOnTaskListId');
  @override
  late final GeneratedColumn<int> dependsOnTaskListId = GeneratedColumn<int>(
    'depends_on_task_list_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dependsOnTaskIdMeta = const VerificationMeta(
    'dependsOnTaskId',
  );
  @override
  late final GeneratedColumn<int> dependsOnTaskId = GeneratedColumn<int>(
    'depends_on_task_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    desiredStateId,
    dependencyKind,
    dependsOnTaskListId,
    dependsOnTaskId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'desired_state_dependencies';
  @override
  VerificationContext validateIntegrity(
    Insertable<DesiredStateDependencyRow> instance, {
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
    if (data.containsKey('desired_state_id')) {
      context.handle(
        _desiredStateIdMeta,
        desiredStateId.isAcceptableOrUnknown(
          data['desired_state_id']!,
          _desiredStateIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_desiredStateIdMeta);
    }
    if (data.containsKey('dependency_kind')) {
      context.handle(
        _dependencyKindMeta,
        dependencyKind.isAcceptableOrUnknown(
          data['dependency_kind']!,
          _dependencyKindMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_dependencyKindMeta);
    }
    if (data.containsKey('depends_on_task_list_id')) {
      context.handle(
        _dependsOnTaskListIdMeta,
        dependsOnTaskListId.isAcceptableOrUnknown(
          data['depends_on_task_list_id']!,
          _dependsOnTaskListIdMeta,
        ),
      );
    }
    if (data.containsKey('depends_on_task_id')) {
      context.handle(
        _dependsOnTaskIdMeta,
        dependsOnTaskId.isAcceptableOrUnknown(
          data['depends_on_task_id']!,
          _dependsOnTaskIdMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, desiredStateId, dependencyKind},
  ];
  @override
  DesiredStateDependencyRow map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DesiredStateDependencyRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      desiredStateId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}desired_state_id'],
      )!,
      dependencyKind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}dependency_kind'],
      )!,
      dependsOnTaskListId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}depends_on_task_list_id'],
      ),
      dependsOnTaskId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}depends_on_task_id'],
      ),
    );
  }

  @override
  $DesiredStateDependencyRowsTable createAlias(String alias) {
    return $DesiredStateDependencyRowsTable(attachedDatabase, alias);
  }
}

class DesiredStateDependencyRow extends DataClass
    implements Insertable<DesiredStateDependencyRow> {
  final int id;
  final int accountId;
  final int desiredStateId;
  final String dependencyKind;
  final int? dependsOnTaskListId;
  final int? dependsOnTaskId;
  const DesiredStateDependencyRow({
    required this.id,
    required this.accountId,
    required this.desiredStateId,
    required this.dependencyKind,
    this.dependsOnTaskListId,
    this.dependsOnTaskId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['account_id'] = Variable<int>(accountId);
    map['desired_state_id'] = Variable<int>(desiredStateId);
    map['dependency_kind'] = Variable<String>(dependencyKind);
    if (!nullToAbsent || dependsOnTaskListId != null) {
      map['depends_on_task_list_id'] = Variable<int>(dependsOnTaskListId);
    }
    if (!nullToAbsent || dependsOnTaskId != null) {
      map['depends_on_task_id'] = Variable<int>(dependsOnTaskId);
    }
    return map;
  }

  DesiredStateDependencyRowsCompanion toCompanion(bool nullToAbsent) {
    return DesiredStateDependencyRowsCompanion(
      id: Value(id),
      accountId: Value(accountId),
      desiredStateId: Value(desiredStateId),
      dependencyKind: Value(dependencyKind),
      dependsOnTaskListId: dependsOnTaskListId == null && nullToAbsent
          ? const Value.absent()
          : Value(dependsOnTaskListId),
      dependsOnTaskId: dependsOnTaskId == null && nullToAbsent
          ? const Value.absent()
          : Value(dependsOnTaskId),
    );
  }

  factory DesiredStateDependencyRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DesiredStateDependencyRow(
      id: serializer.fromJson<int>(json['id']),
      accountId: serializer.fromJson<int>(json['accountId']),
      desiredStateId: serializer.fromJson<int>(json['desiredStateId']),
      dependencyKind: serializer.fromJson<String>(json['dependencyKind']),
      dependsOnTaskListId: serializer.fromJson<int?>(
        json['dependsOnTaskListId'],
      ),
      dependsOnTaskId: serializer.fromJson<int?>(json['dependsOnTaskId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'accountId': serializer.toJson<int>(accountId),
      'desiredStateId': serializer.toJson<int>(desiredStateId),
      'dependencyKind': serializer.toJson<String>(dependencyKind),
      'dependsOnTaskListId': serializer.toJson<int?>(dependsOnTaskListId),
      'dependsOnTaskId': serializer.toJson<int?>(dependsOnTaskId),
    };
  }

  DesiredStateDependencyRow copyWith({
    int? id,
    int? accountId,
    int? desiredStateId,
    String? dependencyKind,
    Value<int?> dependsOnTaskListId = const Value.absent(),
    Value<int?> dependsOnTaskId = const Value.absent(),
  }) => DesiredStateDependencyRow(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    desiredStateId: desiredStateId ?? this.desiredStateId,
    dependencyKind: dependencyKind ?? this.dependencyKind,
    dependsOnTaskListId: dependsOnTaskListId.present
        ? dependsOnTaskListId.value
        : this.dependsOnTaskListId,
    dependsOnTaskId: dependsOnTaskId.present
        ? dependsOnTaskId.value
        : this.dependsOnTaskId,
  );
  DesiredStateDependencyRow copyWithCompanion(
    DesiredStateDependencyRowsCompanion data,
  ) {
    return DesiredStateDependencyRow(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      desiredStateId: data.desiredStateId.present
          ? data.desiredStateId.value
          : this.desiredStateId,
      dependencyKind: data.dependencyKind.present
          ? data.dependencyKind.value
          : this.dependencyKind,
      dependsOnTaskListId: data.dependsOnTaskListId.present
          ? data.dependsOnTaskListId.value
          : this.dependsOnTaskListId,
      dependsOnTaskId: data.dependsOnTaskId.present
          ? data.dependsOnTaskId.value
          : this.dependsOnTaskId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DesiredStateDependencyRow(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('desiredStateId: $desiredStateId, ')
          ..write('dependencyKind: $dependencyKind, ')
          ..write('dependsOnTaskListId: $dependsOnTaskListId, ')
          ..write('dependsOnTaskId: $dependsOnTaskId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    desiredStateId,
    dependencyKind,
    dependsOnTaskListId,
    dependsOnTaskId,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DesiredStateDependencyRow &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.desiredStateId == this.desiredStateId &&
          other.dependencyKind == this.dependencyKind &&
          other.dependsOnTaskListId == this.dependsOnTaskListId &&
          other.dependsOnTaskId == this.dependsOnTaskId);
}

class DesiredStateDependencyRowsCompanion
    extends UpdateCompanion<DesiredStateDependencyRow> {
  final Value<int> id;
  final Value<int> accountId;
  final Value<int> desiredStateId;
  final Value<String> dependencyKind;
  final Value<int?> dependsOnTaskListId;
  final Value<int?> dependsOnTaskId;
  const DesiredStateDependencyRowsCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.desiredStateId = const Value.absent(),
    this.dependencyKind = const Value.absent(),
    this.dependsOnTaskListId = const Value.absent(),
    this.dependsOnTaskId = const Value.absent(),
  });
  DesiredStateDependencyRowsCompanion.insert({
    this.id = const Value.absent(),
    required int accountId,
    required int desiredStateId,
    required String dependencyKind,
    this.dependsOnTaskListId = const Value.absent(),
    this.dependsOnTaskId = const Value.absent(),
  }) : accountId = Value(accountId),
       desiredStateId = Value(desiredStateId),
       dependencyKind = Value(dependencyKind);
  static Insertable<DesiredStateDependencyRow> custom({
    Expression<int>? id,
    Expression<int>? accountId,
    Expression<int>? desiredStateId,
    Expression<String>? dependencyKind,
    Expression<int>? dependsOnTaskListId,
    Expression<int>? dependsOnTaskId,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (desiredStateId != null) 'desired_state_id': desiredStateId,
      if (dependencyKind != null) 'dependency_kind': dependencyKind,
      if (dependsOnTaskListId != null)
        'depends_on_task_list_id': dependsOnTaskListId,
      if (dependsOnTaskId != null) 'depends_on_task_id': dependsOnTaskId,
    });
  }

  DesiredStateDependencyRowsCompanion copyWith({
    Value<int>? id,
    Value<int>? accountId,
    Value<int>? desiredStateId,
    Value<String>? dependencyKind,
    Value<int?>? dependsOnTaskListId,
    Value<int?>? dependsOnTaskId,
  }) {
    return DesiredStateDependencyRowsCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      desiredStateId: desiredStateId ?? this.desiredStateId,
      dependencyKind: dependencyKind ?? this.dependencyKind,
      dependsOnTaskListId: dependsOnTaskListId ?? this.dependsOnTaskListId,
      dependsOnTaskId: dependsOnTaskId ?? this.dependsOnTaskId,
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
    if (desiredStateId.present) {
      map['desired_state_id'] = Variable<int>(desiredStateId.value);
    }
    if (dependencyKind.present) {
      map['dependency_kind'] = Variable<String>(dependencyKind.value);
    }
    if (dependsOnTaskListId.present) {
      map['depends_on_task_list_id'] = Variable<int>(dependsOnTaskListId.value);
    }
    if (dependsOnTaskId.present) {
      map['depends_on_task_id'] = Variable<int>(dependsOnTaskId.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DesiredStateDependencyRowsCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('desiredStateId: $desiredStateId, ')
          ..write('dependencyKind: $dependencyKind, ')
          ..write('dependsOnTaskListId: $dependsOnTaskListId, ')
          ..write('dependsOnTaskId: $dependsOnTaskId')
          ..write(')'))
        .toString();
  }
}

class $DesiredStateAttemptRowsTable extends DesiredStateAttemptRows
    with TableInfo<$DesiredStateAttemptRowsTable, DesiredStateAttemptRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DesiredStateAttemptRowsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _desiredStateIdMeta = const VerificationMeta(
    'desiredStateId',
  );
  @override
  late final GeneratedColumn<int> desiredStateId = GeneratedColumn<int>(
    'desired_state_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _generationMeta = const VerificationMeta(
    'generation',
  );
  @override
  late final GeneratedColumn<int> generation = GeneratedColumn<int>(
    'generation',
    aliasedName,
    false,
    check: () => ComparableExpr(generation).isBiggerThanValue(0),
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _desiredLifecycleMeta = const VerificationMeta(
    'desiredLifecycle',
  );
  @override
  late final GeneratedColumn<String> desiredLifecycle = GeneratedColumn<String>(
    'desired_lifecycle',
    aliasedName,
    false,
    check: () => desiredLifecycle.isIn(const <String>['present', 'deleted']),
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
  static const VerificationMeta _desiredTaskListIdMeta = const VerificationMeta(
    'desiredTaskListId',
  );
  @override
  late final GeneratedColumn<int> desiredTaskListId = GeneratedColumn<int>(
    'desired_task_list_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _desiredParentTaskIdMeta =
      const VerificationMeta('desiredParentTaskId');
  @override
  late final GeneratedColumn<int> desiredParentTaskId = GeneratedColumn<int>(
    'desired_parent_task_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _desiredPreviousTaskIdMeta =
      const VerificationMeta('desiredPreviousTaskId');
  @override
  late final GeneratedColumn<int> desiredPreviousTaskId = GeneratedColumn<int>(
    'desired_previous_task_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _baseRemoteIdMeta = const VerificationMeta(
    'baseRemoteId',
  );
  @override
  late final GeneratedColumn<String> baseRemoteId = GeneratedColumn<String>(
    'base_remote_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _baseEtagMeta = const VerificationMeta(
    'baseEtag',
  );
  @override
  late final GeneratedColumn<String> baseEtag = GeneratedColumn<String>(
    'base_etag',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _baseRemoteUpdatedAtMeta =
      const VerificationMeta('baseRemoteUpdatedAt');
  @override
  late final GeneratedColumn<DateTime> baseRemoteUpdatedAt =
      GeneratedColumn<DateTime>(
        'base_remote_updated_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _baseObservedPublicationIdMeta =
      const VerificationMeta('baseObservedPublicationId');
  @override
  late final GeneratedColumn<String> baseObservedPublicationId =
      GeneratedColumn<String>(
        'base_observed_publication_id',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _baseTitleMeta = const VerificationMeta(
    'baseTitle',
  );
  @override
  late final GeneratedColumn<String> baseTitle = GeneratedColumn<String>(
    'base_title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _baseTaskListIdMeta = const VerificationMeta(
    'baseTaskListId',
  );
  @override
  late final GeneratedColumn<int> baseTaskListId = GeneratedColumn<int>(
    'base_task_list_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _baseParentTaskIdMeta = const VerificationMeta(
    'baseParentTaskId',
  );
  @override
  late final GeneratedColumn<int> baseParentTaskId = GeneratedColumn<int>(
    'base_parent_task_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _basePreviousTaskIdMeta =
      const VerificationMeta('basePreviousTaskId');
  @override
  late final GeneratedColumn<int> basePreviousTaskId = GeneratedColumn<int>(
    'base_previous_task_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _basePositionMeta = const VerificationMeta(
    'basePosition',
  );
  @override
  late final GeneratedColumn<String> basePosition = GeneratedColumn<String>(
    'base_position',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _baseSiblingOrderMeta = const VerificationMeta(
    'baseSiblingOrder',
  );
  @override
  late final GeneratedColumn<String> baseSiblingOrder = GeneratedColumn<String>(
    'base_sibling_order',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _notBeforeMeta = const VerificationMeta(
    'notBefore',
  );
  @override
  late final GeneratedColumn<DateTime> notBefore = GeneratedColumn<DateTime>(
    'not_before',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
    'state',
    aliasedName,
    false,
    check: () => state.isIn(const <String>[
      'pending',
      'in_flight',
      'uncertain',
      'failed',
      'confirmed',
      'superseded',
    ]),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _failureCodeMeta = const VerificationMeta(
    'failureCode',
  );
  @override
  late final GeneratedColumn<String> failureCode = GeneratedColumn<String>(
    'failure_code',
    aliasedName,
    true,
    check: () =>
        failureCode.isNull() |
        ComparableExpr(failureCode.length).isBiggerThanValue(0),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _claimedAtMeta = const VerificationMeta(
    'claimedAt',
  );
  @override
  late final GeneratedColumn<DateTime> claimedAt = GeneratedColumn<DateTime>(
    'claimed_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastTransitionAtMeta = const VerificationMeta(
    'lastTransitionAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastTransitionAt =
      GeneratedColumn<DateTime>(
        'last_transition_at',
        aliasedName,
        false,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: true,
      );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    desiredStateId,
    generation,
    desiredLifecycle,
    title,
    notes,
    status,
    dueEpochDay,
    desiredTaskListId,
    desiredParentTaskId,
    desiredPreviousTaskId,
    baseRemoteId,
    baseEtag,
    baseRemoteUpdatedAt,
    baseObservedPublicationId,
    baseTitle,
    baseTaskListId,
    baseParentTaskId,
    basePreviousTaskId,
    basePosition,
    baseSiblingOrder,
    notBefore,
    state,
    failureCode,
    claimedAt,
    lastTransitionAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'desired_state_attempts';
  @override
  VerificationContext validateIntegrity(
    Insertable<DesiredStateAttemptRow> instance, {
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
    if (data.containsKey('desired_state_id')) {
      context.handle(
        _desiredStateIdMeta,
        desiredStateId.isAcceptableOrUnknown(
          data['desired_state_id']!,
          _desiredStateIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_desiredStateIdMeta);
    }
    if (data.containsKey('generation')) {
      context.handle(
        _generationMeta,
        generation.isAcceptableOrUnknown(data['generation']!, _generationMeta),
      );
    } else if (isInserting) {
      context.missing(_generationMeta);
    }
    if (data.containsKey('desired_lifecycle')) {
      context.handle(
        _desiredLifecycleMeta,
        desiredLifecycle.isAcceptableOrUnknown(
          data['desired_lifecycle']!,
          _desiredLifecycleMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_desiredLifecycleMeta);
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
    if (data.containsKey('desired_task_list_id')) {
      context.handle(
        _desiredTaskListIdMeta,
        desiredTaskListId.isAcceptableOrUnknown(
          data['desired_task_list_id']!,
          _desiredTaskListIdMeta,
        ),
      );
    }
    if (data.containsKey('desired_parent_task_id')) {
      context.handle(
        _desiredParentTaskIdMeta,
        desiredParentTaskId.isAcceptableOrUnknown(
          data['desired_parent_task_id']!,
          _desiredParentTaskIdMeta,
        ),
      );
    }
    if (data.containsKey('desired_previous_task_id')) {
      context.handle(
        _desiredPreviousTaskIdMeta,
        desiredPreviousTaskId.isAcceptableOrUnknown(
          data['desired_previous_task_id']!,
          _desiredPreviousTaskIdMeta,
        ),
      );
    }
    if (data.containsKey('base_remote_id')) {
      context.handle(
        _baseRemoteIdMeta,
        baseRemoteId.isAcceptableOrUnknown(
          data['base_remote_id']!,
          _baseRemoteIdMeta,
        ),
      );
    }
    if (data.containsKey('base_etag')) {
      context.handle(
        _baseEtagMeta,
        baseEtag.isAcceptableOrUnknown(data['base_etag']!, _baseEtagMeta),
      );
    }
    if (data.containsKey('base_remote_updated_at')) {
      context.handle(
        _baseRemoteUpdatedAtMeta,
        baseRemoteUpdatedAt.isAcceptableOrUnknown(
          data['base_remote_updated_at']!,
          _baseRemoteUpdatedAtMeta,
        ),
      );
    }
    if (data.containsKey('base_observed_publication_id')) {
      context.handle(
        _baseObservedPublicationIdMeta,
        baseObservedPublicationId.isAcceptableOrUnknown(
          data['base_observed_publication_id']!,
          _baseObservedPublicationIdMeta,
        ),
      );
    }
    if (data.containsKey('base_title')) {
      context.handle(
        _baseTitleMeta,
        baseTitle.isAcceptableOrUnknown(data['base_title']!, _baseTitleMeta),
      );
    }
    if (data.containsKey('base_task_list_id')) {
      context.handle(
        _baseTaskListIdMeta,
        baseTaskListId.isAcceptableOrUnknown(
          data['base_task_list_id']!,
          _baseTaskListIdMeta,
        ),
      );
    }
    if (data.containsKey('base_parent_task_id')) {
      context.handle(
        _baseParentTaskIdMeta,
        baseParentTaskId.isAcceptableOrUnknown(
          data['base_parent_task_id']!,
          _baseParentTaskIdMeta,
        ),
      );
    }
    if (data.containsKey('base_previous_task_id')) {
      context.handle(
        _basePreviousTaskIdMeta,
        basePreviousTaskId.isAcceptableOrUnknown(
          data['base_previous_task_id']!,
          _basePreviousTaskIdMeta,
        ),
      );
    }
    if (data.containsKey('base_position')) {
      context.handle(
        _basePositionMeta,
        basePosition.isAcceptableOrUnknown(
          data['base_position']!,
          _basePositionMeta,
        ),
      );
    }
    if (data.containsKey('base_sibling_order')) {
      context.handle(
        _baseSiblingOrderMeta,
        baseSiblingOrder.isAcceptableOrUnknown(
          data['base_sibling_order']!,
          _baseSiblingOrderMeta,
        ),
      );
    }
    if (data.containsKey('not_before')) {
      context.handle(
        _notBeforeMeta,
        notBefore.isAcceptableOrUnknown(data['not_before']!, _notBeforeMeta),
      );
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    } else if (isInserting) {
      context.missing(_stateMeta);
    }
    if (data.containsKey('failure_code')) {
      context.handle(
        _failureCodeMeta,
        failureCode.isAcceptableOrUnknown(
          data['failure_code']!,
          _failureCodeMeta,
        ),
      );
    }
    if (data.containsKey('claimed_at')) {
      context.handle(
        _claimedAtMeta,
        claimedAt.isAcceptableOrUnknown(data['claimed_at']!, _claimedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_claimedAtMeta);
    }
    if (data.containsKey('last_transition_at')) {
      context.handle(
        _lastTransitionAtMeta,
        lastTransitionAt.isAcceptableOrUnknown(
          data['last_transition_at']!,
          _lastTransitionAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_lastTransitionAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, id},
  ];
  @override
  DesiredStateAttemptRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DesiredStateAttemptRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      desiredStateId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}desired_state_id'],
      )!,
      generation: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}generation'],
      )!,
      desiredLifecycle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}desired_lifecycle'],
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
      desiredTaskListId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}desired_task_list_id'],
      ),
      desiredParentTaskId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}desired_parent_task_id'],
      ),
      desiredPreviousTaskId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}desired_previous_task_id'],
      ),
      baseRemoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_remote_id'],
      ),
      baseEtag: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_etag'],
      ),
      baseRemoteUpdatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}base_remote_updated_at'],
      ),
      baseObservedPublicationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_observed_publication_id'],
      ),
      baseTitle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_title'],
      ),
      baseTaskListId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}base_task_list_id'],
      ),
      baseParentTaskId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}base_parent_task_id'],
      ),
      basePreviousTaskId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}base_previous_task_id'],
      ),
      basePosition: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_position'],
      ),
      baseSiblingOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_sibling_order'],
      ),
      notBefore: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}not_before'],
      ),
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state'],
      )!,
      failureCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}failure_code'],
      ),
      claimedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}claimed_at'],
      )!,
      lastTransitionAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_transition_at'],
      )!,
    );
  }

  @override
  $DesiredStateAttemptRowsTable createAlias(String alias) {
    return $DesiredStateAttemptRowsTable(attachedDatabase, alias);
  }
}

class DesiredStateAttemptRow extends DataClass
    implements Insertable<DesiredStateAttemptRow> {
  final int id;
  final int accountId;
  final int desiredStateId;
  final int generation;
  final String desiredLifecycle;
  final String? title;
  final String? notes;
  final String? status;
  final int? dueEpochDay;
  final int? desiredTaskListId;
  final int? desiredParentTaskId;
  final int? desiredPreviousTaskId;
  final String? baseRemoteId;
  final String? baseEtag;
  final DateTime? baseRemoteUpdatedAt;
  final String? baseObservedPublicationId;
  final String? baseTitle;
  final int? baseTaskListId;
  final int? baseParentTaskId;
  final int? basePreviousTaskId;
  final String? basePosition;
  final String? baseSiblingOrder;
  final DateTime? notBefore;
  final String state;
  final String? failureCode;
  final DateTime claimedAt;
  final DateTime lastTransitionAt;
  const DesiredStateAttemptRow({
    required this.id,
    required this.accountId,
    required this.desiredStateId,
    required this.generation,
    required this.desiredLifecycle,
    this.title,
    this.notes,
    this.status,
    this.dueEpochDay,
    this.desiredTaskListId,
    this.desiredParentTaskId,
    this.desiredPreviousTaskId,
    this.baseRemoteId,
    this.baseEtag,
    this.baseRemoteUpdatedAt,
    this.baseObservedPublicationId,
    this.baseTitle,
    this.baseTaskListId,
    this.baseParentTaskId,
    this.basePreviousTaskId,
    this.basePosition,
    this.baseSiblingOrder,
    this.notBefore,
    required this.state,
    this.failureCode,
    required this.claimedAt,
    required this.lastTransitionAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['account_id'] = Variable<int>(accountId);
    map['desired_state_id'] = Variable<int>(desiredStateId);
    map['generation'] = Variable<int>(generation);
    map['desired_lifecycle'] = Variable<String>(desiredLifecycle);
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
    if (!nullToAbsent || desiredTaskListId != null) {
      map['desired_task_list_id'] = Variable<int>(desiredTaskListId);
    }
    if (!nullToAbsent || desiredParentTaskId != null) {
      map['desired_parent_task_id'] = Variable<int>(desiredParentTaskId);
    }
    if (!nullToAbsent || desiredPreviousTaskId != null) {
      map['desired_previous_task_id'] = Variable<int>(desiredPreviousTaskId);
    }
    if (!nullToAbsent || baseRemoteId != null) {
      map['base_remote_id'] = Variable<String>(baseRemoteId);
    }
    if (!nullToAbsent || baseEtag != null) {
      map['base_etag'] = Variable<String>(baseEtag);
    }
    if (!nullToAbsent || baseRemoteUpdatedAt != null) {
      map['base_remote_updated_at'] = Variable<DateTime>(baseRemoteUpdatedAt);
    }
    if (!nullToAbsent || baseObservedPublicationId != null) {
      map['base_observed_publication_id'] = Variable<String>(
        baseObservedPublicationId,
      );
    }
    if (!nullToAbsent || baseTitle != null) {
      map['base_title'] = Variable<String>(baseTitle);
    }
    if (!nullToAbsent || baseTaskListId != null) {
      map['base_task_list_id'] = Variable<int>(baseTaskListId);
    }
    if (!nullToAbsent || baseParentTaskId != null) {
      map['base_parent_task_id'] = Variable<int>(baseParentTaskId);
    }
    if (!nullToAbsent || basePreviousTaskId != null) {
      map['base_previous_task_id'] = Variable<int>(basePreviousTaskId);
    }
    if (!nullToAbsent || basePosition != null) {
      map['base_position'] = Variable<String>(basePosition);
    }
    if (!nullToAbsent || baseSiblingOrder != null) {
      map['base_sibling_order'] = Variable<String>(baseSiblingOrder);
    }
    if (!nullToAbsent || notBefore != null) {
      map['not_before'] = Variable<DateTime>(notBefore);
    }
    map['state'] = Variable<String>(state);
    if (!nullToAbsent || failureCode != null) {
      map['failure_code'] = Variable<String>(failureCode);
    }
    map['claimed_at'] = Variable<DateTime>(claimedAt);
    map['last_transition_at'] = Variable<DateTime>(lastTransitionAt);
    return map;
  }

  DesiredStateAttemptRowsCompanion toCompanion(bool nullToAbsent) {
    return DesiredStateAttemptRowsCompanion(
      id: Value(id),
      accountId: Value(accountId),
      desiredStateId: Value(desiredStateId),
      generation: Value(generation),
      desiredLifecycle: Value(desiredLifecycle),
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
      desiredTaskListId: desiredTaskListId == null && nullToAbsent
          ? const Value.absent()
          : Value(desiredTaskListId),
      desiredParentTaskId: desiredParentTaskId == null && nullToAbsent
          ? const Value.absent()
          : Value(desiredParentTaskId),
      desiredPreviousTaskId: desiredPreviousTaskId == null && nullToAbsent
          ? const Value.absent()
          : Value(desiredPreviousTaskId),
      baseRemoteId: baseRemoteId == null && nullToAbsent
          ? const Value.absent()
          : Value(baseRemoteId),
      baseEtag: baseEtag == null && nullToAbsent
          ? const Value.absent()
          : Value(baseEtag),
      baseRemoteUpdatedAt: baseRemoteUpdatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(baseRemoteUpdatedAt),
      baseObservedPublicationId:
          baseObservedPublicationId == null && nullToAbsent
          ? const Value.absent()
          : Value(baseObservedPublicationId),
      baseTitle: baseTitle == null && nullToAbsent
          ? const Value.absent()
          : Value(baseTitle),
      baseTaskListId: baseTaskListId == null && nullToAbsent
          ? const Value.absent()
          : Value(baseTaskListId),
      baseParentTaskId: baseParentTaskId == null && nullToAbsent
          ? const Value.absent()
          : Value(baseParentTaskId),
      basePreviousTaskId: basePreviousTaskId == null && nullToAbsent
          ? const Value.absent()
          : Value(basePreviousTaskId),
      basePosition: basePosition == null && nullToAbsent
          ? const Value.absent()
          : Value(basePosition),
      baseSiblingOrder: baseSiblingOrder == null && nullToAbsent
          ? const Value.absent()
          : Value(baseSiblingOrder),
      notBefore: notBefore == null && nullToAbsent
          ? const Value.absent()
          : Value(notBefore),
      state: Value(state),
      failureCode: failureCode == null && nullToAbsent
          ? const Value.absent()
          : Value(failureCode),
      claimedAt: Value(claimedAt),
      lastTransitionAt: Value(lastTransitionAt),
    );
  }

  factory DesiredStateAttemptRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DesiredStateAttemptRow(
      id: serializer.fromJson<int>(json['id']),
      accountId: serializer.fromJson<int>(json['accountId']),
      desiredStateId: serializer.fromJson<int>(json['desiredStateId']),
      generation: serializer.fromJson<int>(json['generation']),
      desiredLifecycle: serializer.fromJson<String>(json['desiredLifecycle']),
      title: serializer.fromJson<String?>(json['title']),
      notes: serializer.fromJson<String?>(json['notes']),
      status: serializer.fromJson<String?>(json['status']),
      dueEpochDay: serializer.fromJson<int?>(json['dueEpochDay']),
      desiredTaskListId: serializer.fromJson<int?>(json['desiredTaskListId']),
      desiredParentTaskId: serializer.fromJson<int?>(
        json['desiredParentTaskId'],
      ),
      desiredPreviousTaskId: serializer.fromJson<int?>(
        json['desiredPreviousTaskId'],
      ),
      baseRemoteId: serializer.fromJson<String?>(json['baseRemoteId']),
      baseEtag: serializer.fromJson<String?>(json['baseEtag']),
      baseRemoteUpdatedAt: serializer.fromJson<DateTime?>(
        json['baseRemoteUpdatedAt'],
      ),
      baseObservedPublicationId: serializer.fromJson<String?>(
        json['baseObservedPublicationId'],
      ),
      baseTitle: serializer.fromJson<String?>(json['baseTitle']),
      baseTaskListId: serializer.fromJson<int?>(json['baseTaskListId']),
      baseParentTaskId: serializer.fromJson<int?>(json['baseParentTaskId']),
      basePreviousTaskId: serializer.fromJson<int?>(json['basePreviousTaskId']),
      basePosition: serializer.fromJson<String?>(json['basePosition']),
      baseSiblingOrder: serializer.fromJson<String?>(json['baseSiblingOrder']),
      notBefore: serializer.fromJson<DateTime?>(json['notBefore']),
      state: serializer.fromJson<String>(json['state']),
      failureCode: serializer.fromJson<String?>(json['failureCode']),
      claimedAt: serializer.fromJson<DateTime>(json['claimedAt']),
      lastTransitionAt: serializer.fromJson<DateTime>(json['lastTransitionAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'accountId': serializer.toJson<int>(accountId),
      'desiredStateId': serializer.toJson<int>(desiredStateId),
      'generation': serializer.toJson<int>(generation),
      'desiredLifecycle': serializer.toJson<String>(desiredLifecycle),
      'title': serializer.toJson<String?>(title),
      'notes': serializer.toJson<String?>(notes),
      'status': serializer.toJson<String?>(status),
      'dueEpochDay': serializer.toJson<int?>(dueEpochDay),
      'desiredTaskListId': serializer.toJson<int?>(desiredTaskListId),
      'desiredParentTaskId': serializer.toJson<int?>(desiredParentTaskId),
      'desiredPreviousTaskId': serializer.toJson<int?>(desiredPreviousTaskId),
      'baseRemoteId': serializer.toJson<String?>(baseRemoteId),
      'baseEtag': serializer.toJson<String?>(baseEtag),
      'baseRemoteUpdatedAt': serializer.toJson<DateTime?>(baseRemoteUpdatedAt),
      'baseObservedPublicationId': serializer.toJson<String?>(
        baseObservedPublicationId,
      ),
      'baseTitle': serializer.toJson<String?>(baseTitle),
      'baseTaskListId': serializer.toJson<int?>(baseTaskListId),
      'baseParentTaskId': serializer.toJson<int?>(baseParentTaskId),
      'basePreviousTaskId': serializer.toJson<int?>(basePreviousTaskId),
      'basePosition': serializer.toJson<String?>(basePosition),
      'baseSiblingOrder': serializer.toJson<String?>(baseSiblingOrder),
      'notBefore': serializer.toJson<DateTime?>(notBefore),
      'state': serializer.toJson<String>(state),
      'failureCode': serializer.toJson<String?>(failureCode),
      'claimedAt': serializer.toJson<DateTime>(claimedAt),
      'lastTransitionAt': serializer.toJson<DateTime>(lastTransitionAt),
    };
  }

  DesiredStateAttemptRow copyWith({
    int? id,
    int? accountId,
    int? desiredStateId,
    int? generation,
    String? desiredLifecycle,
    Value<String?> title = const Value.absent(),
    Value<String?> notes = const Value.absent(),
    Value<String?> status = const Value.absent(),
    Value<int?> dueEpochDay = const Value.absent(),
    Value<int?> desiredTaskListId = const Value.absent(),
    Value<int?> desiredParentTaskId = const Value.absent(),
    Value<int?> desiredPreviousTaskId = const Value.absent(),
    Value<String?> baseRemoteId = const Value.absent(),
    Value<String?> baseEtag = const Value.absent(),
    Value<DateTime?> baseRemoteUpdatedAt = const Value.absent(),
    Value<String?> baseObservedPublicationId = const Value.absent(),
    Value<String?> baseTitle = const Value.absent(),
    Value<int?> baseTaskListId = const Value.absent(),
    Value<int?> baseParentTaskId = const Value.absent(),
    Value<int?> basePreviousTaskId = const Value.absent(),
    Value<String?> basePosition = const Value.absent(),
    Value<String?> baseSiblingOrder = const Value.absent(),
    Value<DateTime?> notBefore = const Value.absent(),
    String? state,
    Value<String?> failureCode = const Value.absent(),
    DateTime? claimedAt,
    DateTime? lastTransitionAt,
  }) => DesiredStateAttemptRow(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    desiredStateId: desiredStateId ?? this.desiredStateId,
    generation: generation ?? this.generation,
    desiredLifecycle: desiredLifecycle ?? this.desiredLifecycle,
    title: title.present ? title.value : this.title,
    notes: notes.present ? notes.value : this.notes,
    status: status.present ? status.value : this.status,
    dueEpochDay: dueEpochDay.present ? dueEpochDay.value : this.dueEpochDay,
    desiredTaskListId: desiredTaskListId.present
        ? desiredTaskListId.value
        : this.desiredTaskListId,
    desiredParentTaskId: desiredParentTaskId.present
        ? desiredParentTaskId.value
        : this.desiredParentTaskId,
    desiredPreviousTaskId: desiredPreviousTaskId.present
        ? desiredPreviousTaskId.value
        : this.desiredPreviousTaskId,
    baseRemoteId: baseRemoteId.present ? baseRemoteId.value : this.baseRemoteId,
    baseEtag: baseEtag.present ? baseEtag.value : this.baseEtag,
    baseRemoteUpdatedAt: baseRemoteUpdatedAt.present
        ? baseRemoteUpdatedAt.value
        : this.baseRemoteUpdatedAt,
    baseObservedPublicationId: baseObservedPublicationId.present
        ? baseObservedPublicationId.value
        : this.baseObservedPublicationId,
    baseTitle: baseTitle.present ? baseTitle.value : this.baseTitle,
    baseTaskListId: baseTaskListId.present
        ? baseTaskListId.value
        : this.baseTaskListId,
    baseParentTaskId: baseParentTaskId.present
        ? baseParentTaskId.value
        : this.baseParentTaskId,
    basePreviousTaskId: basePreviousTaskId.present
        ? basePreviousTaskId.value
        : this.basePreviousTaskId,
    basePosition: basePosition.present ? basePosition.value : this.basePosition,
    baseSiblingOrder: baseSiblingOrder.present
        ? baseSiblingOrder.value
        : this.baseSiblingOrder,
    notBefore: notBefore.present ? notBefore.value : this.notBefore,
    state: state ?? this.state,
    failureCode: failureCode.present ? failureCode.value : this.failureCode,
    claimedAt: claimedAt ?? this.claimedAt,
    lastTransitionAt: lastTransitionAt ?? this.lastTransitionAt,
  );
  DesiredStateAttemptRow copyWithCompanion(
    DesiredStateAttemptRowsCompanion data,
  ) {
    return DesiredStateAttemptRow(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      desiredStateId: data.desiredStateId.present
          ? data.desiredStateId.value
          : this.desiredStateId,
      generation: data.generation.present
          ? data.generation.value
          : this.generation,
      desiredLifecycle: data.desiredLifecycle.present
          ? data.desiredLifecycle.value
          : this.desiredLifecycle,
      title: data.title.present ? data.title.value : this.title,
      notes: data.notes.present ? data.notes.value : this.notes,
      status: data.status.present ? data.status.value : this.status,
      dueEpochDay: data.dueEpochDay.present
          ? data.dueEpochDay.value
          : this.dueEpochDay,
      desiredTaskListId: data.desiredTaskListId.present
          ? data.desiredTaskListId.value
          : this.desiredTaskListId,
      desiredParentTaskId: data.desiredParentTaskId.present
          ? data.desiredParentTaskId.value
          : this.desiredParentTaskId,
      desiredPreviousTaskId: data.desiredPreviousTaskId.present
          ? data.desiredPreviousTaskId.value
          : this.desiredPreviousTaskId,
      baseRemoteId: data.baseRemoteId.present
          ? data.baseRemoteId.value
          : this.baseRemoteId,
      baseEtag: data.baseEtag.present ? data.baseEtag.value : this.baseEtag,
      baseRemoteUpdatedAt: data.baseRemoteUpdatedAt.present
          ? data.baseRemoteUpdatedAt.value
          : this.baseRemoteUpdatedAt,
      baseObservedPublicationId: data.baseObservedPublicationId.present
          ? data.baseObservedPublicationId.value
          : this.baseObservedPublicationId,
      baseTitle: data.baseTitle.present ? data.baseTitle.value : this.baseTitle,
      baseTaskListId: data.baseTaskListId.present
          ? data.baseTaskListId.value
          : this.baseTaskListId,
      baseParentTaskId: data.baseParentTaskId.present
          ? data.baseParentTaskId.value
          : this.baseParentTaskId,
      basePreviousTaskId: data.basePreviousTaskId.present
          ? data.basePreviousTaskId.value
          : this.basePreviousTaskId,
      basePosition: data.basePosition.present
          ? data.basePosition.value
          : this.basePosition,
      baseSiblingOrder: data.baseSiblingOrder.present
          ? data.baseSiblingOrder.value
          : this.baseSiblingOrder,
      notBefore: data.notBefore.present ? data.notBefore.value : this.notBefore,
      state: data.state.present ? data.state.value : this.state,
      failureCode: data.failureCode.present
          ? data.failureCode.value
          : this.failureCode,
      claimedAt: data.claimedAt.present ? data.claimedAt.value : this.claimedAt,
      lastTransitionAt: data.lastTransitionAt.present
          ? data.lastTransitionAt.value
          : this.lastTransitionAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DesiredStateAttemptRow(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('desiredStateId: $desiredStateId, ')
          ..write('generation: $generation, ')
          ..write('desiredLifecycle: $desiredLifecycle, ')
          ..write('title: $title, ')
          ..write('notes: $notes, ')
          ..write('status: $status, ')
          ..write('dueEpochDay: $dueEpochDay, ')
          ..write('desiredTaskListId: $desiredTaskListId, ')
          ..write('desiredParentTaskId: $desiredParentTaskId, ')
          ..write('desiredPreviousTaskId: $desiredPreviousTaskId, ')
          ..write('baseRemoteId: $baseRemoteId, ')
          ..write('baseEtag: $baseEtag, ')
          ..write('baseRemoteUpdatedAt: $baseRemoteUpdatedAt, ')
          ..write('baseObservedPublicationId: $baseObservedPublicationId, ')
          ..write('baseTitle: $baseTitle, ')
          ..write('baseTaskListId: $baseTaskListId, ')
          ..write('baseParentTaskId: $baseParentTaskId, ')
          ..write('basePreviousTaskId: $basePreviousTaskId, ')
          ..write('basePosition: $basePosition, ')
          ..write('baseSiblingOrder: $baseSiblingOrder, ')
          ..write('notBefore: $notBefore, ')
          ..write('state: $state, ')
          ..write('failureCode: $failureCode, ')
          ..write('claimedAt: $claimedAt, ')
          ..write('lastTransitionAt: $lastTransitionAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    accountId,
    desiredStateId,
    generation,
    desiredLifecycle,
    title,
    notes,
    status,
    dueEpochDay,
    desiredTaskListId,
    desiredParentTaskId,
    desiredPreviousTaskId,
    baseRemoteId,
    baseEtag,
    baseRemoteUpdatedAt,
    baseObservedPublicationId,
    baseTitle,
    baseTaskListId,
    baseParentTaskId,
    basePreviousTaskId,
    basePosition,
    baseSiblingOrder,
    notBefore,
    state,
    failureCode,
    claimedAt,
    lastTransitionAt,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DesiredStateAttemptRow &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.desiredStateId == this.desiredStateId &&
          other.generation == this.generation &&
          other.desiredLifecycle == this.desiredLifecycle &&
          other.title == this.title &&
          other.notes == this.notes &&
          other.status == this.status &&
          other.dueEpochDay == this.dueEpochDay &&
          other.desiredTaskListId == this.desiredTaskListId &&
          other.desiredParentTaskId == this.desiredParentTaskId &&
          other.desiredPreviousTaskId == this.desiredPreviousTaskId &&
          other.baseRemoteId == this.baseRemoteId &&
          other.baseEtag == this.baseEtag &&
          other.baseRemoteUpdatedAt == this.baseRemoteUpdatedAt &&
          other.baseObservedPublicationId == this.baseObservedPublicationId &&
          other.baseTitle == this.baseTitle &&
          other.baseTaskListId == this.baseTaskListId &&
          other.baseParentTaskId == this.baseParentTaskId &&
          other.basePreviousTaskId == this.basePreviousTaskId &&
          other.basePosition == this.basePosition &&
          other.baseSiblingOrder == this.baseSiblingOrder &&
          other.notBefore == this.notBefore &&
          other.state == this.state &&
          other.failureCode == this.failureCode &&
          other.claimedAt == this.claimedAt &&
          other.lastTransitionAt == this.lastTransitionAt);
}

class DesiredStateAttemptRowsCompanion
    extends UpdateCompanion<DesiredStateAttemptRow> {
  final Value<int> id;
  final Value<int> accountId;
  final Value<int> desiredStateId;
  final Value<int> generation;
  final Value<String> desiredLifecycle;
  final Value<String?> title;
  final Value<String?> notes;
  final Value<String?> status;
  final Value<int?> dueEpochDay;
  final Value<int?> desiredTaskListId;
  final Value<int?> desiredParentTaskId;
  final Value<int?> desiredPreviousTaskId;
  final Value<String?> baseRemoteId;
  final Value<String?> baseEtag;
  final Value<DateTime?> baseRemoteUpdatedAt;
  final Value<String?> baseObservedPublicationId;
  final Value<String?> baseTitle;
  final Value<int?> baseTaskListId;
  final Value<int?> baseParentTaskId;
  final Value<int?> basePreviousTaskId;
  final Value<String?> basePosition;
  final Value<String?> baseSiblingOrder;
  final Value<DateTime?> notBefore;
  final Value<String> state;
  final Value<String?> failureCode;
  final Value<DateTime> claimedAt;
  final Value<DateTime> lastTransitionAt;
  const DesiredStateAttemptRowsCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.desiredStateId = const Value.absent(),
    this.generation = const Value.absent(),
    this.desiredLifecycle = const Value.absent(),
    this.title = const Value.absent(),
    this.notes = const Value.absent(),
    this.status = const Value.absent(),
    this.dueEpochDay = const Value.absent(),
    this.desiredTaskListId = const Value.absent(),
    this.desiredParentTaskId = const Value.absent(),
    this.desiredPreviousTaskId = const Value.absent(),
    this.baseRemoteId = const Value.absent(),
    this.baseEtag = const Value.absent(),
    this.baseRemoteUpdatedAt = const Value.absent(),
    this.baseObservedPublicationId = const Value.absent(),
    this.baseTitle = const Value.absent(),
    this.baseTaskListId = const Value.absent(),
    this.baseParentTaskId = const Value.absent(),
    this.basePreviousTaskId = const Value.absent(),
    this.basePosition = const Value.absent(),
    this.baseSiblingOrder = const Value.absent(),
    this.notBefore = const Value.absent(),
    this.state = const Value.absent(),
    this.failureCode = const Value.absent(),
    this.claimedAt = const Value.absent(),
    this.lastTransitionAt = const Value.absent(),
  });
  DesiredStateAttemptRowsCompanion.insert({
    this.id = const Value.absent(),
    required int accountId,
    required int desiredStateId,
    required int generation,
    required String desiredLifecycle,
    this.title = const Value.absent(),
    this.notes = const Value.absent(),
    this.status = const Value.absent(),
    this.dueEpochDay = const Value.absent(),
    this.desiredTaskListId = const Value.absent(),
    this.desiredParentTaskId = const Value.absent(),
    this.desiredPreviousTaskId = const Value.absent(),
    this.baseRemoteId = const Value.absent(),
    this.baseEtag = const Value.absent(),
    this.baseRemoteUpdatedAt = const Value.absent(),
    this.baseObservedPublicationId = const Value.absent(),
    this.baseTitle = const Value.absent(),
    this.baseTaskListId = const Value.absent(),
    this.baseParentTaskId = const Value.absent(),
    this.basePreviousTaskId = const Value.absent(),
    this.basePosition = const Value.absent(),
    this.baseSiblingOrder = const Value.absent(),
    this.notBefore = const Value.absent(),
    required String state,
    this.failureCode = const Value.absent(),
    required DateTime claimedAt,
    required DateTime lastTransitionAt,
  }) : accountId = Value(accountId),
       desiredStateId = Value(desiredStateId),
       generation = Value(generation),
       desiredLifecycle = Value(desiredLifecycle),
       state = Value(state),
       claimedAt = Value(claimedAt),
       lastTransitionAt = Value(lastTransitionAt);
  static Insertable<DesiredStateAttemptRow> custom({
    Expression<int>? id,
    Expression<int>? accountId,
    Expression<int>? desiredStateId,
    Expression<int>? generation,
    Expression<String>? desiredLifecycle,
    Expression<String>? title,
    Expression<String>? notes,
    Expression<String>? status,
    Expression<int>? dueEpochDay,
    Expression<int>? desiredTaskListId,
    Expression<int>? desiredParentTaskId,
    Expression<int>? desiredPreviousTaskId,
    Expression<String>? baseRemoteId,
    Expression<String>? baseEtag,
    Expression<DateTime>? baseRemoteUpdatedAt,
    Expression<String>? baseObservedPublicationId,
    Expression<String>? baseTitle,
    Expression<int>? baseTaskListId,
    Expression<int>? baseParentTaskId,
    Expression<int>? basePreviousTaskId,
    Expression<String>? basePosition,
    Expression<String>? baseSiblingOrder,
    Expression<DateTime>? notBefore,
    Expression<String>? state,
    Expression<String>? failureCode,
    Expression<DateTime>? claimedAt,
    Expression<DateTime>? lastTransitionAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (desiredStateId != null) 'desired_state_id': desiredStateId,
      if (generation != null) 'generation': generation,
      if (desiredLifecycle != null) 'desired_lifecycle': desiredLifecycle,
      if (title != null) 'title': title,
      if (notes != null) 'notes': notes,
      if (status != null) 'status': status,
      if (dueEpochDay != null) 'due_epoch_day': dueEpochDay,
      if (desiredTaskListId != null) 'desired_task_list_id': desiredTaskListId,
      if (desiredParentTaskId != null)
        'desired_parent_task_id': desiredParentTaskId,
      if (desiredPreviousTaskId != null)
        'desired_previous_task_id': desiredPreviousTaskId,
      if (baseRemoteId != null) 'base_remote_id': baseRemoteId,
      if (baseEtag != null) 'base_etag': baseEtag,
      if (baseRemoteUpdatedAt != null)
        'base_remote_updated_at': baseRemoteUpdatedAt,
      if (baseObservedPublicationId != null)
        'base_observed_publication_id': baseObservedPublicationId,
      if (baseTitle != null) 'base_title': baseTitle,
      if (baseTaskListId != null) 'base_task_list_id': baseTaskListId,
      if (baseParentTaskId != null) 'base_parent_task_id': baseParentTaskId,
      if (basePreviousTaskId != null)
        'base_previous_task_id': basePreviousTaskId,
      if (basePosition != null) 'base_position': basePosition,
      if (baseSiblingOrder != null) 'base_sibling_order': baseSiblingOrder,
      if (notBefore != null) 'not_before': notBefore,
      if (state != null) 'state': state,
      if (failureCode != null) 'failure_code': failureCode,
      if (claimedAt != null) 'claimed_at': claimedAt,
      if (lastTransitionAt != null) 'last_transition_at': lastTransitionAt,
    });
  }

  DesiredStateAttemptRowsCompanion copyWith({
    Value<int>? id,
    Value<int>? accountId,
    Value<int>? desiredStateId,
    Value<int>? generation,
    Value<String>? desiredLifecycle,
    Value<String?>? title,
    Value<String?>? notes,
    Value<String?>? status,
    Value<int?>? dueEpochDay,
    Value<int?>? desiredTaskListId,
    Value<int?>? desiredParentTaskId,
    Value<int?>? desiredPreviousTaskId,
    Value<String?>? baseRemoteId,
    Value<String?>? baseEtag,
    Value<DateTime?>? baseRemoteUpdatedAt,
    Value<String?>? baseObservedPublicationId,
    Value<String?>? baseTitle,
    Value<int?>? baseTaskListId,
    Value<int?>? baseParentTaskId,
    Value<int?>? basePreviousTaskId,
    Value<String?>? basePosition,
    Value<String?>? baseSiblingOrder,
    Value<DateTime?>? notBefore,
    Value<String>? state,
    Value<String?>? failureCode,
    Value<DateTime>? claimedAt,
    Value<DateTime>? lastTransitionAt,
  }) {
    return DesiredStateAttemptRowsCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      desiredStateId: desiredStateId ?? this.desiredStateId,
      generation: generation ?? this.generation,
      desiredLifecycle: desiredLifecycle ?? this.desiredLifecycle,
      title: title ?? this.title,
      notes: notes ?? this.notes,
      status: status ?? this.status,
      dueEpochDay: dueEpochDay ?? this.dueEpochDay,
      desiredTaskListId: desiredTaskListId ?? this.desiredTaskListId,
      desiredParentTaskId: desiredParentTaskId ?? this.desiredParentTaskId,
      desiredPreviousTaskId:
          desiredPreviousTaskId ?? this.desiredPreviousTaskId,
      baseRemoteId: baseRemoteId ?? this.baseRemoteId,
      baseEtag: baseEtag ?? this.baseEtag,
      baseRemoteUpdatedAt: baseRemoteUpdatedAt ?? this.baseRemoteUpdatedAt,
      baseObservedPublicationId:
          baseObservedPublicationId ?? this.baseObservedPublicationId,
      baseTitle: baseTitle ?? this.baseTitle,
      baseTaskListId: baseTaskListId ?? this.baseTaskListId,
      baseParentTaskId: baseParentTaskId ?? this.baseParentTaskId,
      basePreviousTaskId: basePreviousTaskId ?? this.basePreviousTaskId,
      basePosition: basePosition ?? this.basePosition,
      baseSiblingOrder: baseSiblingOrder ?? this.baseSiblingOrder,
      notBefore: notBefore ?? this.notBefore,
      state: state ?? this.state,
      failureCode: failureCode ?? this.failureCode,
      claimedAt: claimedAt ?? this.claimedAt,
      lastTransitionAt: lastTransitionAt ?? this.lastTransitionAt,
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
    if (desiredStateId.present) {
      map['desired_state_id'] = Variable<int>(desiredStateId.value);
    }
    if (generation.present) {
      map['generation'] = Variable<int>(generation.value);
    }
    if (desiredLifecycle.present) {
      map['desired_lifecycle'] = Variable<String>(desiredLifecycle.value);
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
    if (desiredTaskListId.present) {
      map['desired_task_list_id'] = Variable<int>(desiredTaskListId.value);
    }
    if (desiredParentTaskId.present) {
      map['desired_parent_task_id'] = Variable<int>(desiredParentTaskId.value);
    }
    if (desiredPreviousTaskId.present) {
      map['desired_previous_task_id'] = Variable<int>(
        desiredPreviousTaskId.value,
      );
    }
    if (baseRemoteId.present) {
      map['base_remote_id'] = Variable<String>(baseRemoteId.value);
    }
    if (baseEtag.present) {
      map['base_etag'] = Variable<String>(baseEtag.value);
    }
    if (baseRemoteUpdatedAt.present) {
      map['base_remote_updated_at'] = Variable<DateTime>(
        baseRemoteUpdatedAt.value,
      );
    }
    if (baseObservedPublicationId.present) {
      map['base_observed_publication_id'] = Variable<String>(
        baseObservedPublicationId.value,
      );
    }
    if (baseTitle.present) {
      map['base_title'] = Variable<String>(baseTitle.value);
    }
    if (baseTaskListId.present) {
      map['base_task_list_id'] = Variable<int>(baseTaskListId.value);
    }
    if (baseParentTaskId.present) {
      map['base_parent_task_id'] = Variable<int>(baseParentTaskId.value);
    }
    if (basePreviousTaskId.present) {
      map['base_previous_task_id'] = Variable<int>(basePreviousTaskId.value);
    }
    if (basePosition.present) {
      map['base_position'] = Variable<String>(basePosition.value);
    }
    if (baseSiblingOrder.present) {
      map['base_sibling_order'] = Variable<String>(baseSiblingOrder.value);
    }
    if (notBefore.present) {
      map['not_before'] = Variable<DateTime>(notBefore.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (failureCode.present) {
      map['failure_code'] = Variable<String>(failureCode.value);
    }
    if (claimedAt.present) {
      map['claimed_at'] = Variable<DateTime>(claimedAt.value);
    }
    if (lastTransitionAt.present) {
      map['last_transition_at'] = Variable<DateTime>(lastTransitionAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DesiredStateAttemptRowsCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('desiredStateId: $desiredStateId, ')
          ..write('generation: $generation, ')
          ..write('desiredLifecycle: $desiredLifecycle, ')
          ..write('title: $title, ')
          ..write('notes: $notes, ')
          ..write('status: $status, ')
          ..write('dueEpochDay: $dueEpochDay, ')
          ..write('desiredTaskListId: $desiredTaskListId, ')
          ..write('desiredParentTaskId: $desiredParentTaskId, ')
          ..write('desiredPreviousTaskId: $desiredPreviousTaskId, ')
          ..write('baseRemoteId: $baseRemoteId, ')
          ..write('baseEtag: $baseEtag, ')
          ..write('baseRemoteUpdatedAt: $baseRemoteUpdatedAt, ')
          ..write('baseObservedPublicationId: $baseObservedPublicationId, ')
          ..write('baseTitle: $baseTitle, ')
          ..write('baseTaskListId: $baseTaskListId, ')
          ..write('baseParentTaskId: $baseParentTaskId, ')
          ..write('basePreviousTaskId: $basePreviousTaskId, ')
          ..write('basePosition: $basePosition, ')
          ..write('baseSiblingOrder: $baseSiblingOrder, ')
          ..write('notBefore: $notBefore, ')
          ..write('state: $state, ')
          ..write('failureCode: $failureCode, ')
          ..write('claimedAt: $claimedAt, ')
          ..write('lastTransitionAt: $lastTransitionAt')
          ..write(')'))
        .toString();
  }
}

class $SyncRunRowsTable extends SyncRunRows
    with TableInfo<$SyncRunRowsTable, SyncRunRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncRunRowsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _runIdMeta = const VerificationMeta('runId');
  @override
  late final GeneratedColumn<String> runId = GeneratedColumn<String>(
    'run_id',
    aliasedName,
    false,
    check: () => ComparableExpr(runId.length).isBiggerThanValue(0),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _triggersJsonMeta = const VerificationMeta(
    'triggersJson',
  );
  @override
  late final GeneratedColumn<String> triggersJson = GeneratedColumn<String>(
    'triggers_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
    'state',
    aliasedName,
    false,
    check: () => state.isIn(const <String>[
      'in_progress',
      'interrupted',
      'succeeded',
      'failed',
    ]),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _startedAtMeta = const VerificationMeta(
    'startedAt',
  );
  @override
  late final GeneratedColumn<DateTime> startedAt = GeneratedColumn<DateTime>(
    'started_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _finishedAtMeta = const VerificationMeta(
    'finishedAt',
  );
  @override
  late final GeneratedColumn<DateTime> finishedAt = GeneratedColumn<DateTime>(
    'finished_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _failureCodeMeta = const VerificationMeta(
    'failureCode',
  );
  @override
  late final GeneratedColumn<String> failureCode = GeneratedColumn<String>(
    'failure_code',
    aliasedName,
    true,
    check: () =>
        failureCode.isNull() |
        ComparableExpr(failureCode.length).isBiggerThanValue(0),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    runId,
    triggersJson,
    state,
    startedAt,
    finishedAt,
    failureCode,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_runs';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncRunRow> instance, {
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
    if (data.containsKey('run_id')) {
      context.handle(
        _runIdMeta,
        runId.isAcceptableOrUnknown(data['run_id']!, _runIdMeta),
      );
    } else if (isInserting) {
      context.missing(_runIdMeta);
    }
    if (data.containsKey('triggers_json')) {
      context.handle(
        _triggersJsonMeta,
        triggersJson.isAcceptableOrUnknown(
          data['triggers_json']!,
          _triggersJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_triggersJsonMeta);
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    } else if (isInserting) {
      context.missing(_stateMeta);
    }
    if (data.containsKey('started_at')) {
      context.handle(
        _startedAtMeta,
        startedAt.isAcceptableOrUnknown(data['started_at']!, _startedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_startedAtMeta);
    }
    if (data.containsKey('finished_at')) {
      context.handle(
        _finishedAtMeta,
        finishedAt.isAcceptableOrUnknown(data['finished_at']!, _finishedAtMeta),
      );
    }
    if (data.containsKey('failure_code')) {
      context.handle(
        _failureCodeMeta,
        failureCode.isAcceptableOrUnknown(
          data['failure_code']!,
          _failureCodeMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId, runId};
  @override
  SyncRunRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncRunRow(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      runId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}run_id'],
      )!,
      triggersJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}triggers_json'],
      )!,
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state'],
      )!,
      startedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}started_at'],
      )!,
      finishedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}finished_at'],
      ),
      failureCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}failure_code'],
      ),
    );
  }

  @override
  $SyncRunRowsTable createAlias(String alias) {
    return $SyncRunRowsTable(attachedDatabase, alias);
  }
}

class SyncRunRow extends DataClass implements Insertable<SyncRunRow> {
  final int accountId;
  final String runId;
  final String triggersJson;
  final String state;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final String? failureCode;
  const SyncRunRow({
    required this.accountId,
    required this.runId,
    required this.triggersJson,
    required this.state,
    required this.startedAt,
    this.finishedAt,
    this.failureCode,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<int>(accountId);
    map['run_id'] = Variable<String>(runId);
    map['triggers_json'] = Variable<String>(triggersJson);
    map['state'] = Variable<String>(state);
    map['started_at'] = Variable<DateTime>(startedAt);
    if (!nullToAbsent || finishedAt != null) {
      map['finished_at'] = Variable<DateTime>(finishedAt);
    }
    if (!nullToAbsent || failureCode != null) {
      map['failure_code'] = Variable<String>(failureCode);
    }
    return map;
  }

  SyncRunRowsCompanion toCompanion(bool nullToAbsent) {
    return SyncRunRowsCompanion(
      accountId: Value(accountId),
      runId: Value(runId),
      triggersJson: Value(triggersJson),
      state: Value(state),
      startedAt: Value(startedAt),
      finishedAt: finishedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(finishedAt),
      failureCode: failureCode == null && nullToAbsent
          ? const Value.absent()
          : Value(failureCode),
    );
  }

  factory SyncRunRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncRunRow(
      accountId: serializer.fromJson<int>(json['accountId']),
      runId: serializer.fromJson<String>(json['runId']),
      triggersJson: serializer.fromJson<String>(json['triggersJson']),
      state: serializer.fromJson<String>(json['state']),
      startedAt: serializer.fromJson<DateTime>(json['startedAt']),
      finishedAt: serializer.fromJson<DateTime?>(json['finishedAt']),
      failureCode: serializer.fromJson<String?>(json['failureCode']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<int>(accountId),
      'runId': serializer.toJson<String>(runId),
      'triggersJson': serializer.toJson<String>(triggersJson),
      'state': serializer.toJson<String>(state),
      'startedAt': serializer.toJson<DateTime>(startedAt),
      'finishedAt': serializer.toJson<DateTime?>(finishedAt),
      'failureCode': serializer.toJson<String?>(failureCode),
    };
  }

  SyncRunRow copyWith({
    int? accountId,
    String? runId,
    String? triggersJson,
    String? state,
    DateTime? startedAt,
    Value<DateTime?> finishedAt = const Value.absent(),
    Value<String?> failureCode = const Value.absent(),
  }) => SyncRunRow(
    accountId: accountId ?? this.accountId,
    runId: runId ?? this.runId,
    triggersJson: triggersJson ?? this.triggersJson,
    state: state ?? this.state,
    startedAt: startedAt ?? this.startedAt,
    finishedAt: finishedAt.present ? finishedAt.value : this.finishedAt,
    failureCode: failureCode.present ? failureCode.value : this.failureCode,
  );
  SyncRunRow copyWithCompanion(SyncRunRowsCompanion data) {
    return SyncRunRow(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      runId: data.runId.present ? data.runId.value : this.runId,
      triggersJson: data.triggersJson.present
          ? data.triggersJson.value
          : this.triggersJson,
      state: data.state.present ? data.state.value : this.state,
      startedAt: data.startedAt.present ? data.startedAt.value : this.startedAt,
      finishedAt: data.finishedAt.present
          ? data.finishedAt.value
          : this.finishedAt,
      failureCode: data.failureCode.present
          ? data.failureCode.value
          : this.failureCode,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncRunRow(')
          ..write('accountId: $accountId, ')
          ..write('runId: $runId, ')
          ..write('triggersJson: $triggersJson, ')
          ..write('state: $state, ')
          ..write('startedAt: $startedAt, ')
          ..write('finishedAt: $finishedAt, ')
          ..write('failureCode: $failureCode')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    accountId,
    runId,
    triggersJson,
    state,
    startedAt,
    finishedAt,
    failureCode,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncRunRow &&
          other.accountId == this.accountId &&
          other.runId == this.runId &&
          other.triggersJson == this.triggersJson &&
          other.state == this.state &&
          other.startedAt == this.startedAt &&
          other.finishedAt == this.finishedAt &&
          other.failureCode == this.failureCode);
}

class SyncRunRowsCompanion extends UpdateCompanion<SyncRunRow> {
  final Value<int> accountId;
  final Value<String> runId;
  final Value<String> triggersJson;
  final Value<String> state;
  final Value<DateTime> startedAt;
  final Value<DateTime?> finishedAt;
  final Value<String?> failureCode;
  final Value<int> rowid;
  const SyncRunRowsCompanion({
    this.accountId = const Value.absent(),
    this.runId = const Value.absent(),
    this.triggersJson = const Value.absent(),
    this.state = const Value.absent(),
    this.startedAt = const Value.absent(),
    this.finishedAt = const Value.absent(),
    this.failureCode = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncRunRowsCompanion.insert({
    required int accountId,
    required String runId,
    required String triggersJson,
    required String state,
    required DateTime startedAt,
    this.finishedAt = const Value.absent(),
    this.failureCode = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       runId = Value(runId),
       triggersJson = Value(triggersJson),
       state = Value(state),
       startedAt = Value(startedAt);
  static Insertable<SyncRunRow> custom({
    Expression<int>? accountId,
    Expression<String>? runId,
    Expression<String>? triggersJson,
    Expression<String>? state,
    Expression<DateTime>? startedAt,
    Expression<DateTime>? finishedAt,
    Expression<String>? failureCode,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (runId != null) 'run_id': runId,
      if (triggersJson != null) 'triggers_json': triggersJson,
      if (state != null) 'state': state,
      if (startedAt != null) 'started_at': startedAt,
      if (finishedAt != null) 'finished_at': finishedAt,
      if (failureCode != null) 'failure_code': failureCode,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncRunRowsCompanion copyWith({
    Value<int>? accountId,
    Value<String>? runId,
    Value<String>? triggersJson,
    Value<String>? state,
    Value<DateTime>? startedAt,
    Value<DateTime?>? finishedAt,
    Value<String?>? failureCode,
    Value<int>? rowid,
  }) {
    return SyncRunRowsCompanion(
      accountId: accountId ?? this.accountId,
      runId: runId ?? this.runId,
      triggersJson: triggersJson ?? this.triggersJson,
      state: state ?? this.state,
      startedAt: startedAt ?? this.startedAt,
      finishedAt: finishedAt ?? this.finishedAt,
      failureCode: failureCode ?? this.failureCode,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (runId.present) {
      map['run_id'] = Variable<String>(runId.value);
    }
    if (triggersJson.present) {
      map['triggers_json'] = Variable<String>(triggersJson.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (startedAt.present) {
      map['started_at'] = Variable<DateTime>(startedAt.value);
    }
    if (finishedAt.present) {
      map['finished_at'] = Variable<DateTime>(finishedAt.value);
    }
    if (failureCode.present) {
      map['failure_code'] = Variable<String>(failureCode.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncRunRowsCompanion(')
          ..write('accountId: $accountId, ')
          ..write('runId: $runId, ')
          ..write('triggersJson: $triggersJson, ')
          ..write('state: $state, ')
          ..write('startedAt: $startedAt, ')
          ..write('finishedAt: $finishedAt, ')
          ..write('failureCode: $failureCode, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TaskDeleteTombstoneRowsTable extends TaskDeleteTombstoneRows
    with TableInfo<$TaskDeleteTombstoneRowsTable, TaskDeleteTombstoneRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TaskDeleteTombstoneRowsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _rootTaskIdMeta = const VerificationMeta(
    'rootTaskId',
  );
  @override
  late final GeneratedColumn<int> rootTaskId = GeneratedColumn<int>(
    'root_task_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _desiredStateIdMeta = const VerificationMeta(
    'desiredStateId',
  );
  @override
  late final GeneratedColumn<int> desiredStateId = GeneratedColumn<int>(
    'desired_state_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deleteGenerationMeta = const VerificationMeta(
    'deleteGeneration',
  );
  @override
  late final GeneratedColumn<int> deleteGeneration = GeneratedColumn<int>(
    'delete_generation',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _notBeforeMeta = const VerificationMeta(
    'notBefore',
  );
  @override
  late final GeneratedColumn<DateTime> notBefore = GeneratedColumn<DateTime>(
    'not_before',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _snapshotAvailableMeta = const VerificationMeta(
    'snapshotAvailable',
  );
  @override
  late final GeneratedColumn<bool> snapshotAvailable = GeneratedColumn<bool>(
    'snapshot_available',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("snapshot_available" IN (0, 1))',
    ),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    rootTaskId,
    desiredStateId,
    deleteGeneration,
    notBefore,
    snapshotAvailable,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'task_delete_tombstones';
  @override
  VerificationContext validateIntegrity(
    Insertable<TaskDeleteTombstoneRow> instance, {
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
    if (data.containsKey('root_task_id')) {
      context.handle(
        _rootTaskIdMeta,
        rootTaskId.isAcceptableOrUnknown(
          data['root_task_id']!,
          _rootTaskIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_rootTaskIdMeta);
    }
    if (data.containsKey('desired_state_id')) {
      context.handle(
        _desiredStateIdMeta,
        desiredStateId.isAcceptableOrUnknown(
          data['desired_state_id']!,
          _desiredStateIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_desiredStateIdMeta);
    }
    if (data.containsKey('delete_generation')) {
      context.handle(
        _deleteGenerationMeta,
        deleteGeneration.isAcceptableOrUnknown(
          data['delete_generation']!,
          _deleteGenerationMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_deleteGenerationMeta);
    }
    if (data.containsKey('not_before')) {
      context.handle(
        _notBeforeMeta,
        notBefore.isAcceptableOrUnknown(data['not_before']!, _notBeforeMeta),
      );
    } else if (isInserting) {
      context.missing(_notBeforeMeta);
    }
    if (data.containsKey('snapshot_available')) {
      context.handle(
        _snapshotAvailableMeta,
        snapshotAvailable.isAcceptableOrUnknown(
          data['snapshot_available']!,
          _snapshotAvailableMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_snapshotAvailableMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, id},
    {accountId, rootTaskId},
  ];
  @override
  TaskDeleteTombstoneRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TaskDeleteTombstoneRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      rootTaskId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}root_task_id'],
      )!,
      desiredStateId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}desired_state_id'],
      )!,
      deleteGeneration: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}delete_generation'],
      )!,
      notBefore: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}not_before'],
      )!,
      snapshotAvailable: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}snapshot_available'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $TaskDeleteTombstoneRowsTable createAlias(String alias) {
    return $TaskDeleteTombstoneRowsTable(attachedDatabase, alias);
  }
}

class TaskDeleteTombstoneRow extends DataClass
    implements Insertable<TaskDeleteTombstoneRow> {
  final int id;
  final int accountId;
  final int rootTaskId;
  final int desiredStateId;
  final int deleteGeneration;
  final DateTime notBefore;
  final bool snapshotAvailable;
  final DateTime createdAt;
  const TaskDeleteTombstoneRow({
    required this.id,
    required this.accountId,
    required this.rootTaskId,
    required this.desiredStateId,
    required this.deleteGeneration,
    required this.notBefore,
    required this.snapshotAvailable,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['account_id'] = Variable<int>(accountId);
    map['root_task_id'] = Variable<int>(rootTaskId);
    map['desired_state_id'] = Variable<int>(desiredStateId);
    map['delete_generation'] = Variable<int>(deleteGeneration);
    map['not_before'] = Variable<DateTime>(notBefore);
    map['snapshot_available'] = Variable<bool>(snapshotAvailable);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  TaskDeleteTombstoneRowsCompanion toCompanion(bool nullToAbsent) {
    return TaskDeleteTombstoneRowsCompanion(
      id: Value(id),
      accountId: Value(accountId),
      rootTaskId: Value(rootTaskId),
      desiredStateId: Value(desiredStateId),
      deleteGeneration: Value(deleteGeneration),
      notBefore: Value(notBefore),
      snapshotAvailable: Value(snapshotAvailable),
      createdAt: Value(createdAt),
    );
  }

  factory TaskDeleteTombstoneRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TaskDeleteTombstoneRow(
      id: serializer.fromJson<int>(json['id']),
      accountId: serializer.fromJson<int>(json['accountId']),
      rootTaskId: serializer.fromJson<int>(json['rootTaskId']),
      desiredStateId: serializer.fromJson<int>(json['desiredStateId']),
      deleteGeneration: serializer.fromJson<int>(json['deleteGeneration']),
      notBefore: serializer.fromJson<DateTime>(json['notBefore']),
      snapshotAvailable: serializer.fromJson<bool>(json['snapshotAvailable']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'accountId': serializer.toJson<int>(accountId),
      'rootTaskId': serializer.toJson<int>(rootTaskId),
      'desiredStateId': serializer.toJson<int>(desiredStateId),
      'deleteGeneration': serializer.toJson<int>(deleteGeneration),
      'notBefore': serializer.toJson<DateTime>(notBefore),
      'snapshotAvailable': serializer.toJson<bool>(snapshotAvailable),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  TaskDeleteTombstoneRow copyWith({
    int? id,
    int? accountId,
    int? rootTaskId,
    int? desiredStateId,
    int? deleteGeneration,
    DateTime? notBefore,
    bool? snapshotAvailable,
    DateTime? createdAt,
  }) => TaskDeleteTombstoneRow(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    rootTaskId: rootTaskId ?? this.rootTaskId,
    desiredStateId: desiredStateId ?? this.desiredStateId,
    deleteGeneration: deleteGeneration ?? this.deleteGeneration,
    notBefore: notBefore ?? this.notBefore,
    snapshotAvailable: snapshotAvailable ?? this.snapshotAvailable,
    createdAt: createdAt ?? this.createdAt,
  );
  TaskDeleteTombstoneRow copyWithCompanion(
    TaskDeleteTombstoneRowsCompanion data,
  ) {
    return TaskDeleteTombstoneRow(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      rootTaskId: data.rootTaskId.present
          ? data.rootTaskId.value
          : this.rootTaskId,
      desiredStateId: data.desiredStateId.present
          ? data.desiredStateId.value
          : this.desiredStateId,
      deleteGeneration: data.deleteGeneration.present
          ? data.deleteGeneration.value
          : this.deleteGeneration,
      notBefore: data.notBefore.present ? data.notBefore.value : this.notBefore,
      snapshotAvailable: data.snapshotAvailable.present
          ? data.snapshotAvailable.value
          : this.snapshotAvailable,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TaskDeleteTombstoneRow(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('rootTaskId: $rootTaskId, ')
          ..write('desiredStateId: $desiredStateId, ')
          ..write('deleteGeneration: $deleteGeneration, ')
          ..write('notBefore: $notBefore, ')
          ..write('snapshotAvailable: $snapshotAvailable, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    rootTaskId,
    desiredStateId,
    deleteGeneration,
    notBefore,
    snapshotAvailable,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TaskDeleteTombstoneRow &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.rootTaskId == this.rootTaskId &&
          other.desiredStateId == this.desiredStateId &&
          other.deleteGeneration == this.deleteGeneration &&
          other.notBefore == this.notBefore &&
          other.snapshotAvailable == this.snapshotAvailable &&
          other.createdAt == this.createdAt);
}

class TaskDeleteTombstoneRowsCompanion
    extends UpdateCompanion<TaskDeleteTombstoneRow> {
  final Value<int> id;
  final Value<int> accountId;
  final Value<int> rootTaskId;
  final Value<int> desiredStateId;
  final Value<int> deleteGeneration;
  final Value<DateTime> notBefore;
  final Value<bool> snapshotAvailable;
  final Value<DateTime> createdAt;
  const TaskDeleteTombstoneRowsCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.rootTaskId = const Value.absent(),
    this.desiredStateId = const Value.absent(),
    this.deleteGeneration = const Value.absent(),
    this.notBefore = const Value.absent(),
    this.snapshotAvailable = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  TaskDeleteTombstoneRowsCompanion.insert({
    this.id = const Value.absent(),
    required int accountId,
    required int rootTaskId,
    required int desiredStateId,
    required int deleteGeneration,
    required DateTime notBefore,
    required bool snapshotAvailable,
    required DateTime createdAt,
  }) : accountId = Value(accountId),
       rootTaskId = Value(rootTaskId),
       desiredStateId = Value(desiredStateId),
       deleteGeneration = Value(deleteGeneration),
       notBefore = Value(notBefore),
       snapshotAvailable = Value(snapshotAvailable),
       createdAt = Value(createdAt);
  static Insertable<TaskDeleteTombstoneRow> custom({
    Expression<int>? id,
    Expression<int>? accountId,
    Expression<int>? rootTaskId,
    Expression<int>? desiredStateId,
    Expression<int>? deleteGeneration,
    Expression<DateTime>? notBefore,
    Expression<bool>? snapshotAvailable,
    Expression<DateTime>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (rootTaskId != null) 'root_task_id': rootTaskId,
      if (desiredStateId != null) 'desired_state_id': desiredStateId,
      if (deleteGeneration != null) 'delete_generation': deleteGeneration,
      if (notBefore != null) 'not_before': notBefore,
      if (snapshotAvailable != null) 'snapshot_available': snapshotAvailable,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  TaskDeleteTombstoneRowsCompanion copyWith({
    Value<int>? id,
    Value<int>? accountId,
    Value<int>? rootTaskId,
    Value<int>? desiredStateId,
    Value<int>? deleteGeneration,
    Value<DateTime>? notBefore,
    Value<bool>? snapshotAvailable,
    Value<DateTime>? createdAt,
  }) {
    return TaskDeleteTombstoneRowsCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      rootTaskId: rootTaskId ?? this.rootTaskId,
      desiredStateId: desiredStateId ?? this.desiredStateId,
      deleteGeneration: deleteGeneration ?? this.deleteGeneration,
      notBefore: notBefore ?? this.notBefore,
      snapshotAvailable: snapshotAvailable ?? this.snapshotAvailable,
      createdAt: createdAt ?? this.createdAt,
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
    if (rootTaskId.present) {
      map['root_task_id'] = Variable<int>(rootTaskId.value);
    }
    if (desiredStateId.present) {
      map['desired_state_id'] = Variable<int>(desiredStateId.value);
    }
    if (deleteGeneration.present) {
      map['delete_generation'] = Variable<int>(deleteGeneration.value);
    }
    if (notBefore.present) {
      map['not_before'] = Variable<DateTime>(notBefore.value);
    }
    if (snapshotAvailable.present) {
      map['snapshot_available'] = Variable<bool>(snapshotAvailable.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TaskDeleteTombstoneRowsCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('rootTaskId: $rootTaskId, ')
          ..write('desiredStateId: $desiredStateId, ')
          ..write('deleteGeneration: $deleteGeneration, ')
          ..write('notBefore: $notBefore, ')
          ..write('snapshotAvailable: $snapshotAvailable, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $TaskDeleteSnapshotRowsTable extends TaskDeleteSnapshotRows
    with TableInfo<$TaskDeleteSnapshotRowsTable, TaskDeleteSnapshotRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TaskDeleteSnapshotRowsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _tombstoneIdMeta = const VerificationMeta(
    'tombstoneId',
  );
  @override
  late final GeneratedColumn<int> tombstoneId = GeneratedColumn<int>(
    'tombstone_id',
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
    true,
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
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    tombstoneId,
    taskId,
    taskListId,
    parentTaskId,
    remoteId,
    title,
    notes,
    status,
    dueEpochDay,
    position,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'task_delete_snapshots';
  @override
  VerificationContext validateIntegrity(
    Insertable<TaskDeleteSnapshotRow> instance, {
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
    if (data.containsKey('tombstone_id')) {
      context.handle(
        _tombstoneIdMeta,
        tombstoneId.isAcceptableOrUnknown(
          data['tombstone_id']!,
          _tombstoneIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_tombstoneIdMeta);
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
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, tombstoneId, taskId},
  ];
  @override
  TaskDeleteSnapshotRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TaskDeleteSnapshotRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      tombstoneId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}tombstone_id'],
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
    );
  }

  @override
  $TaskDeleteSnapshotRowsTable createAlias(String alias) {
    return $TaskDeleteSnapshotRowsTable(attachedDatabase, alias);
  }
}

class TaskDeleteSnapshotRow extends DataClass
    implements Insertable<TaskDeleteSnapshotRow> {
  final int id;
  final int accountId;
  final int tombstoneId;
  final int taskId;
  final int taskListId;
  final int? parentTaskId;
  final String? remoteId;
  final String title;
  final String? notes;
  final String status;
  final int? dueEpochDay;
  final String position;
  const TaskDeleteSnapshotRow({
    required this.id,
    required this.accountId,
    required this.tombstoneId,
    required this.taskId,
    required this.taskListId,
    this.parentTaskId,
    this.remoteId,
    required this.title,
    this.notes,
    required this.status,
    this.dueEpochDay,
    required this.position,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['account_id'] = Variable<int>(accountId);
    map['tombstone_id'] = Variable<int>(tombstoneId);
    map['task_id'] = Variable<int>(taskId);
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
    return map;
  }

  TaskDeleteSnapshotRowsCompanion toCompanion(bool nullToAbsent) {
    return TaskDeleteSnapshotRowsCompanion(
      id: Value(id),
      accountId: Value(accountId),
      tombstoneId: Value(tombstoneId),
      taskId: Value(taskId),
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
    );
  }

  factory TaskDeleteSnapshotRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TaskDeleteSnapshotRow(
      id: serializer.fromJson<int>(json['id']),
      accountId: serializer.fromJson<int>(json['accountId']),
      tombstoneId: serializer.fromJson<int>(json['tombstoneId']),
      taskId: serializer.fromJson<int>(json['taskId']),
      taskListId: serializer.fromJson<int>(json['taskListId']),
      parentTaskId: serializer.fromJson<int?>(json['parentTaskId']),
      remoteId: serializer.fromJson<String?>(json['remoteId']),
      title: serializer.fromJson<String>(json['title']),
      notes: serializer.fromJson<String?>(json['notes']),
      status: serializer.fromJson<String>(json['status']),
      dueEpochDay: serializer.fromJson<int?>(json['dueEpochDay']),
      position: serializer.fromJson<String>(json['position']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'accountId': serializer.toJson<int>(accountId),
      'tombstoneId': serializer.toJson<int>(tombstoneId),
      'taskId': serializer.toJson<int>(taskId),
      'taskListId': serializer.toJson<int>(taskListId),
      'parentTaskId': serializer.toJson<int?>(parentTaskId),
      'remoteId': serializer.toJson<String?>(remoteId),
      'title': serializer.toJson<String>(title),
      'notes': serializer.toJson<String?>(notes),
      'status': serializer.toJson<String>(status),
      'dueEpochDay': serializer.toJson<int?>(dueEpochDay),
      'position': serializer.toJson<String>(position),
    };
  }

  TaskDeleteSnapshotRow copyWith({
    int? id,
    int? accountId,
    int? tombstoneId,
    int? taskId,
    int? taskListId,
    Value<int?> parentTaskId = const Value.absent(),
    Value<String?> remoteId = const Value.absent(),
    String? title,
    Value<String?> notes = const Value.absent(),
    String? status,
    Value<int?> dueEpochDay = const Value.absent(),
    String? position,
  }) => TaskDeleteSnapshotRow(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    tombstoneId: tombstoneId ?? this.tombstoneId,
    taskId: taskId ?? this.taskId,
    taskListId: taskListId ?? this.taskListId,
    parentTaskId: parentTaskId.present ? parentTaskId.value : this.parentTaskId,
    remoteId: remoteId.present ? remoteId.value : this.remoteId,
    title: title ?? this.title,
    notes: notes.present ? notes.value : this.notes,
    status: status ?? this.status,
    dueEpochDay: dueEpochDay.present ? dueEpochDay.value : this.dueEpochDay,
    position: position ?? this.position,
  );
  TaskDeleteSnapshotRow copyWithCompanion(
    TaskDeleteSnapshotRowsCompanion data,
  ) {
    return TaskDeleteSnapshotRow(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      tombstoneId: data.tombstoneId.present
          ? data.tombstoneId.value
          : this.tombstoneId,
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
    );
  }

  @override
  String toString() {
    return (StringBuffer('TaskDeleteSnapshotRow(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('tombstoneId: $tombstoneId, ')
          ..write('taskId: $taskId, ')
          ..write('taskListId: $taskListId, ')
          ..write('parentTaskId: $parentTaskId, ')
          ..write('remoteId: $remoteId, ')
          ..write('title: $title, ')
          ..write('notes: $notes, ')
          ..write('status: $status, ')
          ..write('dueEpochDay: $dueEpochDay, ')
          ..write('position: $position')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    tombstoneId,
    taskId,
    taskListId,
    parentTaskId,
    remoteId,
    title,
    notes,
    status,
    dueEpochDay,
    position,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TaskDeleteSnapshotRow &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.tombstoneId == this.tombstoneId &&
          other.taskId == this.taskId &&
          other.taskListId == this.taskListId &&
          other.parentTaskId == this.parentTaskId &&
          other.remoteId == this.remoteId &&
          other.title == this.title &&
          other.notes == this.notes &&
          other.status == this.status &&
          other.dueEpochDay == this.dueEpochDay &&
          other.position == this.position);
}

class TaskDeleteSnapshotRowsCompanion
    extends UpdateCompanion<TaskDeleteSnapshotRow> {
  final Value<int> id;
  final Value<int> accountId;
  final Value<int> tombstoneId;
  final Value<int> taskId;
  final Value<int> taskListId;
  final Value<int?> parentTaskId;
  final Value<String?> remoteId;
  final Value<String> title;
  final Value<String?> notes;
  final Value<String> status;
  final Value<int?> dueEpochDay;
  final Value<String> position;
  const TaskDeleteSnapshotRowsCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.tombstoneId = const Value.absent(),
    this.taskId = const Value.absent(),
    this.taskListId = const Value.absent(),
    this.parentTaskId = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.title = const Value.absent(),
    this.notes = const Value.absent(),
    this.status = const Value.absent(),
    this.dueEpochDay = const Value.absent(),
    this.position = const Value.absent(),
  });
  TaskDeleteSnapshotRowsCompanion.insert({
    this.id = const Value.absent(),
    required int accountId,
    required int tombstoneId,
    required int taskId,
    required int taskListId,
    this.parentTaskId = const Value.absent(),
    this.remoteId = const Value.absent(),
    required String title,
    this.notes = const Value.absent(),
    required String status,
    this.dueEpochDay = const Value.absent(),
    required String position,
  }) : accountId = Value(accountId),
       tombstoneId = Value(tombstoneId),
       taskId = Value(taskId),
       taskListId = Value(taskListId),
       title = Value(title),
       status = Value(status),
       position = Value(position);
  static Insertable<TaskDeleteSnapshotRow> custom({
    Expression<int>? id,
    Expression<int>? accountId,
    Expression<int>? tombstoneId,
    Expression<int>? taskId,
    Expression<int>? taskListId,
    Expression<int>? parentTaskId,
    Expression<String>? remoteId,
    Expression<String>? title,
    Expression<String>? notes,
    Expression<String>? status,
    Expression<int>? dueEpochDay,
    Expression<String>? position,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (tombstoneId != null) 'tombstone_id': tombstoneId,
      if (taskId != null) 'task_id': taskId,
      if (taskListId != null) 'task_list_id': taskListId,
      if (parentTaskId != null) 'parent_task_id': parentTaskId,
      if (remoteId != null) 'remote_id': remoteId,
      if (title != null) 'title': title,
      if (notes != null) 'notes': notes,
      if (status != null) 'status': status,
      if (dueEpochDay != null) 'due_epoch_day': dueEpochDay,
      if (position != null) 'position': position,
    });
  }

  TaskDeleteSnapshotRowsCompanion copyWith({
    Value<int>? id,
    Value<int>? accountId,
    Value<int>? tombstoneId,
    Value<int>? taskId,
    Value<int>? taskListId,
    Value<int?>? parentTaskId,
    Value<String?>? remoteId,
    Value<String>? title,
    Value<String?>? notes,
    Value<String>? status,
    Value<int?>? dueEpochDay,
    Value<String>? position,
  }) {
    return TaskDeleteSnapshotRowsCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      tombstoneId: tombstoneId ?? this.tombstoneId,
      taskId: taskId ?? this.taskId,
      taskListId: taskListId ?? this.taskListId,
      parentTaskId: parentTaskId ?? this.parentTaskId,
      remoteId: remoteId ?? this.remoteId,
      title: title ?? this.title,
      notes: notes ?? this.notes,
      status: status ?? this.status,
      dueEpochDay: dueEpochDay ?? this.dueEpochDay,
      position: position ?? this.position,
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
    if (tombstoneId.present) {
      map['tombstone_id'] = Variable<int>(tombstoneId.value);
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
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TaskDeleteSnapshotRowsCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('tombstoneId: $tombstoneId, ')
          ..write('taskId: $taskId, ')
          ..write('taskListId: $taskListId, ')
          ..write('parentTaskId: $parentTaskId, ')
          ..write('remoteId: $remoteId, ')
          ..write('title: $title, ')
          ..write('notes: $notes, ')
          ..write('status: $status, ')
          ..write('dueEpochDay: $dueEpochDay, ')
          ..write('position: $position')
          ..write(')'))
        .toString();
  }
}

class $TaskDueChangeGroupRowsTable extends TaskDueChangeGroupRows
    with TableInfo<$TaskDueChangeGroupRowsTable, TaskDueChangeGroupRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TaskDueChangeGroupRowsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _editedTaskIdMeta = const VerificationMeta(
    'editedTaskId',
  );
  @override
  late final GeneratedColumn<int> editedTaskId = GeneratedColumn<int>(
    'edited_task_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _snapshotCountMeta = const VerificationMeta(
    'snapshotCount',
  );
  @override
  late final GeneratedColumn<int> snapshotCount = GeneratedColumn<int>(
    'snapshot_count',
    aliasedName,
    false,
    check: () => ComparableExpr(snapshotCount).isBiggerThanValue(1),
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cascadedParentMeta = const VerificationMeta(
    'cascadedParent',
  );
  @override
  late final GeneratedColumn<bool> cascadedParent = GeneratedColumn<bool>(
    'cascaded_parent',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("cascaded_parent" IN (0, 1))',
    ),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    editedTaskId,
    snapshotCount,
    cascadedParent,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'task_due_change_groups';
  @override
  VerificationContext validateIntegrity(
    Insertable<TaskDueChangeGroupRow> instance, {
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
    if (data.containsKey('edited_task_id')) {
      context.handle(
        _editedTaskIdMeta,
        editedTaskId.isAcceptableOrUnknown(
          data['edited_task_id']!,
          _editedTaskIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_editedTaskIdMeta);
    }
    if (data.containsKey('snapshot_count')) {
      context.handle(
        _snapshotCountMeta,
        snapshotCount.isAcceptableOrUnknown(
          data['snapshot_count']!,
          _snapshotCountMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_snapshotCountMeta);
    }
    if (data.containsKey('cascaded_parent')) {
      context.handle(
        _cascadedParentMeta,
        cascadedParent.isAcceptableOrUnknown(
          data['cascaded_parent']!,
          _cascadedParentMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_cascadedParentMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, id},
    {accountId},
  ];
  @override
  TaskDueChangeGroupRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TaskDueChangeGroupRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      editedTaskId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}edited_task_id'],
      )!,
      snapshotCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}snapshot_count'],
      )!,
      cascadedParent: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}cascaded_parent'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $TaskDueChangeGroupRowsTable createAlias(String alias) {
    return $TaskDueChangeGroupRowsTable(attachedDatabase, alias);
  }
}

class TaskDueChangeGroupRow extends DataClass
    implements Insertable<TaskDueChangeGroupRow> {
  final int id;
  final int accountId;
  final int editedTaskId;
  final int snapshotCount;
  final bool cascadedParent;
  final DateTime createdAt;
  const TaskDueChangeGroupRow({
    required this.id,
    required this.accountId,
    required this.editedTaskId,
    required this.snapshotCount,
    required this.cascadedParent,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['account_id'] = Variable<int>(accountId);
    map['edited_task_id'] = Variable<int>(editedTaskId);
    map['snapshot_count'] = Variable<int>(snapshotCount);
    map['cascaded_parent'] = Variable<bool>(cascadedParent);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  TaskDueChangeGroupRowsCompanion toCompanion(bool nullToAbsent) {
    return TaskDueChangeGroupRowsCompanion(
      id: Value(id),
      accountId: Value(accountId),
      editedTaskId: Value(editedTaskId),
      snapshotCount: Value(snapshotCount),
      cascadedParent: Value(cascadedParent),
      createdAt: Value(createdAt),
    );
  }

  factory TaskDueChangeGroupRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TaskDueChangeGroupRow(
      id: serializer.fromJson<int>(json['id']),
      accountId: serializer.fromJson<int>(json['accountId']),
      editedTaskId: serializer.fromJson<int>(json['editedTaskId']),
      snapshotCount: serializer.fromJson<int>(json['snapshotCount']),
      cascadedParent: serializer.fromJson<bool>(json['cascadedParent']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'accountId': serializer.toJson<int>(accountId),
      'editedTaskId': serializer.toJson<int>(editedTaskId),
      'snapshotCount': serializer.toJson<int>(snapshotCount),
      'cascadedParent': serializer.toJson<bool>(cascadedParent),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  TaskDueChangeGroupRow copyWith({
    int? id,
    int? accountId,
    int? editedTaskId,
    int? snapshotCount,
    bool? cascadedParent,
    DateTime? createdAt,
  }) => TaskDueChangeGroupRow(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    editedTaskId: editedTaskId ?? this.editedTaskId,
    snapshotCount: snapshotCount ?? this.snapshotCount,
    cascadedParent: cascadedParent ?? this.cascadedParent,
    createdAt: createdAt ?? this.createdAt,
  );
  TaskDueChangeGroupRow copyWithCompanion(
    TaskDueChangeGroupRowsCompanion data,
  ) {
    return TaskDueChangeGroupRow(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      editedTaskId: data.editedTaskId.present
          ? data.editedTaskId.value
          : this.editedTaskId,
      snapshotCount: data.snapshotCount.present
          ? data.snapshotCount.value
          : this.snapshotCount,
      cascadedParent: data.cascadedParent.present
          ? data.cascadedParent.value
          : this.cascadedParent,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TaskDueChangeGroupRow(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('editedTaskId: $editedTaskId, ')
          ..write('snapshotCount: $snapshotCount, ')
          ..write('cascadedParent: $cascadedParent, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    editedTaskId,
    snapshotCount,
    cascadedParent,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TaskDueChangeGroupRow &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.editedTaskId == this.editedTaskId &&
          other.snapshotCount == this.snapshotCount &&
          other.cascadedParent == this.cascadedParent &&
          other.createdAt == this.createdAt);
}

class TaskDueChangeGroupRowsCompanion
    extends UpdateCompanion<TaskDueChangeGroupRow> {
  final Value<int> id;
  final Value<int> accountId;
  final Value<int> editedTaskId;
  final Value<int> snapshotCount;
  final Value<bool> cascadedParent;
  final Value<DateTime> createdAt;
  const TaskDueChangeGroupRowsCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.editedTaskId = const Value.absent(),
    this.snapshotCount = const Value.absent(),
    this.cascadedParent = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  TaskDueChangeGroupRowsCompanion.insert({
    this.id = const Value.absent(),
    required int accountId,
    required int editedTaskId,
    required int snapshotCount,
    required bool cascadedParent,
    required DateTime createdAt,
  }) : accountId = Value(accountId),
       editedTaskId = Value(editedTaskId),
       snapshotCount = Value(snapshotCount),
       cascadedParent = Value(cascadedParent),
       createdAt = Value(createdAt);
  static Insertable<TaskDueChangeGroupRow> custom({
    Expression<int>? id,
    Expression<int>? accountId,
    Expression<int>? editedTaskId,
    Expression<int>? snapshotCount,
    Expression<bool>? cascadedParent,
    Expression<DateTime>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (editedTaskId != null) 'edited_task_id': editedTaskId,
      if (snapshotCount != null) 'snapshot_count': snapshotCount,
      if (cascadedParent != null) 'cascaded_parent': cascadedParent,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  TaskDueChangeGroupRowsCompanion copyWith({
    Value<int>? id,
    Value<int>? accountId,
    Value<int>? editedTaskId,
    Value<int>? snapshotCount,
    Value<bool>? cascadedParent,
    Value<DateTime>? createdAt,
  }) {
    return TaskDueChangeGroupRowsCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      editedTaskId: editedTaskId ?? this.editedTaskId,
      snapshotCount: snapshotCount ?? this.snapshotCount,
      cascadedParent: cascadedParent ?? this.cascadedParent,
      createdAt: createdAt ?? this.createdAt,
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
    if (editedTaskId.present) {
      map['edited_task_id'] = Variable<int>(editedTaskId.value);
    }
    if (snapshotCount.present) {
      map['snapshot_count'] = Variable<int>(snapshotCount.value);
    }
    if (cascadedParent.present) {
      map['cascaded_parent'] = Variable<bool>(cascadedParent.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TaskDueChangeGroupRowsCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('editedTaskId: $editedTaskId, ')
          ..write('snapshotCount: $snapshotCount, ')
          ..write('cascadedParent: $cascadedParent, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $TaskDueChangeSnapshotRowsTable extends TaskDueChangeSnapshotRows
    with TableInfo<$TaskDueChangeSnapshotRowsTable, TaskDueChangeSnapshotRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TaskDueChangeSnapshotRowsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _groupIdMeta = const VerificationMeta(
    'groupId',
  );
  @override
  late final GeneratedColumn<int> groupId = GeneratedColumn<int>(
    'group_id',
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
  static const VerificationMeta _priorDueEpochDayMeta = const VerificationMeta(
    'priorDueEpochDay',
  );
  @override
  late final GeneratedColumn<int> priorDueEpochDay = GeneratedColumn<int>(
    'prior_due_epoch_day',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    groupId,
    taskId,
    priorDueEpochDay,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'task_due_change_snapshots';
  @override
  VerificationContext validateIntegrity(
    Insertable<TaskDueChangeSnapshotRow> instance, {
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
    if (data.containsKey('group_id')) {
      context.handle(
        _groupIdMeta,
        groupId.isAcceptableOrUnknown(data['group_id']!, _groupIdMeta),
      );
    } else if (isInserting) {
      context.missing(_groupIdMeta);
    }
    if (data.containsKey('task_id')) {
      context.handle(
        _taskIdMeta,
        taskId.isAcceptableOrUnknown(data['task_id']!, _taskIdMeta),
      );
    } else if (isInserting) {
      context.missing(_taskIdMeta);
    }
    if (data.containsKey('prior_due_epoch_day')) {
      context.handle(
        _priorDueEpochDayMeta,
        priorDueEpochDay.isAcceptableOrUnknown(
          data['prior_due_epoch_day']!,
          _priorDueEpochDayMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, groupId, taskId},
  ];
  @override
  TaskDueChangeSnapshotRow map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TaskDueChangeSnapshotRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      groupId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}group_id'],
      )!,
      taskId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}task_id'],
      )!,
      priorDueEpochDay: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}prior_due_epoch_day'],
      ),
    );
  }

  @override
  $TaskDueChangeSnapshotRowsTable createAlias(String alias) {
    return $TaskDueChangeSnapshotRowsTable(attachedDatabase, alias);
  }
}

class TaskDueChangeSnapshotRow extends DataClass
    implements Insertable<TaskDueChangeSnapshotRow> {
  final int id;
  final int accountId;
  final int groupId;
  final int taskId;
  final int? priorDueEpochDay;
  const TaskDueChangeSnapshotRow({
    required this.id,
    required this.accountId,
    required this.groupId,
    required this.taskId,
    this.priorDueEpochDay,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['account_id'] = Variable<int>(accountId);
    map['group_id'] = Variable<int>(groupId);
    map['task_id'] = Variable<int>(taskId);
    if (!nullToAbsent || priorDueEpochDay != null) {
      map['prior_due_epoch_day'] = Variable<int>(priorDueEpochDay);
    }
    return map;
  }

  TaskDueChangeSnapshotRowsCompanion toCompanion(bool nullToAbsent) {
    return TaskDueChangeSnapshotRowsCompanion(
      id: Value(id),
      accountId: Value(accountId),
      groupId: Value(groupId),
      taskId: Value(taskId),
      priorDueEpochDay: priorDueEpochDay == null && nullToAbsent
          ? const Value.absent()
          : Value(priorDueEpochDay),
    );
  }

  factory TaskDueChangeSnapshotRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TaskDueChangeSnapshotRow(
      id: serializer.fromJson<int>(json['id']),
      accountId: serializer.fromJson<int>(json['accountId']),
      groupId: serializer.fromJson<int>(json['groupId']),
      taskId: serializer.fromJson<int>(json['taskId']),
      priorDueEpochDay: serializer.fromJson<int?>(json['priorDueEpochDay']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'accountId': serializer.toJson<int>(accountId),
      'groupId': serializer.toJson<int>(groupId),
      'taskId': serializer.toJson<int>(taskId),
      'priorDueEpochDay': serializer.toJson<int?>(priorDueEpochDay),
    };
  }

  TaskDueChangeSnapshotRow copyWith({
    int? id,
    int? accountId,
    int? groupId,
    int? taskId,
    Value<int?> priorDueEpochDay = const Value.absent(),
  }) => TaskDueChangeSnapshotRow(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    groupId: groupId ?? this.groupId,
    taskId: taskId ?? this.taskId,
    priorDueEpochDay: priorDueEpochDay.present
        ? priorDueEpochDay.value
        : this.priorDueEpochDay,
  );
  TaskDueChangeSnapshotRow copyWithCompanion(
    TaskDueChangeSnapshotRowsCompanion data,
  ) {
    return TaskDueChangeSnapshotRow(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      groupId: data.groupId.present ? data.groupId.value : this.groupId,
      taskId: data.taskId.present ? data.taskId.value : this.taskId,
      priorDueEpochDay: data.priorDueEpochDay.present
          ? data.priorDueEpochDay.value
          : this.priorDueEpochDay,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TaskDueChangeSnapshotRow(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('groupId: $groupId, ')
          ..write('taskId: $taskId, ')
          ..write('priorDueEpochDay: $priorDueEpochDay')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, accountId, groupId, taskId, priorDueEpochDay);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TaskDueChangeSnapshotRow &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.groupId == this.groupId &&
          other.taskId == this.taskId &&
          other.priorDueEpochDay == this.priorDueEpochDay);
}

class TaskDueChangeSnapshotRowsCompanion
    extends UpdateCompanion<TaskDueChangeSnapshotRow> {
  final Value<int> id;
  final Value<int> accountId;
  final Value<int> groupId;
  final Value<int> taskId;
  final Value<int?> priorDueEpochDay;
  const TaskDueChangeSnapshotRowsCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.groupId = const Value.absent(),
    this.taskId = const Value.absent(),
    this.priorDueEpochDay = const Value.absent(),
  });
  TaskDueChangeSnapshotRowsCompanion.insert({
    this.id = const Value.absent(),
    required int accountId,
    required int groupId,
    required int taskId,
    this.priorDueEpochDay = const Value.absent(),
  }) : accountId = Value(accountId),
       groupId = Value(groupId),
       taskId = Value(taskId);
  static Insertable<TaskDueChangeSnapshotRow> custom({
    Expression<int>? id,
    Expression<int>? accountId,
    Expression<int>? groupId,
    Expression<int>? taskId,
    Expression<int>? priorDueEpochDay,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (groupId != null) 'group_id': groupId,
      if (taskId != null) 'task_id': taskId,
      if (priorDueEpochDay != null) 'prior_due_epoch_day': priorDueEpochDay,
    });
  }

  TaskDueChangeSnapshotRowsCompanion copyWith({
    Value<int>? id,
    Value<int>? accountId,
    Value<int>? groupId,
    Value<int>? taskId,
    Value<int?>? priorDueEpochDay,
  }) {
    return TaskDueChangeSnapshotRowsCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      groupId: groupId ?? this.groupId,
      taskId: taskId ?? this.taskId,
      priorDueEpochDay: priorDueEpochDay ?? this.priorDueEpochDay,
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
    if (groupId.present) {
      map['group_id'] = Variable<int>(groupId.value);
    }
    if (taskId.present) {
      map['task_id'] = Variable<int>(taskId.value);
    }
    if (priorDueEpochDay.present) {
      map['prior_due_epoch_day'] = Variable<int>(priorDueEpochDay.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TaskDueChangeSnapshotRowsCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('groupId: $groupId, ')
          ..write('taskId: $taskId, ')
          ..write('priorDueEpochDay: $priorDueEpochDay')
          ..write(')'))
        .toString();
  }
}

class $BulkOperationRowsTable extends BulkOperationRows
    with TableInfo<$BulkOperationRowsTable, BulkOperationRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BulkOperationRowsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    check: () => kind.isIn(const <String>['complete', 'reschedule', 'move']),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _selectedCountMeta = const VerificationMeta(
    'selectedCount',
  );
  @override
  late final GeneratedColumn<int> selectedCount = GeneratedColumn<int>(
    'selected_count',
    aliasedName,
    false,
    check: () => ComparableExpr(selectedCount).isBiggerThanValue(0),
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _affectedCountMeta = const VerificationMeta(
    'affectedCount',
  );
  @override
  late final GeneratedColumn<int> affectedCount = GeneratedColumn<int>(
    'affected_count',
    aliasedName,
    false,
    check: () => ComparableExpr(affectedCount).isBiggerOrEqualValue(0),
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    kind,
    selectedCount,
    affectedCount,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'bulk_operations';
  @override
  VerificationContext validateIntegrity(
    Insertable<BulkOperationRow> instance, {
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
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('selected_count')) {
      context.handle(
        _selectedCountMeta,
        selectedCount.isAcceptableOrUnknown(
          data['selected_count']!,
          _selectedCountMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_selectedCountMeta);
    }
    if (data.containsKey('affected_count')) {
      context.handle(
        _affectedCountMeta,
        affectedCount.isAcceptableOrUnknown(
          data['affected_count']!,
          _affectedCountMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_affectedCountMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId},
    {accountId, id},
  ];
  @override
  BulkOperationRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BulkOperationRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      selectedCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}selected_count'],
      )!,
      affectedCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}affected_count'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $BulkOperationRowsTable createAlias(String alias) {
    return $BulkOperationRowsTable(attachedDatabase, alias);
  }
}

class BulkOperationRow extends DataClass
    implements Insertable<BulkOperationRow> {
  final int id;
  final int accountId;
  final String kind;
  final int selectedCount;
  final int affectedCount;
  final DateTime createdAt;
  const BulkOperationRow({
    required this.id,
    required this.accountId,
    required this.kind,
    required this.selectedCount,
    required this.affectedCount,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['account_id'] = Variable<int>(accountId);
    map['kind'] = Variable<String>(kind);
    map['selected_count'] = Variable<int>(selectedCount);
    map['affected_count'] = Variable<int>(affectedCount);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  BulkOperationRowsCompanion toCompanion(bool nullToAbsent) {
    return BulkOperationRowsCompanion(
      id: Value(id),
      accountId: Value(accountId),
      kind: Value(kind),
      selectedCount: Value(selectedCount),
      affectedCount: Value(affectedCount),
      createdAt: Value(createdAt),
    );
  }

  factory BulkOperationRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BulkOperationRow(
      id: serializer.fromJson<int>(json['id']),
      accountId: serializer.fromJson<int>(json['accountId']),
      kind: serializer.fromJson<String>(json['kind']),
      selectedCount: serializer.fromJson<int>(json['selectedCount']),
      affectedCount: serializer.fromJson<int>(json['affectedCount']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'accountId': serializer.toJson<int>(accountId),
      'kind': serializer.toJson<String>(kind),
      'selectedCount': serializer.toJson<int>(selectedCount),
      'affectedCount': serializer.toJson<int>(affectedCount),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  BulkOperationRow copyWith({
    int? id,
    int? accountId,
    String? kind,
    int? selectedCount,
    int? affectedCount,
    DateTime? createdAt,
  }) => BulkOperationRow(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    kind: kind ?? this.kind,
    selectedCount: selectedCount ?? this.selectedCount,
    affectedCount: affectedCount ?? this.affectedCount,
    createdAt: createdAt ?? this.createdAt,
  );
  BulkOperationRow copyWithCompanion(BulkOperationRowsCompanion data) {
    return BulkOperationRow(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      kind: data.kind.present ? data.kind.value : this.kind,
      selectedCount: data.selectedCount.present
          ? data.selectedCount.value
          : this.selectedCount,
      affectedCount: data.affectedCount.present
          ? data.affectedCount.value
          : this.affectedCount,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BulkOperationRow(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('kind: $kind, ')
          ..write('selectedCount: $selectedCount, ')
          ..write('affectedCount: $affectedCount, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, accountId, kind, selectedCount, affectedCount, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BulkOperationRow &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.kind == this.kind &&
          other.selectedCount == this.selectedCount &&
          other.affectedCount == this.affectedCount &&
          other.createdAt == this.createdAt);
}

class BulkOperationRowsCompanion extends UpdateCompanion<BulkOperationRow> {
  final Value<int> id;
  final Value<int> accountId;
  final Value<String> kind;
  final Value<int> selectedCount;
  final Value<int> affectedCount;
  final Value<DateTime> createdAt;
  const BulkOperationRowsCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.kind = const Value.absent(),
    this.selectedCount = const Value.absent(),
    this.affectedCount = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  BulkOperationRowsCompanion.insert({
    this.id = const Value.absent(),
    required int accountId,
    required String kind,
    required int selectedCount,
    required int affectedCount,
    required DateTime createdAt,
  }) : accountId = Value(accountId),
       kind = Value(kind),
       selectedCount = Value(selectedCount),
       affectedCount = Value(affectedCount),
       createdAt = Value(createdAt);
  static Insertable<BulkOperationRow> custom({
    Expression<int>? id,
    Expression<int>? accountId,
    Expression<String>? kind,
    Expression<int>? selectedCount,
    Expression<int>? affectedCount,
    Expression<DateTime>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (kind != null) 'kind': kind,
      if (selectedCount != null) 'selected_count': selectedCount,
      if (affectedCount != null) 'affected_count': affectedCount,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  BulkOperationRowsCompanion copyWith({
    Value<int>? id,
    Value<int>? accountId,
    Value<String>? kind,
    Value<int>? selectedCount,
    Value<int>? affectedCount,
    Value<DateTime>? createdAt,
  }) {
    return BulkOperationRowsCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      kind: kind ?? this.kind,
      selectedCount: selectedCount ?? this.selectedCount,
      affectedCount: affectedCount ?? this.affectedCount,
      createdAt: createdAt ?? this.createdAt,
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
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (selectedCount.present) {
      map['selected_count'] = Variable<int>(selectedCount.value);
    }
    if (affectedCount.present) {
      map['affected_count'] = Variable<int>(affectedCount.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BulkOperationRowsCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('kind: $kind, ')
          ..write('selectedCount: $selectedCount, ')
          ..write('affectedCount: $affectedCount, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $BulkOperationMemberRowsTable extends BulkOperationMemberRows
    with TableInfo<$BulkOperationMemberRowsTable, BulkOperationMemberRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BulkOperationMemberRowsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _operationIdMeta = const VerificationMeta(
    'operationId',
  );
  @override
  late final GeneratedColumn<int> operationId = GeneratedColumn<int>(
    'operation_id',
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
  static const VerificationMeta _desiredStateIdMeta = const VerificationMeta(
    'desiredStateId',
  );
  @override
  late final GeneratedColumn<int> desiredStateId = GeneratedColumn<int>(
    'desired_state_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _generationMeta = const VerificationMeta(
    'generation',
  );
  @override
  late final GeneratedColumn<int> generation = GeneratedColumn<int>(
    'generation',
    aliasedName,
    false,
    check: () => ComparableExpr(generation).isBiggerThanValue(0),
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _outcomeMeta = const VerificationMeta(
    'outcome',
  );
  @override
  late final GeneratedColumn<String> outcome = GeneratedColumn<String>(
    'outcome',
    aliasedName,
    false,
    check: () => outcome.isIn(const <String>['confirmed', 'pending', 'failed']),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountId,
    operationId,
    taskId,
    desiredStateId,
    generation,
    outcome,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'bulk_operation_members';
  @override
  VerificationContext validateIntegrity(
    Insertable<BulkOperationMemberRow> instance, {
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
    if (data.containsKey('operation_id')) {
      context.handle(
        _operationIdMeta,
        operationId.isAcceptableOrUnknown(
          data['operation_id']!,
          _operationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_operationIdMeta);
    }
    if (data.containsKey('task_id')) {
      context.handle(
        _taskIdMeta,
        taskId.isAcceptableOrUnknown(data['task_id']!, _taskIdMeta),
      );
    } else if (isInserting) {
      context.missing(_taskIdMeta);
    }
    if (data.containsKey('desired_state_id')) {
      context.handle(
        _desiredStateIdMeta,
        desiredStateId.isAcceptableOrUnknown(
          data['desired_state_id']!,
          _desiredStateIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_desiredStateIdMeta);
    }
    if (data.containsKey('generation')) {
      context.handle(
        _generationMeta,
        generation.isAcceptableOrUnknown(data['generation']!, _generationMeta),
      );
    } else if (isInserting) {
      context.missing(_generationMeta);
    }
    if (data.containsKey('outcome')) {
      context.handle(
        _outcomeMeta,
        outcome.isAcceptableOrUnknown(data['outcome']!, _outcomeMeta),
      );
    } else if (isInserting) {
      context.missing(_outcomeMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {accountId, operationId, taskId},
  ];
  @override
  BulkOperationMemberRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BulkOperationMemberRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      operationId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}operation_id'],
      )!,
      taskId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}task_id'],
      )!,
      desiredStateId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}desired_state_id'],
      )!,
      generation: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}generation'],
      )!,
      outcome: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}outcome'],
      )!,
    );
  }

  @override
  $BulkOperationMemberRowsTable createAlias(String alias) {
    return $BulkOperationMemberRowsTable(attachedDatabase, alias);
  }
}

class BulkOperationMemberRow extends DataClass
    implements Insertable<BulkOperationMemberRow> {
  final int id;
  final int accountId;
  final int operationId;
  final int taskId;
  final int desiredStateId;
  final int generation;
  final String outcome;
  const BulkOperationMemberRow({
    required this.id,
    required this.accountId,
    required this.operationId,
    required this.taskId,
    required this.desiredStateId,
    required this.generation,
    required this.outcome,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['account_id'] = Variable<int>(accountId);
    map['operation_id'] = Variable<int>(operationId);
    map['task_id'] = Variable<int>(taskId);
    map['desired_state_id'] = Variable<int>(desiredStateId);
    map['generation'] = Variable<int>(generation);
    map['outcome'] = Variable<String>(outcome);
    return map;
  }

  BulkOperationMemberRowsCompanion toCompanion(bool nullToAbsent) {
    return BulkOperationMemberRowsCompanion(
      id: Value(id),
      accountId: Value(accountId),
      operationId: Value(operationId),
      taskId: Value(taskId),
      desiredStateId: Value(desiredStateId),
      generation: Value(generation),
      outcome: Value(outcome),
    );
  }

  factory BulkOperationMemberRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BulkOperationMemberRow(
      id: serializer.fromJson<int>(json['id']),
      accountId: serializer.fromJson<int>(json['accountId']),
      operationId: serializer.fromJson<int>(json['operationId']),
      taskId: serializer.fromJson<int>(json['taskId']),
      desiredStateId: serializer.fromJson<int>(json['desiredStateId']),
      generation: serializer.fromJson<int>(json['generation']),
      outcome: serializer.fromJson<String>(json['outcome']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'accountId': serializer.toJson<int>(accountId),
      'operationId': serializer.toJson<int>(operationId),
      'taskId': serializer.toJson<int>(taskId),
      'desiredStateId': serializer.toJson<int>(desiredStateId),
      'generation': serializer.toJson<int>(generation),
      'outcome': serializer.toJson<String>(outcome),
    };
  }

  BulkOperationMemberRow copyWith({
    int? id,
    int? accountId,
    int? operationId,
    int? taskId,
    int? desiredStateId,
    int? generation,
    String? outcome,
  }) => BulkOperationMemberRow(
    id: id ?? this.id,
    accountId: accountId ?? this.accountId,
    operationId: operationId ?? this.operationId,
    taskId: taskId ?? this.taskId,
    desiredStateId: desiredStateId ?? this.desiredStateId,
    generation: generation ?? this.generation,
    outcome: outcome ?? this.outcome,
  );
  BulkOperationMemberRow copyWithCompanion(
    BulkOperationMemberRowsCompanion data,
  ) {
    return BulkOperationMemberRow(
      id: data.id.present ? data.id.value : this.id,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      operationId: data.operationId.present
          ? data.operationId.value
          : this.operationId,
      taskId: data.taskId.present ? data.taskId.value : this.taskId,
      desiredStateId: data.desiredStateId.present
          ? data.desiredStateId.value
          : this.desiredStateId,
      generation: data.generation.present
          ? data.generation.value
          : this.generation,
      outcome: data.outcome.present ? data.outcome.value : this.outcome,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BulkOperationMemberRow(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('operationId: $operationId, ')
          ..write('taskId: $taskId, ')
          ..write('desiredStateId: $desiredStateId, ')
          ..write('generation: $generation, ')
          ..write('outcome: $outcome')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    operationId,
    taskId,
    desiredStateId,
    generation,
    outcome,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BulkOperationMemberRow &&
          other.id == this.id &&
          other.accountId == this.accountId &&
          other.operationId == this.operationId &&
          other.taskId == this.taskId &&
          other.desiredStateId == this.desiredStateId &&
          other.generation == this.generation &&
          other.outcome == this.outcome);
}

class BulkOperationMemberRowsCompanion
    extends UpdateCompanion<BulkOperationMemberRow> {
  final Value<int> id;
  final Value<int> accountId;
  final Value<int> operationId;
  final Value<int> taskId;
  final Value<int> desiredStateId;
  final Value<int> generation;
  final Value<String> outcome;
  const BulkOperationMemberRowsCompanion({
    this.id = const Value.absent(),
    this.accountId = const Value.absent(),
    this.operationId = const Value.absent(),
    this.taskId = const Value.absent(),
    this.desiredStateId = const Value.absent(),
    this.generation = const Value.absent(),
    this.outcome = const Value.absent(),
  });
  BulkOperationMemberRowsCompanion.insert({
    this.id = const Value.absent(),
    required int accountId,
    required int operationId,
    required int taskId,
    required int desiredStateId,
    required int generation,
    required String outcome,
  }) : accountId = Value(accountId),
       operationId = Value(operationId),
       taskId = Value(taskId),
       desiredStateId = Value(desiredStateId),
       generation = Value(generation),
       outcome = Value(outcome);
  static Insertable<BulkOperationMemberRow> custom({
    Expression<int>? id,
    Expression<int>? accountId,
    Expression<int>? operationId,
    Expression<int>? taskId,
    Expression<int>? desiredStateId,
    Expression<int>? generation,
    Expression<String>? outcome,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountId != null) 'account_id': accountId,
      if (operationId != null) 'operation_id': operationId,
      if (taskId != null) 'task_id': taskId,
      if (desiredStateId != null) 'desired_state_id': desiredStateId,
      if (generation != null) 'generation': generation,
      if (outcome != null) 'outcome': outcome,
    });
  }

  BulkOperationMemberRowsCompanion copyWith({
    Value<int>? id,
    Value<int>? accountId,
    Value<int>? operationId,
    Value<int>? taskId,
    Value<int>? desiredStateId,
    Value<int>? generation,
    Value<String>? outcome,
  }) {
    return BulkOperationMemberRowsCompanion(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      operationId: operationId ?? this.operationId,
      taskId: taskId ?? this.taskId,
      desiredStateId: desiredStateId ?? this.desiredStateId,
      generation: generation ?? this.generation,
      outcome: outcome ?? this.outcome,
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
    if (operationId.present) {
      map['operation_id'] = Variable<int>(operationId.value);
    }
    if (taskId.present) {
      map['task_id'] = Variable<int>(taskId.value);
    }
    if (desiredStateId.present) {
      map['desired_state_id'] = Variable<int>(desiredStateId.value);
    }
    if (generation.present) {
      map['generation'] = Variable<int>(generation.value);
    }
    if (outcome.present) {
      map['outcome'] = Variable<String>(outcome.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BulkOperationMemberRowsCompanion(')
          ..write('id: $id, ')
          ..write('accountId: $accountId, ')
          ..write('operationId: $operationId, ')
          ..write('taskId: $taskId, ')
          ..write('desiredStateId: $desiredStateId, ')
          ..write('generation: $generation, ')
          ..write('outcome: $outcome')
          ..write(')'))
        .toString();
  }
}

class $SyncFactRowsTable extends SyncFactRows
    with TableInfo<$SyncFactRowsTable, SyncFactRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncFactRowsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _lastSuccessfulSyncAtMeta =
      const VerificationMeta('lastSuccessfulSyncAt');
  @override
  late final GeneratedColumn<DateTime> lastSuccessfulSyncAt =
      GeneratedColumn<DateTime>(
        'last_successful_sync_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _latestFailureReasonMeta =
      const VerificationMeta('latestFailureReason');
  @override
  late final GeneratedColumn<String> latestFailureReason =
      GeneratedColumn<String>(
        'latest_failure_reason',
        aliasedName,
        true,
        check: () =>
            latestFailureReason.isNull() |
            latestFailureReason.isIn(const <String>[
              'no_connection',
              'remote_failure',
              'application_failure',
              'stale',
            ]),
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _latestFailureAtMeta = const VerificationMeta(
    'latestFailureAt',
  );
  @override
  late final GeneratedColumn<DateTime> latestFailureAt =
      GeneratedColumn<DateTime>(
        'latest_failure_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _latestFailureDiagnosticCodeMeta =
      const VerificationMeta('latestFailureDiagnosticCode');
  @override
  late final GeneratedColumn<String> latestFailureDiagnosticCode =
      GeneratedColumn<String>(
        'latest_failure_diagnostic_code',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _latestFailureActionMeta =
      const VerificationMeta('latestFailureAction');
  @override
  late final GeneratedColumn<String> latestFailureAction =
      GeneratedColumn<String>(
        'latest_failure_action',
        aliasedName,
        true,
        check: () =>
            latestFailureAction.isNull() |
            latestFailureAction.isIn(const <String>['none', 'retry']),
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _pendingCountMeta = const VerificationMeta(
    'pendingCount',
  );
  @override
  late final GeneratedColumn<int> pendingCount = GeneratedColumn<int>(
    'pending_count',
    aliasedName,
    false,
    check: () => ComparableExpr(pendingCount).isBiggerOrEqualValue(0),
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _inFlightCountMeta = const VerificationMeta(
    'inFlightCount',
  );
  @override
  late final GeneratedColumn<int> inFlightCount = GeneratedColumn<int>(
    'in_flight_count',
    aliasedName,
    false,
    check: () => ComparableExpr(inFlightCount).isBiggerOrEqualValue(0),
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _uncertainCountMeta = const VerificationMeta(
    'uncertainCount',
  );
  @override
  late final GeneratedColumn<int> uncertainCount = GeneratedColumn<int>(
    'uncertain_count',
    aliasedName,
    false,
    check: () => ComparableExpr(uncertainCount).isBiggerOrEqualValue(0),
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _failedCountMeta = const VerificationMeta(
    'failedCount',
  );
  @override
  late final GeneratedColumn<int> failedCount = GeneratedColumn<int>(
    'failed_count',
    aliasedName,
    false,
    check: () => ComparableExpr(failedCount).isBiggerOrEqualValue(0),
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _reauthorizationRequiredMeta =
      const VerificationMeta('reauthorizationRequired');
  @override
  late final GeneratedColumn<bool> reauthorizationRequired =
      GeneratedColumn<bool>(
        'reauthorization_required',
        aliasedName,
        false,
        type: DriftSqlType.bool,
        requiredDuringInsert: false,
        defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("reauthorization_required" IN (0, 1))',
        ),
        defaultValue: const Constant(false),
      );
  static const VerificationMeta _retryWaitingMeta = const VerificationMeta(
    'retryWaiting',
  );
  @override
  late final GeneratedColumn<bool> retryWaiting = GeneratedColumn<bool>(
    'retry_waiting',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("retry_waiting" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _automaticRetryExhaustedMeta =
      const VerificationMeta('automaticRetryExhausted');
  @override
  late final GeneratedColumn<bool> automaticRetryExhausted =
      GeneratedColumn<bool>(
        'automatic_retry_exhausted',
        aliasedName,
        false,
        type: DriftSqlType.bool,
        requiredDuringInsert: false,
        defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("automatic_retry_exhausted" IN (0, 1))',
        ),
        defaultValue: const Constant(false),
      );
  static const VerificationMeta _retryEpisodeStartedAtMeta =
      const VerificationMeta('retryEpisodeStartedAt');
  @override
  late final GeneratedColumn<DateTime> retryEpisodeStartedAt =
      GeneratedColumn<DateTime>(
        'retry_episode_started_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _retryEpisodeDeadlineAtMeta =
      const VerificationMeta('retryEpisodeDeadlineAt');
  @override
  late final GeneratedColumn<DateTime> retryEpisodeDeadlineAt =
      GeneratedColumn<DateTime>(
        'retry_episode_deadline_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _retryNextAttemptAtMeta =
      const VerificationMeta('retryNextAttemptAt');
  @override
  late final GeneratedColumn<DateTime> retryNextAttemptAt =
      GeneratedColumn<DateTime>(
        'retry_next_attempt_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _retryServerNotBeforeAtMeta =
      const VerificationMeta('retryServerNotBeforeAt');
  @override
  late final GeneratedColumn<DateTime> retryServerNotBeforeAt =
      GeneratedColumn<DateTime>(
        'retry_server_not_before_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _retryLastObservedAtMeta =
      const VerificationMeta('retryLastObservedAt');
  @override
  late final GeneratedColumn<DateTime> retryLastObservedAt =
      GeneratedColumn<DateTime>(
        'retry_last_observed_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _retryAttemptCountMeta = const VerificationMeta(
    'retryAttemptCount',
  );
  @override
  late final GeneratedColumn<int> retryAttemptCount = GeneratedColumn<int>(
    'retry_attempt_count',
    aliasedName,
    false,
    check: () => ComparableExpr(retryAttemptCount).isBiggerOrEqualValue(0),
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _requiredScopeIncompleteMeta =
      const VerificationMeta('requiredScopeIncomplete');
  @override
  late final GeneratedColumn<bool> requiredScopeIncomplete =
      GeneratedColumn<bool>(
        'required_scope_incomplete',
        aliasedName,
        false,
        type: DriftSqlType.bool,
        requiredDuringInsert: false,
        defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("required_scope_incomplete" IN (0, 1))',
        ),
        defaultValue: const Constant(false),
      );
  static const VerificationMeta _followUpRequiredMeta = const VerificationMeta(
    'followUpRequired',
  );
  @override
  late final GeneratedColumn<bool> followUpRequired = GeneratedColumn<bool>(
    'follow_up_required',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("follow_up_required" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    lastSuccessfulSyncAt,
    latestFailureReason,
    latestFailureAt,
    latestFailureDiagnosticCode,
    latestFailureAction,
    pendingCount,
    inFlightCount,
    uncertainCount,
    failedCount,
    reauthorizationRequired,
    retryWaiting,
    automaticRetryExhausted,
    retryEpisodeStartedAt,
    retryEpisodeDeadlineAt,
    retryNextAttemptAt,
    retryServerNotBeforeAt,
    retryLastObservedAt,
    retryAttemptCount,
    requiredScopeIncomplete,
    followUpRequired,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_facts';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncFactRow> instance, {
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
    if (data.containsKey('last_successful_sync_at')) {
      context.handle(
        _lastSuccessfulSyncAtMeta,
        lastSuccessfulSyncAt.isAcceptableOrUnknown(
          data['last_successful_sync_at']!,
          _lastSuccessfulSyncAtMeta,
        ),
      );
    }
    if (data.containsKey('latest_failure_reason')) {
      context.handle(
        _latestFailureReasonMeta,
        latestFailureReason.isAcceptableOrUnknown(
          data['latest_failure_reason']!,
          _latestFailureReasonMeta,
        ),
      );
    }
    if (data.containsKey('latest_failure_at')) {
      context.handle(
        _latestFailureAtMeta,
        latestFailureAt.isAcceptableOrUnknown(
          data['latest_failure_at']!,
          _latestFailureAtMeta,
        ),
      );
    }
    if (data.containsKey('latest_failure_diagnostic_code')) {
      context.handle(
        _latestFailureDiagnosticCodeMeta,
        latestFailureDiagnosticCode.isAcceptableOrUnknown(
          data['latest_failure_diagnostic_code']!,
          _latestFailureDiagnosticCodeMeta,
        ),
      );
    }
    if (data.containsKey('latest_failure_action')) {
      context.handle(
        _latestFailureActionMeta,
        latestFailureAction.isAcceptableOrUnknown(
          data['latest_failure_action']!,
          _latestFailureActionMeta,
        ),
      );
    }
    if (data.containsKey('pending_count')) {
      context.handle(
        _pendingCountMeta,
        pendingCount.isAcceptableOrUnknown(
          data['pending_count']!,
          _pendingCountMeta,
        ),
      );
    }
    if (data.containsKey('in_flight_count')) {
      context.handle(
        _inFlightCountMeta,
        inFlightCount.isAcceptableOrUnknown(
          data['in_flight_count']!,
          _inFlightCountMeta,
        ),
      );
    }
    if (data.containsKey('uncertain_count')) {
      context.handle(
        _uncertainCountMeta,
        uncertainCount.isAcceptableOrUnknown(
          data['uncertain_count']!,
          _uncertainCountMeta,
        ),
      );
    }
    if (data.containsKey('failed_count')) {
      context.handle(
        _failedCountMeta,
        failedCount.isAcceptableOrUnknown(
          data['failed_count']!,
          _failedCountMeta,
        ),
      );
    }
    if (data.containsKey('reauthorization_required')) {
      context.handle(
        _reauthorizationRequiredMeta,
        reauthorizationRequired.isAcceptableOrUnknown(
          data['reauthorization_required']!,
          _reauthorizationRequiredMeta,
        ),
      );
    }
    if (data.containsKey('retry_waiting')) {
      context.handle(
        _retryWaitingMeta,
        retryWaiting.isAcceptableOrUnknown(
          data['retry_waiting']!,
          _retryWaitingMeta,
        ),
      );
    }
    if (data.containsKey('automatic_retry_exhausted')) {
      context.handle(
        _automaticRetryExhaustedMeta,
        automaticRetryExhausted.isAcceptableOrUnknown(
          data['automatic_retry_exhausted']!,
          _automaticRetryExhaustedMeta,
        ),
      );
    }
    if (data.containsKey('retry_episode_started_at')) {
      context.handle(
        _retryEpisodeStartedAtMeta,
        retryEpisodeStartedAt.isAcceptableOrUnknown(
          data['retry_episode_started_at']!,
          _retryEpisodeStartedAtMeta,
        ),
      );
    }
    if (data.containsKey('retry_episode_deadline_at')) {
      context.handle(
        _retryEpisodeDeadlineAtMeta,
        retryEpisodeDeadlineAt.isAcceptableOrUnknown(
          data['retry_episode_deadline_at']!,
          _retryEpisodeDeadlineAtMeta,
        ),
      );
    }
    if (data.containsKey('retry_next_attempt_at')) {
      context.handle(
        _retryNextAttemptAtMeta,
        retryNextAttemptAt.isAcceptableOrUnknown(
          data['retry_next_attempt_at']!,
          _retryNextAttemptAtMeta,
        ),
      );
    }
    if (data.containsKey('retry_server_not_before_at')) {
      context.handle(
        _retryServerNotBeforeAtMeta,
        retryServerNotBeforeAt.isAcceptableOrUnknown(
          data['retry_server_not_before_at']!,
          _retryServerNotBeforeAtMeta,
        ),
      );
    }
    if (data.containsKey('retry_last_observed_at')) {
      context.handle(
        _retryLastObservedAtMeta,
        retryLastObservedAt.isAcceptableOrUnknown(
          data['retry_last_observed_at']!,
          _retryLastObservedAtMeta,
        ),
      );
    }
    if (data.containsKey('retry_attempt_count')) {
      context.handle(
        _retryAttemptCountMeta,
        retryAttemptCount.isAcceptableOrUnknown(
          data['retry_attempt_count']!,
          _retryAttemptCountMeta,
        ),
      );
    }
    if (data.containsKey('required_scope_incomplete')) {
      context.handle(
        _requiredScopeIncompleteMeta,
        requiredScopeIncomplete.isAcceptableOrUnknown(
          data['required_scope_incomplete']!,
          _requiredScopeIncompleteMeta,
        ),
      );
    }
    if (data.containsKey('follow_up_required')) {
      context.handle(
        _followUpRequiredMeta,
        followUpRequired.isAcceptableOrUnknown(
          data['follow_up_required']!,
          _followUpRequiredMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId};
  @override
  SyncFactRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncFactRow(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_id'],
      )!,
      lastSuccessfulSyncAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_successful_sync_at'],
      ),
      latestFailureReason: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}latest_failure_reason'],
      ),
      latestFailureAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}latest_failure_at'],
      ),
      latestFailureDiagnosticCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}latest_failure_diagnostic_code'],
      ),
      latestFailureAction: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}latest_failure_action'],
      ),
      pendingCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}pending_count'],
      )!,
      inFlightCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}in_flight_count'],
      )!,
      uncertainCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}uncertain_count'],
      )!,
      failedCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}failed_count'],
      )!,
      reauthorizationRequired: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}reauthorization_required'],
      )!,
      retryWaiting: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}retry_waiting'],
      )!,
      automaticRetryExhausted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}automatic_retry_exhausted'],
      )!,
      retryEpisodeStartedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}retry_episode_started_at'],
      ),
      retryEpisodeDeadlineAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}retry_episode_deadline_at'],
      ),
      retryNextAttemptAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}retry_next_attempt_at'],
      ),
      retryServerNotBeforeAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}retry_server_not_before_at'],
      ),
      retryLastObservedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}retry_last_observed_at'],
      ),
      retryAttemptCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}retry_attempt_count'],
      )!,
      requiredScopeIncomplete: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}required_scope_incomplete'],
      )!,
      followUpRequired: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}follow_up_required'],
      )!,
    );
  }

  @override
  $SyncFactRowsTable createAlias(String alias) {
    return $SyncFactRowsTable(attachedDatabase, alias);
  }
}

class SyncFactRow extends DataClass implements Insertable<SyncFactRow> {
  final int accountId;
  final DateTime? lastSuccessfulSyncAt;
  final String? latestFailureReason;
  final DateTime? latestFailureAt;
  final String? latestFailureDiagnosticCode;
  final String? latestFailureAction;
  final int pendingCount;
  final int inFlightCount;
  final int uncertainCount;
  final int failedCount;
  final bool reauthorizationRequired;
  final bool retryWaiting;
  final bool automaticRetryExhausted;
  final DateTime? retryEpisodeStartedAt;
  final DateTime? retryEpisodeDeadlineAt;
  final DateTime? retryNextAttemptAt;
  final DateTime? retryServerNotBeforeAt;
  final DateTime? retryLastObservedAt;
  final int retryAttemptCount;
  final bool requiredScopeIncomplete;
  final bool followUpRequired;
  const SyncFactRow({
    required this.accountId,
    this.lastSuccessfulSyncAt,
    this.latestFailureReason,
    this.latestFailureAt,
    this.latestFailureDiagnosticCode,
    this.latestFailureAction,
    required this.pendingCount,
    required this.inFlightCount,
    required this.uncertainCount,
    required this.failedCount,
    required this.reauthorizationRequired,
    required this.retryWaiting,
    required this.automaticRetryExhausted,
    this.retryEpisodeStartedAt,
    this.retryEpisodeDeadlineAt,
    this.retryNextAttemptAt,
    this.retryServerNotBeforeAt,
    this.retryLastObservedAt,
    required this.retryAttemptCount,
    required this.requiredScopeIncomplete,
    required this.followUpRequired,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<int>(accountId);
    if (!nullToAbsent || lastSuccessfulSyncAt != null) {
      map['last_successful_sync_at'] = Variable<DateTime>(lastSuccessfulSyncAt);
    }
    if (!nullToAbsent || latestFailureReason != null) {
      map['latest_failure_reason'] = Variable<String>(latestFailureReason);
    }
    if (!nullToAbsent || latestFailureAt != null) {
      map['latest_failure_at'] = Variable<DateTime>(latestFailureAt);
    }
    if (!nullToAbsent || latestFailureDiagnosticCode != null) {
      map['latest_failure_diagnostic_code'] = Variable<String>(
        latestFailureDiagnosticCode,
      );
    }
    if (!nullToAbsent || latestFailureAction != null) {
      map['latest_failure_action'] = Variable<String>(latestFailureAction);
    }
    map['pending_count'] = Variable<int>(pendingCount);
    map['in_flight_count'] = Variable<int>(inFlightCount);
    map['uncertain_count'] = Variable<int>(uncertainCount);
    map['failed_count'] = Variable<int>(failedCount);
    map['reauthorization_required'] = Variable<bool>(reauthorizationRequired);
    map['retry_waiting'] = Variable<bool>(retryWaiting);
    map['automatic_retry_exhausted'] = Variable<bool>(automaticRetryExhausted);
    if (!nullToAbsent || retryEpisodeStartedAt != null) {
      map['retry_episode_started_at'] = Variable<DateTime>(
        retryEpisodeStartedAt,
      );
    }
    if (!nullToAbsent || retryEpisodeDeadlineAt != null) {
      map['retry_episode_deadline_at'] = Variable<DateTime>(
        retryEpisodeDeadlineAt,
      );
    }
    if (!nullToAbsent || retryNextAttemptAt != null) {
      map['retry_next_attempt_at'] = Variable<DateTime>(retryNextAttemptAt);
    }
    if (!nullToAbsent || retryServerNotBeforeAt != null) {
      map['retry_server_not_before_at'] = Variable<DateTime>(
        retryServerNotBeforeAt,
      );
    }
    if (!nullToAbsent || retryLastObservedAt != null) {
      map['retry_last_observed_at'] = Variable<DateTime>(retryLastObservedAt);
    }
    map['retry_attempt_count'] = Variable<int>(retryAttemptCount);
    map['required_scope_incomplete'] = Variable<bool>(requiredScopeIncomplete);
    map['follow_up_required'] = Variable<bool>(followUpRequired);
    return map;
  }

  SyncFactRowsCompanion toCompanion(bool nullToAbsent) {
    return SyncFactRowsCompanion(
      accountId: Value(accountId),
      lastSuccessfulSyncAt: lastSuccessfulSyncAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastSuccessfulSyncAt),
      latestFailureReason: latestFailureReason == null && nullToAbsent
          ? const Value.absent()
          : Value(latestFailureReason),
      latestFailureAt: latestFailureAt == null && nullToAbsent
          ? const Value.absent()
          : Value(latestFailureAt),
      latestFailureDiagnosticCode:
          latestFailureDiagnosticCode == null && nullToAbsent
          ? const Value.absent()
          : Value(latestFailureDiagnosticCode),
      latestFailureAction: latestFailureAction == null && nullToAbsent
          ? const Value.absent()
          : Value(latestFailureAction),
      pendingCount: Value(pendingCount),
      inFlightCount: Value(inFlightCount),
      uncertainCount: Value(uncertainCount),
      failedCount: Value(failedCount),
      reauthorizationRequired: Value(reauthorizationRequired),
      retryWaiting: Value(retryWaiting),
      automaticRetryExhausted: Value(automaticRetryExhausted),
      retryEpisodeStartedAt: retryEpisodeStartedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(retryEpisodeStartedAt),
      retryEpisodeDeadlineAt: retryEpisodeDeadlineAt == null && nullToAbsent
          ? const Value.absent()
          : Value(retryEpisodeDeadlineAt),
      retryNextAttemptAt: retryNextAttemptAt == null && nullToAbsent
          ? const Value.absent()
          : Value(retryNextAttemptAt),
      retryServerNotBeforeAt: retryServerNotBeforeAt == null && nullToAbsent
          ? const Value.absent()
          : Value(retryServerNotBeforeAt),
      retryLastObservedAt: retryLastObservedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(retryLastObservedAt),
      retryAttemptCount: Value(retryAttemptCount),
      requiredScopeIncomplete: Value(requiredScopeIncomplete),
      followUpRequired: Value(followUpRequired),
    );
  }

  factory SyncFactRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncFactRow(
      accountId: serializer.fromJson<int>(json['accountId']),
      lastSuccessfulSyncAt: serializer.fromJson<DateTime?>(
        json['lastSuccessfulSyncAt'],
      ),
      latestFailureReason: serializer.fromJson<String?>(
        json['latestFailureReason'],
      ),
      latestFailureAt: serializer.fromJson<DateTime?>(json['latestFailureAt']),
      latestFailureDiagnosticCode: serializer.fromJson<String?>(
        json['latestFailureDiagnosticCode'],
      ),
      latestFailureAction: serializer.fromJson<String?>(
        json['latestFailureAction'],
      ),
      pendingCount: serializer.fromJson<int>(json['pendingCount']),
      inFlightCount: serializer.fromJson<int>(json['inFlightCount']),
      uncertainCount: serializer.fromJson<int>(json['uncertainCount']),
      failedCount: serializer.fromJson<int>(json['failedCount']),
      reauthorizationRequired: serializer.fromJson<bool>(
        json['reauthorizationRequired'],
      ),
      retryWaiting: serializer.fromJson<bool>(json['retryWaiting']),
      automaticRetryExhausted: serializer.fromJson<bool>(
        json['automaticRetryExhausted'],
      ),
      retryEpisodeStartedAt: serializer.fromJson<DateTime?>(
        json['retryEpisodeStartedAt'],
      ),
      retryEpisodeDeadlineAt: serializer.fromJson<DateTime?>(
        json['retryEpisodeDeadlineAt'],
      ),
      retryNextAttemptAt: serializer.fromJson<DateTime?>(
        json['retryNextAttemptAt'],
      ),
      retryServerNotBeforeAt: serializer.fromJson<DateTime?>(
        json['retryServerNotBeforeAt'],
      ),
      retryLastObservedAt: serializer.fromJson<DateTime?>(
        json['retryLastObservedAt'],
      ),
      retryAttemptCount: serializer.fromJson<int>(json['retryAttemptCount']),
      requiredScopeIncomplete: serializer.fromJson<bool>(
        json['requiredScopeIncomplete'],
      ),
      followUpRequired: serializer.fromJson<bool>(json['followUpRequired']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<int>(accountId),
      'lastSuccessfulSyncAt': serializer.toJson<DateTime?>(
        lastSuccessfulSyncAt,
      ),
      'latestFailureReason': serializer.toJson<String?>(latestFailureReason),
      'latestFailureAt': serializer.toJson<DateTime?>(latestFailureAt),
      'latestFailureDiagnosticCode': serializer.toJson<String?>(
        latestFailureDiagnosticCode,
      ),
      'latestFailureAction': serializer.toJson<String?>(latestFailureAction),
      'pendingCount': serializer.toJson<int>(pendingCount),
      'inFlightCount': serializer.toJson<int>(inFlightCount),
      'uncertainCount': serializer.toJson<int>(uncertainCount),
      'failedCount': serializer.toJson<int>(failedCount),
      'reauthorizationRequired': serializer.toJson<bool>(
        reauthorizationRequired,
      ),
      'retryWaiting': serializer.toJson<bool>(retryWaiting),
      'automaticRetryExhausted': serializer.toJson<bool>(
        automaticRetryExhausted,
      ),
      'retryEpisodeStartedAt': serializer.toJson<DateTime?>(
        retryEpisodeStartedAt,
      ),
      'retryEpisodeDeadlineAt': serializer.toJson<DateTime?>(
        retryEpisodeDeadlineAt,
      ),
      'retryNextAttemptAt': serializer.toJson<DateTime?>(retryNextAttemptAt),
      'retryServerNotBeforeAt': serializer.toJson<DateTime?>(
        retryServerNotBeforeAt,
      ),
      'retryLastObservedAt': serializer.toJson<DateTime?>(retryLastObservedAt),
      'retryAttemptCount': serializer.toJson<int>(retryAttemptCount),
      'requiredScopeIncomplete': serializer.toJson<bool>(
        requiredScopeIncomplete,
      ),
      'followUpRequired': serializer.toJson<bool>(followUpRequired),
    };
  }

  SyncFactRow copyWith({
    int? accountId,
    Value<DateTime?> lastSuccessfulSyncAt = const Value.absent(),
    Value<String?> latestFailureReason = const Value.absent(),
    Value<DateTime?> latestFailureAt = const Value.absent(),
    Value<String?> latestFailureDiagnosticCode = const Value.absent(),
    Value<String?> latestFailureAction = const Value.absent(),
    int? pendingCount,
    int? inFlightCount,
    int? uncertainCount,
    int? failedCount,
    bool? reauthorizationRequired,
    bool? retryWaiting,
    bool? automaticRetryExhausted,
    Value<DateTime?> retryEpisodeStartedAt = const Value.absent(),
    Value<DateTime?> retryEpisodeDeadlineAt = const Value.absent(),
    Value<DateTime?> retryNextAttemptAt = const Value.absent(),
    Value<DateTime?> retryServerNotBeforeAt = const Value.absent(),
    Value<DateTime?> retryLastObservedAt = const Value.absent(),
    int? retryAttemptCount,
    bool? requiredScopeIncomplete,
    bool? followUpRequired,
  }) => SyncFactRow(
    accountId: accountId ?? this.accountId,
    lastSuccessfulSyncAt: lastSuccessfulSyncAt.present
        ? lastSuccessfulSyncAt.value
        : this.lastSuccessfulSyncAt,
    latestFailureReason: latestFailureReason.present
        ? latestFailureReason.value
        : this.latestFailureReason,
    latestFailureAt: latestFailureAt.present
        ? latestFailureAt.value
        : this.latestFailureAt,
    latestFailureDiagnosticCode: latestFailureDiagnosticCode.present
        ? latestFailureDiagnosticCode.value
        : this.latestFailureDiagnosticCode,
    latestFailureAction: latestFailureAction.present
        ? latestFailureAction.value
        : this.latestFailureAction,
    pendingCount: pendingCount ?? this.pendingCount,
    inFlightCount: inFlightCount ?? this.inFlightCount,
    uncertainCount: uncertainCount ?? this.uncertainCount,
    failedCount: failedCount ?? this.failedCount,
    reauthorizationRequired:
        reauthorizationRequired ?? this.reauthorizationRequired,
    retryWaiting: retryWaiting ?? this.retryWaiting,
    automaticRetryExhausted:
        automaticRetryExhausted ?? this.automaticRetryExhausted,
    retryEpisodeStartedAt: retryEpisodeStartedAt.present
        ? retryEpisodeStartedAt.value
        : this.retryEpisodeStartedAt,
    retryEpisodeDeadlineAt: retryEpisodeDeadlineAt.present
        ? retryEpisodeDeadlineAt.value
        : this.retryEpisodeDeadlineAt,
    retryNextAttemptAt: retryNextAttemptAt.present
        ? retryNextAttemptAt.value
        : this.retryNextAttemptAt,
    retryServerNotBeforeAt: retryServerNotBeforeAt.present
        ? retryServerNotBeforeAt.value
        : this.retryServerNotBeforeAt,
    retryLastObservedAt: retryLastObservedAt.present
        ? retryLastObservedAt.value
        : this.retryLastObservedAt,
    retryAttemptCount: retryAttemptCount ?? this.retryAttemptCount,
    requiredScopeIncomplete:
        requiredScopeIncomplete ?? this.requiredScopeIncomplete,
    followUpRequired: followUpRequired ?? this.followUpRequired,
  );
  SyncFactRow copyWithCompanion(SyncFactRowsCompanion data) {
    return SyncFactRow(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      lastSuccessfulSyncAt: data.lastSuccessfulSyncAt.present
          ? data.lastSuccessfulSyncAt.value
          : this.lastSuccessfulSyncAt,
      latestFailureReason: data.latestFailureReason.present
          ? data.latestFailureReason.value
          : this.latestFailureReason,
      latestFailureAt: data.latestFailureAt.present
          ? data.latestFailureAt.value
          : this.latestFailureAt,
      latestFailureDiagnosticCode: data.latestFailureDiagnosticCode.present
          ? data.latestFailureDiagnosticCode.value
          : this.latestFailureDiagnosticCode,
      latestFailureAction: data.latestFailureAction.present
          ? data.latestFailureAction.value
          : this.latestFailureAction,
      pendingCount: data.pendingCount.present
          ? data.pendingCount.value
          : this.pendingCount,
      inFlightCount: data.inFlightCount.present
          ? data.inFlightCount.value
          : this.inFlightCount,
      uncertainCount: data.uncertainCount.present
          ? data.uncertainCount.value
          : this.uncertainCount,
      failedCount: data.failedCount.present
          ? data.failedCount.value
          : this.failedCount,
      reauthorizationRequired: data.reauthorizationRequired.present
          ? data.reauthorizationRequired.value
          : this.reauthorizationRequired,
      retryWaiting: data.retryWaiting.present
          ? data.retryWaiting.value
          : this.retryWaiting,
      automaticRetryExhausted: data.automaticRetryExhausted.present
          ? data.automaticRetryExhausted.value
          : this.automaticRetryExhausted,
      retryEpisodeStartedAt: data.retryEpisodeStartedAt.present
          ? data.retryEpisodeStartedAt.value
          : this.retryEpisodeStartedAt,
      retryEpisodeDeadlineAt: data.retryEpisodeDeadlineAt.present
          ? data.retryEpisodeDeadlineAt.value
          : this.retryEpisodeDeadlineAt,
      retryNextAttemptAt: data.retryNextAttemptAt.present
          ? data.retryNextAttemptAt.value
          : this.retryNextAttemptAt,
      retryServerNotBeforeAt: data.retryServerNotBeforeAt.present
          ? data.retryServerNotBeforeAt.value
          : this.retryServerNotBeforeAt,
      retryLastObservedAt: data.retryLastObservedAt.present
          ? data.retryLastObservedAt.value
          : this.retryLastObservedAt,
      retryAttemptCount: data.retryAttemptCount.present
          ? data.retryAttemptCount.value
          : this.retryAttemptCount,
      requiredScopeIncomplete: data.requiredScopeIncomplete.present
          ? data.requiredScopeIncomplete.value
          : this.requiredScopeIncomplete,
      followUpRequired: data.followUpRequired.present
          ? data.followUpRequired.value
          : this.followUpRequired,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncFactRow(')
          ..write('accountId: $accountId, ')
          ..write('lastSuccessfulSyncAt: $lastSuccessfulSyncAt, ')
          ..write('latestFailureReason: $latestFailureReason, ')
          ..write('latestFailureAt: $latestFailureAt, ')
          ..write('latestFailureDiagnosticCode: $latestFailureDiagnosticCode, ')
          ..write('latestFailureAction: $latestFailureAction, ')
          ..write('pendingCount: $pendingCount, ')
          ..write('inFlightCount: $inFlightCount, ')
          ..write('uncertainCount: $uncertainCount, ')
          ..write('failedCount: $failedCount, ')
          ..write('reauthorizationRequired: $reauthorizationRequired, ')
          ..write('retryWaiting: $retryWaiting, ')
          ..write('automaticRetryExhausted: $automaticRetryExhausted, ')
          ..write('retryEpisodeStartedAt: $retryEpisodeStartedAt, ')
          ..write('retryEpisodeDeadlineAt: $retryEpisodeDeadlineAt, ')
          ..write('retryNextAttemptAt: $retryNextAttemptAt, ')
          ..write('retryServerNotBeforeAt: $retryServerNotBeforeAt, ')
          ..write('retryLastObservedAt: $retryLastObservedAt, ')
          ..write('retryAttemptCount: $retryAttemptCount, ')
          ..write('requiredScopeIncomplete: $requiredScopeIncomplete, ')
          ..write('followUpRequired: $followUpRequired')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    accountId,
    lastSuccessfulSyncAt,
    latestFailureReason,
    latestFailureAt,
    latestFailureDiagnosticCode,
    latestFailureAction,
    pendingCount,
    inFlightCount,
    uncertainCount,
    failedCount,
    reauthorizationRequired,
    retryWaiting,
    automaticRetryExhausted,
    retryEpisodeStartedAt,
    retryEpisodeDeadlineAt,
    retryNextAttemptAt,
    retryServerNotBeforeAt,
    retryLastObservedAt,
    retryAttemptCount,
    requiredScopeIncomplete,
    followUpRequired,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncFactRow &&
          other.accountId == this.accountId &&
          other.lastSuccessfulSyncAt == this.lastSuccessfulSyncAt &&
          other.latestFailureReason == this.latestFailureReason &&
          other.latestFailureAt == this.latestFailureAt &&
          other.latestFailureDiagnosticCode ==
              this.latestFailureDiagnosticCode &&
          other.latestFailureAction == this.latestFailureAction &&
          other.pendingCount == this.pendingCount &&
          other.inFlightCount == this.inFlightCount &&
          other.uncertainCount == this.uncertainCount &&
          other.failedCount == this.failedCount &&
          other.reauthorizationRequired == this.reauthorizationRequired &&
          other.retryWaiting == this.retryWaiting &&
          other.automaticRetryExhausted == this.automaticRetryExhausted &&
          other.retryEpisodeStartedAt == this.retryEpisodeStartedAt &&
          other.retryEpisodeDeadlineAt == this.retryEpisodeDeadlineAt &&
          other.retryNextAttemptAt == this.retryNextAttemptAt &&
          other.retryServerNotBeforeAt == this.retryServerNotBeforeAt &&
          other.retryLastObservedAt == this.retryLastObservedAt &&
          other.retryAttemptCount == this.retryAttemptCount &&
          other.requiredScopeIncomplete == this.requiredScopeIncomplete &&
          other.followUpRequired == this.followUpRequired);
}

class SyncFactRowsCompanion extends UpdateCompanion<SyncFactRow> {
  final Value<int> accountId;
  final Value<DateTime?> lastSuccessfulSyncAt;
  final Value<String?> latestFailureReason;
  final Value<DateTime?> latestFailureAt;
  final Value<String?> latestFailureDiagnosticCode;
  final Value<String?> latestFailureAction;
  final Value<int> pendingCount;
  final Value<int> inFlightCount;
  final Value<int> uncertainCount;
  final Value<int> failedCount;
  final Value<bool> reauthorizationRequired;
  final Value<bool> retryWaiting;
  final Value<bool> automaticRetryExhausted;
  final Value<DateTime?> retryEpisodeStartedAt;
  final Value<DateTime?> retryEpisodeDeadlineAt;
  final Value<DateTime?> retryNextAttemptAt;
  final Value<DateTime?> retryServerNotBeforeAt;
  final Value<DateTime?> retryLastObservedAt;
  final Value<int> retryAttemptCount;
  final Value<bool> requiredScopeIncomplete;
  final Value<bool> followUpRequired;
  const SyncFactRowsCompanion({
    this.accountId = const Value.absent(),
    this.lastSuccessfulSyncAt = const Value.absent(),
    this.latestFailureReason = const Value.absent(),
    this.latestFailureAt = const Value.absent(),
    this.latestFailureDiagnosticCode = const Value.absent(),
    this.latestFailureAction = const Value.absent(),
    this.pendingCount = const Value.absent(),
    this.inFlightCount = const Value.absent(),
    this.uncertainCount = const Value.absent(),
    this.failedCount = const Value.absent(),
    this.reauthorizationRequired = const Value.absent(),
    this.retryWaiting = const Value.absent(),
    this.automaticRetryExhausted = const Value.absent(),
    this.retryEpisodeStartedAt = const Value.absent(),
    this.retryEpisodeDeadlineAt = const Value.absent(),
    this.retryNextAttemptAt = const Value.absent(),
    this.retryServerNotBeforeAt = const Value.absent(),
    this.retryLastObservedAt = const Value.absent(),
    this.retryAttemptCount = const Value.absent(),
    this.requiredScopeIncomplete = const Value.absent(),
    this.followUpRequired = const Value.absent(),
  });
  SyncFactRowsCompanion.insert({
    this.accountId = const Value.absent(),
    this.lastSuccessfulSyncAt = const Value.absent(),
    this.latestFailureReason = const Value.absent(),
    this.latestFailureAt = const Value.absent(),
    this.latestFailureDiagnosticCode = const Value.absent(),
    this.latestFailureAction = const Value.absent(),
    this.pendingCount = const Value.absent(),
    this.inFlightCount = const Value.absent(),
    this.uncertainCount = const Value.absent(),
    this.failedCount = const Value.absent(),
    this.reauthorizationRequired = const Value.absent(),
    this.retryWaiting = const Value.absent(),
    this.automaticRetryExhausted = const Value.absent(),
    this.retryEpisodeStartedAt = const Value.absent(),
    this.retryEpisodeDeadlineAt = const Value.absent(),
    this.retryNextAttemptAt = const Value.absent(),
    this.retryServerNotBeforeAt = const Value.absent(),
    this.retryLastObservedAt = const Value.absent(),
    this.retryAttemptCount = const Value.absent(),
    this.requiredScopeIncomplete = const Value.absent(),
    this.followUpRequired = const Value.absent(),
  });
  static Insertable<SyncFactRow> custom({
    Expression<int>? accountId,
    Expression<DateTime>? lastSuccessfulSyncAt,
    Expression<String>? latestFailureReason,
    Expression<DateTime>? latestFailureAt,
    Expression<String>? latestFailureDiagnosticCode,
    Expression<String>? latestFailureAction,
    Expression<int>? pendingCount,
    Expression<int>? inFlightCount,
    Expression<int>? uncertainCount,
    Expression<int>? failedCount,
    Expression<bool>? reauthorizationRequired,
    Expression<bool>? retryWaiting,
    Expression<bool>? automaticRetryExhausted,
    Expression<DateTime>? retryEpisodeStartedAt,
    Expression<DateTime>? retryEpisodeDeadlineAt,
    Expression<DateTime>? retryNextAttemptAt,
    Expression<DateTime>? retryServerNotBeforeAt,
    Expression<DateTime>? retryLastObservedAt,
    Expression<int>? retryAttemptCount,
    Expression<bool>? requiredScopeIncomplete,
    Expression<bool>? followUpRequired,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (lastSuccessfulSyncAt != null)
        'last_successful_sync_at': lastSuccessfulSyncAt,
      if (latestFailureReason != null)
        'latest_failure_reason': latestFailureReason,
      if (latestFailureAt != null) 'latest_failure_at': latestFailureAt,
      if (latestFailureDiagnosticCode != null)
        'latest_failure_diagnostic_code': latestFailureDiagnosticCode,
      if (latestFailureAction != null)
        'latest_failure_action': latestFailureAction,
      if (pendingCount != null) 'pending_count': pendingCount,
      if (inFlightCount != null) 'in_flight_count': inFlightCount,
      if (uncertainCount != null) 'uncertain_count': uncertainCount,
      if (failedCount != null) 'failed_count': failedCount,
      if (reauthorizationRequired != null)
        'reauthorization_required': reauthorizationRequired,
      if (retryWaiting != null) 'retry_waiting': retryWaiting,
      if (automaticRetryExhausted != null)
        'automatic_retry_exhausted': automaticRetryExhausted,
      if (retryEpisodeStartedAt != null)
        'retry_episode_started_at': retryEpisodeStartedAt,
      if (retryEpisodeDeadlineAt != null)
        'retry_episode_deadline_at': retryEpisodeDeadlineAt,
      if (retryNextAttemptAt != null)
        'retry_next_attempt_at': retryNextAttemptAt,
      if (retryServerNotBeforeAt != null)
        'retry_server_not_before_at': retryServerNotBeforeAt,
      if (retryLastObservedAt != null)
        'retry_last_observed_at': retryLastObservedAt,
      if (retryAttemptCount != null) 'retry_attempt_count': retryAttemptCount,
      if (requiredScopeIncomplete != null)
        'required_scope_incomplete': requiredScopeIncomplete,
      if (followUpRequired != null) 'follow_up_required': followUpRequired,
    });
  }

  SyncFactRowsCompanion copyWith({
    Value<int>? accountId,
    Value<DateTime?>? lastSuccessfulSyncAt,
    Value<String?>? latestFailureReason,
    Value<DateTime?>? latestFailureAt,
    Value<String?>? latestFailureDiagnosticCode,
    Value<String?>? latestFailureAction,
    Value<int>? pendingCount,
    Value<int>? inFlightCount,
    Value<int>? uncertainCount,
    Value<int>? failedCount,
    Value<bool>? reauthorizationRequired,
    Value<bool>? retryWaiting,
    Value<bool>? automaticRetryExhausted,
    Value<DateTime?>? retryEpisodeStartedAt,
    Value<DateTime?>? retryEpisodeDeadlineAt,
    Value<DateTime?>? retryNextAttemptAt,
    Value<DateTime?>? retryServerNotBeforeAt,
    Value<DateTime?>? retryLastObservedAt,
    Value<int>? retryAttemptCount,
    Value<bool>? requiredScopeIncomplete,
    Value<bool>? followUpRequired,
  }) {
    return SyncFactRowsCompanion(
      accountId: accountId ?? this.accountId,
      lastSuccessfulSyncAt: lastSuccessfulSyncAt ?? this.lastSuccessfulSyncAt,
      latestFailureReason: latestFailureReason ?? this.latestFailureReason,
      latestFailureAt: latestFailureAt ?? this.latestFailureAt,
      latestFailureDiagnosticCode:
          latestFailureDiagnosticCode ?? this.latestFailureDiagnosticCode,
      latestFailureAction: latestFailureAction ?? this.latestFailureAction,
      pendingCount: pendingCount ?? this.pendingCount,
      inFlightCount: inFlightCount ?? this.inFlightCount,
      uncertainCount: uncertainCount ?? this.uncertainCount,
      failedCount: failedCount ?? this.failedCount,
      reauthorizationRequired:
          reauthorizationRequired ?? this.reauthorizationRequired,
      retryWaiting: retryWaiting ?? this.retryWaiting,
      automaticRetryExhausted:
          automaticRetryExhausted ?? this.automaticRetryExhausted,
      retryEpisodeStartedAt:
          retryEpisodeStartedAt ?? this.retryEpisodeStartedAt,
      retryEpisodeDeadlineAt:
          retryEpisodeDeadlineAt ?? this.retryEpisodeDeadlineAt,
      retryNextAttemptAt: retryNextAttemptAt ?? this.retryNextAttemptAt,
      retryServerNotBeforeAt:
          retryServerNotBeforeAt ?? this.retryServerNotBeforeAt,
      retryLastObservedAt: retryLastObservedAt ?? this.retryLastObservedAt,
      retryAttemptCount: retryAttemptCount ?? this.retryAttemptCount,
      requiredScopeIncomplete:
          requiredScopeIncomplete ?? this.requiredScopeIncomplete,
      followUpRequired: followUpRequired ?? this.followUpRequired,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    if (lastSuccessfulSyncAt.present) {
      map['last_successful_sync_at'] = Variable<DateTime>(
        lastSuccessfulSyncAt.value,
      );
    }
    if (latestFailureReason.present) {
      map['latest_failure_reason'] = Variable<String>(
        latestFailureReason.value,
      );
    }
    if (latestFailureAt.present) {
      map['latest_failure_at'] = Variable<DateTime>(latestFailureAt.value);
    }
    if (latestFailureDiagnosticCode.present) {
      map['latest_failure_diagnostic_code'] = Variable<String>(
        latestFailureDiagnosticCode.value,
      );
    }
    if (latestFailureAction.present) {
      map['latest_failure_action'] = Variable<String>(
        latestFailureAction.value,
      );
    }
    if (pendingCount.present) {
      map['pending_count'] = Variable<int>(pendingCount.value);
    }
    if (inFlightCount.present) {
      map['in_flight_count'] = Variable<int>(inFlightCount.value);
    }
    if (uncertainCount.present) {
      map['uncertain_count'] = Variable<int>(uncertainCount.value);
    }
    if (failedCount.present) {
      map['failed_count'] = Variable<int>(failedCount.value);
    }
    if (reauthorizationRequired.present) {
      map['reauthorization_required'] = Variable<bool>(
        reauthorizationRequired.value,
      );
    }
    if (retryWaiting.present) {
      map['retry_waiting'] = Variable<bool>(retryWaiting.value);
    }
    if (automaticRetryExhausted.present) {
      map['automatic_retry_exhausted'] = Variable<bool>(
        automaticRetryExhausted.value,
      );
    }
    if (retryEpisodeStartedAt.present) {
      map['retry_episode_started_at'] = Variable<DateTime>(
        retryEpisodeStartedAt.value,
      );
    }
    if (retryEpisodeDeadlineAt.present) {
      map['retry_episode_deadline_at'] = Variable<DateTime>(
        retryEpisodeDeadlineAt.value,
      );
    }
    if (retryNextAttemptAt.present) {
      map['retry_next_attempt_at'] = Variable<DateTime>(
        retryNextAttemptAt.value,
      );
    }
    if (retryServerNotBeforeAt.present) {
      map['retry_server_not_before_at'] = Variable<DateTime>(
        retryServerNotBeforeAt.value,
      );
    }
    if (retryLastObservedAt.present) {
      map['retry_last_observed_at'] = Variable<DateTime>(
        retryLastObservedAt.value,
      );
    }
    if (retryAttemptCount.present) {
      map['retry_attempt_count'] = Variable<int>(retryAttemptCount.value);
    }
    if (requiredScopeIncomplete.present) {
      map['required_scope_incomplete'] = Variable<bool>(
        requiredScopeIncomplete.value,
      );
    }
    if (followUpRequired.present) {
      map['follow_up_required'] = Variable<bool>(followUpRequired.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncFactRowsCompanion(')
          ..write('accountId: $accountId, ')
          ..write('lastSuccessfulSyncAt: $lastSuccessfulSyncAt, ')
          ..write('latestFailureReason: $latestFailureReason, ')
          ..write('latestFailureAt: $latestFailureAt, ')
          ..write('latestFailureDiagnosticCode: $latestFailureDiagnosticCode, ')
          ..write('latestFailureAction: $latestFailureAction, ')
          ..write('pendingCount: $pendingCount, ')
          ..write('inFlightCount: $inFlightCount, ')
          ..write('uncertainCount: $uncertainCount, ')
          ..write('failedCount: $failedCount, ')
          ..write('reauthorizationRequired: $reauthorizationRequired, ')
          ..write('retryWaiting: $retryWaiting, ')
          ..write('automaticRetryExhausted: $automaticRetryExhausted, ')
          ..write('retryEpisodeStartedAt: $retryEpisodeStartedAt, ')
          ..write('retryEpisodeDeadlineAt: $retryEpisodeDeadlineAt, ')
          ..write('retryNextAttemptAt: $retryNextAttemptAt, ')
          ..write('retryServerNotBeforeAt: $retryServerNotBeforeAt, ')
          ..write('retryLastObservedAt: $retryLastObservedAt, ')
          ..write('retryAttemptCount: $retryAttemptCount, ')
          ..write('requiredScopeIncomplete: $requiredScopeIncomplete, ')
          ..write('followUpRequired: $followUpRequired')
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
  late final $DesiredStateRowsTable desiredStateRows = $DesiredStateRowsTable(
    this,
  );
  late final $DesiredStateDependencyRowsTable desiredStateDependencyRows =
      $DesiredStateDependencyRowsTable(this);
  late final $DesiredStateAttemptRowsTable desiredStateAttemptRows =
      $DesiredStateAttemptRowsTable(this);
  late final $SyncRunRowsTable syncRunRows = $SyncRunRowsTable(this);
  late final $TaskDeleteTombstoneRowsTable taskDeleteTombstoneRows =
      $TaskDeleteTombstoneRowsTable(this);
  late final $TaskDeleteSnapshotRowsTable taskDeleteSnapshotRows =
      $TaskDeleteSnapshotRowsTable(this);
  late final $TaskDueChangeGroupRowsTable taskDueChangeGroupRows =
      $TaskDueChangeGroupRowsTable(this);
  late final $TaskDueChangeSnapshotRowsTable taskDueChangeSnapshotRows =
      $TaskDueChangeSnapshotRowsTable(this);
  late final $BulkOperationRowsTable bulkOperationRows =
      $BulkOperationRowsTable(this);
  late final $BulkOperationMemberRowsTable bulkOperationMemberRows =
      $BulkOperationMemberRowsTable(this);
  late final $SyncFactRowsTable syncFactRows = $SyncFactRowsTable(this);
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
    desiredStateRows,
    desiredStateDependencyRows,
    desiredStateAttemptRows,
    syncRunRows,
    taskDeleteTombstoneRows,
    taskDeleteSnapshotRows,
    taskDueChangeGroupRows,
    taskDueChangeSnapshotRows,
    bulkOperationRows,
    bulkOperationMemberRows,
    syncFactRows,
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
      Value<int> nextLocalCausalSequence,
    });
typedef $$AccountPreferenceRowsTableUpdateCompanionBuilder =
    AccountPreferenceRowsCompanion Function({
      Value<int> accountId,
      Value<bool> syncEnabled,
      Value<int?> defaultTaskListId,
      Value<int> nextLocalCausalSequence,
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

  ColumnFilters<int> get nextLocalCausalSequence => $composableBuilder(
    column: $table.nextLocalCausalSequence,
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

  ColumnOrderings<int> get nextLocalCausalSequence => $composableBuilder(
    column: $table.nextLocalCausalSequence,
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

  GeneratedColumn<int> get nextLocalCausalSequence => $composableBuilder(
    column: $table.nextLocalCausalSequence,
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
                Value<int> nextLocalCausalSequence = const Value.absent(),
              }) => AccountPreferenceRowsCompanion(
                accountId: accountId,
                syncEnabled: syncEnabled,
                defaultTaskListId: defaultTaskListId,
                nextLocalCausalSequence: nextLocalCausalSequence,
              ),
          createCompanionCallback:
              ({
                Value<int> accountId = const Value.absent(),
                Value<bool> syncEnabled = const Value.absent(),
                Value<int?> defaultTaskListId = const Value.absent(),
                Value<int> nextLocalCausalSequence = const Value.absent(),
              }) => AccountPreferenceRowsCompanion.insert(
                accountId: accountId,
                syncEnabled: syncEnabled,
                defaultTaskListId: defaultTaskListId,
                nextLocalCausalSequence: nextLocalCausalSequence,
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
typedef $$DesiredStateRowsTableCreateCompanionBuilder =
    DesiredStateRowsCompanion Function({
      Value<int> id,
      required int accountId,
      required String targetKey,
      required String resourceType,
      Value<int?> targetTaskListId,
      Value<int?> targetTaskId,
      required String desiredLifecycle,
      Value<String?> title,
      Value<String?> notes,
      Value<String?> status,
      Value<int?> dueEpochDay,
      Value<int?> desiredTaskListId,
      Value<int?> desiredParentTaskId,
      Value<int?> desiredPreviousTaskId,
      Value<bool> contentDirty,
      Value<bool> structureDirty,
      Value<bool> lifecycleDirty,
      Value<DateTime?> localModifiedAt,
      Value<DateTime?> notBefore,
      required int generation,
      required int localCausalSequence,
      required String state,
      Value<String?> baseRemoteId,
      Value<String?> baseEtag,
      Value<DateTime?> baseRemoteUpdatedAt,
      Value<String?> baseObservedPublicationId,
      Value<String?> baseTitle,
      Value<String?> baseNotes,
      Value<String?> baseStatus,
      Value<int?> baseDueEpochDay,
      Value<int?> baseTaskListId,
      Value<int?> baseParentTaskId,
      Value<int?> basePreviousTaskId,
      Value<String?> basePosition,
      Value<String?> baseSiblingOrder,
      Value<String?> failureCode,
      required DateTime createdAt,
      required DateTime lastTransitionAt,
    });
typedef $$DesiredStateRowsTableUpdateCompanionBuilder =
    DesiredStateRowsCompanion Function({
      Value<int> id,
      Value<int> accountId,
      Value<String> targetKey,
      Value<String> resourceType,
      Value<int?> targetTaskListId,
      Value<int?> targetTaskId,
      Value<String> desiredLifecycle,
      Value<String?> title,
      Value<String?> notes,
      Value<String?> status,
      Value<int?> dueEpochDay,
      Value<int?> desiredTaskListId,
      Value<int?> desiredParentTaskId,
      Value<int?> desiredPreviousTaskId,
      Value<bool> contentDirty,
      Value<bool> structureDirty,
      Value<bool> lifecycleDirty,
      Value<DateTime?> localModifiedAt,
      Value<DateTime?> notBefore,
      Value<int> generation,
      Value<int> localCausalSequence,
      Value<String> state,
      Value<String?> baseRemoteId,
      Value<String?> baseEtag,
      Value<DateTime?> baseRemoteUpdatedAt,
      Value<String?> baseObservedPublicationId,
      Value<String?> baseTitle,
      Value<String?> baseNotes,
      Value<String?> baseStatus,
      Value<int?> baseDueEpochDay,
      Value<int?> baseTaskListId,
      Value<int?> baseParentTaskId,
      Value<int?> basePreviousTaskId,
      Value<String?> basePosition,
      Value<String?> baseSiblingOrder,
      Value<String?> failureCode,
      Value<DateTime> createdAt,
      Value<DateTime> lastTransitionAt,
    });

class $$DesiredStateRowsTableFilterComposer
    extends Composer<_$AppDatabase, $DesiredStateRowsTable> {
  $$DesiredStateRowsTableFilterComposer({
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

  ColumnFilters<String> get targetKey => $composableBuilder(
    column: $table.targetKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get resourceType => $composableBuilder(
    column: $table.resourceType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get targetTaskListId => $composableBuilder(
    column: $table.targetTaskListId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get targetTaskId => $composableBuilder(
    column: $table.targetTaskId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get desiredLifecycle => $composableBuilder(
    column: $table.desiredLifecycle,
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

  ColumnFilters<int> get desiredTaskListId => $composableBuilder(
    column: $table.desiredTaskListId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get desiredParentTaskId => $composableBuilder(
    column: $table.desiredParentTaskId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get desiredPreviousTaskId => $composableBuilder(
    column: $table.desiredPreviousTaskId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get contentDirty => $composableBuilder(
    column: $table.contentDirty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get structureDirty => $composableBuilder(
    column: $table.structureDirty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get lifecycleDirty => $composableBuilder(
    column: $table.lifecycleDirty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get localModifiedAt => $composableBuilder(
    column: $table.localModifiedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get notBefore => $composableBuilder(
    column: $table.notBefore,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get localCausalSequence => $composableBuilder(
    column: $table.localCausalSequence,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseRemoteId => $composableBuilder(
    column: $table.baseRemoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseEtag => $composableBuilder(
    column: $table.baseEtag,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get baseRemoteUpdatedAt => $composableBuilder(
    column: $table.baseRemoteUpdatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseObservedPublicationId => $composableBuilder(
    column: $table.baseObservedPublicationId,
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

  ColumnFilters<String> get baseStatus => $composableBuilder(
    column: $table.baseStatus,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get baseDueEpochDay => $composableBuilder(
    column: $table.baseDueEpochDay,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get baseTaskListId => $composableBuilder(
    column: $table.baseTaskListId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get baseParentTaskId => $composableBuilder(
    column: $table.baseParentTaskId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get basePreviousTaskId => $composableBuilder(
    column: $table.basePreviousTaskId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get basePosition => $composableBuilder(
    column: $table.basePosition,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseSiblingOrder => $composableBuilder(
    column: $table.baseSiblingOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get failureCode => $composableBuilder(
    column: $table.failureCode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastTransitionAt => $composableBuilder(
    column: $table.lastTransitionAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DesiredStateRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $DesiredStateRowsTable> {
  $$DesiredStateRowsTableOrderingComposer({
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

  ColumnOrderings<String> get targetKey => $composableBuilder(
    column: $table.targetKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get resourceType => $composableBuilder(
    column: $table.resourceType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get targetTaskListId => $composableBuilder(
    column: $table.targetTaskListId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get targetTaskId => $composableBuilder(
    column: $table.targetTaskId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get desiredLifecycle => $composableBuilder(
    column: $table.desiredLifecycle,
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

  ColumnOrderings<int> get desiredTaskListId => $composableBuilder(
    column: $table.desiredTaskListId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get desiredParentTaskId => $composableBuilder(
    column: $table.desiredParentTaskId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get desiredPreviousTaskId => $composableBuilder(
    column: $table.desiredPreviousTaskId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get contentDirty => $composableBuilder(
    column: $table.contentDirty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get structureDirty => $composableBuilder(
    column: $table.structureDirty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get lifecycleDirty => $composableBuilder(
    column: $table.lifecycleDirty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get localModifiedAt => $composableBuilder(
    column: $table.localModifiedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get notBefore => $composableBuilder(
    column: $table.notBefore,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get localCausalSequence => $composableBuilder(
    column: $table.localCausalSequence,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseRemoteId => $composableBuilder(
    column: $table.baseRemoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseEtag => $composableBuilder(
    column: $table.baseEtag,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get baseRemoteUpdatedAt => $composableBuilder(
    column: $table.baseRemoteUpdatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseObservedPublicationId => $composableBuilder(
    column: $table.baseObservedPublicationId,
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

  ColumnOrderings<String> get baseStatus => $composableBuilder(
    column: $table.baseStatus,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get baseDueEpochDay => $composableBuilder(
    column: $table.baseDueEpochDay,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get baseTaskListId => $composableBuilder(
    column: $table.baseTaskListId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get baseParentTaskId => $composableBuilder(
    column: $table.baseParentTaskId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get basePreviousTaskId => $composableBuilder(
    column: $table.basePreviousTaskId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get basePosition => $composableBuilder(
    column: $table.basePosition,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseSiblingOrder => $composableBuilder(
    column: $table.baseSiblingOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get failureCode => $composableBuilder(
    column: $table.failureCode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastTransitionAt => $composableBuilder(
    column: $table.lastTransitionAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DesiredStateRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $DesiredStateRowsTable> {
  $$DesiredStateRowsTableAnnotationComposer({
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

  GeneratedColumn<String> get targetKey =>
      $composableBuilder(column: $table.targetKey, builder: (column) => column);

  GeneratedColumn<String> get resourceType => $composableBuilder(
    column: $table.resourceType,
    builder: (column) => column,
  );

  GeneratedColumn<int> get targetTaskListId => $composableBuilder(
    column: $table.targetTaskListId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get targetTaskId => $composableBuilder(
    column: $table.targetTaskId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get desiredLifecycle => $composableBuilder(
    column: $table.desiredLifecycle,
    builder: (column) => column,
  );

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

  GeneratedColumn<int> get desiredTaskListId => $composableBuilder(
    column: $table.desiredTaskListId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get desiredParentTaskId => $composableBuilder(
    column: $table.desiredParentTaskId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get desiredPreviousTaskId => $composableBuilder(
    column: $table.desiredPreviousTaskId,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get contentDirty => $composableBuilder(
    column: $table.contentDirty,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get structureDirty => $composableBuilder(
    column: $table.structureDirty,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get lifecycleDirty => $composableBuilder(
    column: $table.lifecycleDirty,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get localModifiedAt => $composableBuilder(
    column: $table.localModifiedAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get notBefore =>
      $composableBuilder(column: $table.notBefore, builder: (column) => column);

  GeneratedColumn<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => column,
  );

  GeneratedColumn<int> get localCausalSequence => $composableBuilder(
    column: $table.localCausalSequence,
    builder: (column) => column,
  );

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<String> get baseRemoteId => $composableBuilder(
    column: $table.baseRemoteId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get baseEtag =>
      $composableBuilder(column: $table.baseEtag, builder: (column) => column);

  GeneratedColumn<DateTime> get baseRemoteUpdatedAt => $composableBuilder(
    column: $table.baseRemoteUpdatedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get baseObservedPublicationId => $composableBuilder(
    column: $table.baseObservedPublicationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get baseTitle =>
      $composableBuilder(column: $table.baseTitle, builder: (column) => column);

  GeneratedColumn<String> get baseNotes =>
      $composableBuilder(column: $table.baseNotes, builder: (column) => column);

  GeneratedColumn<String> get baseStatus => $composableBuilder(
    column: $table.baseStatus,
    builder: (column) => column,
  );

  GeneratedColumn<int> get baseDueEpochDay => $composableBuilder(
    column: $table.baseDueEpochDay,
    builder: (column) => column,
  );

  GeneratedColumn<int> get baseTaskListId => $composableBuilder(
    column: $table.baseTaskListId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get baseParentTaskId => $composableBuilder(
    column: $table.baseParentTaskId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get basePreviousTaskId => $composableBuilder(
    column: $table.basePreviousTaskId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get basePosition => $composableBuilder(
    column: $table.basePosition,
    builder: (column) => column,
  );

  GeneratedColumn<String> get baseSiblingOrder => $composableBuilder(
    column: $table.baseSiblingOrder,
    builder: (column) => column,
  );

  GeneratedColumn<String> get failureCode => $composableBuilder(
    column: $table.failureCode,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get lastTransitionAt => $composableBuilder(
    column: $table.lastTransitionAt,
    builder: (column) => column,
  );
}

class $$DesiredStateRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DesiredStateRowsTable,
          DesiredStateRow,
          $$DesiredStateRowsTableFilterComposer,
          $$DesiredStateRowsTableOrderingComposer,
          $$DesiredStateRowsTableAnnotationComposer,
          $$DesiredStateRowsTableCreateCompanionBuilder,
          $$DesiredStateRowsTableUpdateCompanionBuilder,
          (
            DesiredStateRow,
            BaseReferences<
              _$AppDatabase,
              $DesiredStateRowsTable,
              DesiredStateRow
            >,
          ),
          DesiredStateRow,
          PrefetchHooks Function()
        > {
  $$DesiredStateRowsTableTableManager(
    _$AppDatabase db,
    $DesiredStateRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DesiredStateRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DesiredStateRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DesiredStateRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> accountId = const Value.absent(),
                Value<String> targetKey = const Value.absent(),
                Value<String> resourceType = const Value.absent(),
                Value<int?> targetTaskListId = const Value.absent(),
                Value<int?> targetTaskId = const Value.absent(),
                Value<String> desiredLifecycle = const Value.absent(),
                Value<String?> title = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<String?> status = const Value.absent(),
                Value<int?> dueEpochDay = const Value.absent(),
                Value<int?> desiredTaskListId = const Value.absent(),
                Value<int?> desiredParentTaskId = const Value.absent(),
                Value<int?> desiredPreviousTaskId = const Value.absent(),
                Value<bool> contentDirty = const Value.absent(),
                Value<bool> structureDirty = const Value.absent(),
                Value<bool> lifecycleDirty = const Value.absent(),
                Value<DateTime?> localModifiedAt = const Value.absent(),
                Value<DateTime?> notBefore = const Value.absent(),
                Value<int> generation = const Value.absent(),
                Value<int> localCausalSequence = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<String?> baseRemoteId = const Value.absent(),
                Value<String?> baseEtag = const Value.absent(),
                Value<DateTime?> baseRemoteUpdatedAt = const Value.absent(),
                Value<String?> baseObservedPublicationId = const Value.absent(),
                Value<String?> baseTitle = const Value.absent(),
                Value<String?> baseNotes = const Value.absent(),
                Value<String?> baseStatus = const Value.absent(),
                Value<int?> baseDueEpochDay = const Value.absent(),
                Value<int?> baseTaskListId = const Value.absent(),
                Value<int?> baseParentTaskId = const Value.absent(),
                Value<int?> basePreviousTaskId = const Value.absent(),
                Value<String?> basePosition = const Value.absent(),
                Value<String?> baseSiblingOrder = const Value.absent(),
                Value<String?> failureCode = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> lastTransitionAt = const Value.absent(),
              }) => DesiredStateRowsCompanion(
                id: id,
                accountId: accountId,
                targetKey: targetKey,
                resourceType: resourceType,
                targetTaskListId: targetTaskListId,
                targetTaskId: targetTaskId,
                desiredLifecycle: desiredLifecycle,
                title: title,
                notes: notes,
                status: status,
                dueEpochDay: dueEpochDay,
                desiredTaskListId: desiredTaskListId,
                desiredParentTaskId: desiredParentTaskId,
                desiredPreviousTaskId: desiredPreviousTaskId,
                contentDirty: contentDirty,
                structureDirty: structureDirty,
                lifecycleDirty: lifecycleDirty,
                localModifiedAt: localModifiedAt,
                notBefore: notBefore,
                generation: generation,
                localCausalSequence: localCausalSequence,
                state: state,
                baseRemoteId: baseRemoteId,
                baseEtag: baseEtag,
                baseRemoteUpdatedAt: baseRemoteUpdatedAt,
                baseObservedPublicationId: baseObservedPublicationId,
                baseTitle: baseTitle,
                baseNotes: baseNotes,
                baseStatus: baseStatus,
                baseDueEpochDay: baseDueEpochDay,
                baseTaskListId: baseTaskListId,
                baseParentTaskId: baseParentTaskId,
                basePreviousTaskId: basePreviousTaskId,
                basePosition: basePosition,
                baseSiblingOrder: baseSiblingOrder,
                failureCode: failureCode,
                createdAt: createdAt,
                lastTransitionAt: lastTransitionAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int accountId,
                required String targetKey,
                required String resourceType,
                Value<int?> targetTaskListId = const Value.absent(),
                Value<int?> targetTaskId = const Value.absent(),
                required String desiredLifecycle,
                Value<String?> title = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<String?> status = const Value.absent(),
                Value<int?> dueEpochDay = const Value.absent(),
                Value<int?> desiredTaskListId = const Value.absent(),
                Value<int?> desiredParentTaskId = const Value.absent(),
                Value<int?> desiredPreviousTaskId = const Value.absent(),
                Value<bool> contentDirty = const Value.absent(),
                Value<bool> structureDirty = const Value.absent(),
                Value<bool> lifecycleDirty = const Value.absent(),
                Value<DateTime?> localModifiedAt = const Value.absent(),
                Value<DateTime?> notBefore = const Value.absent(),
                required int generation,
                required int localCausalSequence,
                required String state,
                Value<String?> baseRemoteId = const Value.absent(),
                Value<String?> baseEtag = const Value.absent(),
                Value<DateTime?> baseRemoteUpdatedAt = const Value.absent(),
                Value<String?> baseObservedPublicationId = const Value.absent(),
                Value<String?> baseTitle = const Value.absent(),
                Value<String?> baseNotes = const Value.absent(),
                Value<String?> baseStatus = const Value.absent(),
                Value<int?> baseDueEpochDay = const Value.absent(),
                Value<int?> baseTaskListId = const Value.absent(),
                Value<int?> baseParentTaskId = const Value.absent(),
                Value<int?> basePreviousTaskId = const Value.absent(),
                Value<String?> basePosition = const Value.absent(),
                Value<String?> baseSiblingOrder = const Value.absent(),
                Value<String?> failureCode = const Value.absent(),
                required DateTime createdAt,
                required DateTime lastTransitionAt,
              }) => DesiredStateRowsCompanion.insert(
                id: id,
                accountId: accountId,
                targetKey: targetKey,
                resourceType: resourceType,
                targetTaskListId: targetTaskListId,
                targetTaskId: targetTaskId,
                desiredLifecycle: desiredLifecycle,
                title: title,
                notes: notes,
                status: status,
                dueEpochDay: dueEpochDay,
                desiredTaskListId: desiredTaskListId,
                desiredParentTaskId: desiredParentTaskId,
                desiredPreviousTaskId: desiredPreviousTaskId,
                contentDirty: contentDirty,
                structureDirty: structureDirty,
                lifecycleDirty: lifecycleDirty,
                localModifiedAt: localModifiedAt,
                notBefore: notBefore,
                generation: generation,
                localCausalSequence: localCausalSequence,
                state: state,
                baseRemoteId: baseRemoteId,
                baseEtag: baseEtag,
                baseRemoteUpdatedAt: baseRemoteUpdatedAt,
                baseObservedPublicationId: baseObservedPublicationId,
                baseTitle: baseTitle,
                baseNotes: baseNotes,
                baseStatus: baseStatus,
                baseDueEpochDay: baseDueEpochDay,
                baseTaskListId: baseTaskListId,
                baseParentTaskId: baseParentTaskId,
                basePreviousTaskId: basePreviousTaskId,
                basePosition: basePosition,
                baseSiblingOrder: baseSiblingOrder,
                failureCode: failureCode,
                createdAt: createdAt,
                lastTransitionAt: lastTransitionAt,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DesiredStateRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DesiredStateRowsTable,
      DesiredStateRow,
      $$DesiredStateRowsTableFilterComposer,
      $$DesiredStateRowsTableOrderingComposer,
      $$DesiredStateRowsTableAnnotationComposer,
      $$DesiredStateRowsTableCreateCompanionBuilder,
      $$DesiredStateRowsTableUpdateCompanionBuilder,
      (
        DesiredStateRow,
        BaseReferences<_$AppDatabase, $DesiredStateRowsTable, DesiredStateRow>,
      ),
      DesiredStateRow,
      PrefetchHooks Function()
    >;
typedef $$DesiredStateDependencyRowsTableCreateCompanionBuilder =
    DesiredStateDependencyRowsCompanion Function({
      Value<int> id,
      required int accountId,
      required int desiredStateId,
      required String dependencyKind,
      Value<int?> dependsOnTaskListId,
      Value<int?> dependsOnTaskId,
    });
typedef $$DesiredStateDependencyRowsTableUpdateCompanionBuilder =
    DesiredStateDependencyRowsCompanion Function({
      Value<int> id,
      Value<int> accountId,
      Value<int> desiredStateId,
      Value<String> dependencyKind,
      Value<int?> dependsOnTaskListId,
      Value<int?> dependsOnTaskId,
    });

class $$DesiredStateDependencyRowsTableFilterComposer
    extends Composer<_$AppDatabase, $DesiredStateDependencyRowsTable> {
  $$DesiredStateDependencyRowsTableFilterComposer({
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

  ColumnFilters<int> get desiredStateId => $composableBuilder(
    column: $table.desiredStateId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get dependencyKind => $composableBuilder(
    column: $table.dependencyKind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get dependsOnTaskListId => $composableBuilder(
    column: $table.dependsOnTaskListId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get dependsOnTaskId => $composableBuilder(
    column: $table.dependsOnTaskId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DesiredStateDependencyRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $DesiredStateDependencyRowsTable> {
  $$DesiredStateDependencyRowsTableOrderingComposer({
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

  ColumnOrderings<int> get desiredStateId => $composableBuilder(
    column: $table.desiredStateId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get dependencyKind => $composableBuilder(
    column: $table.dependencyKind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get dependsOnTaskListId => $composableBuilder(
    column: $table.dependsOnTaskListId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get dependsOnTaskId => $composableBuilder(
    column: $table.dependsOnTaskId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DesiredStateDependencyRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $DesiredStateDependencyRowsTable> {
  $$DesiredStateDependencyRowsTableAnnotationComposer({
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

  GeneratedColumn<int> get desiredStateId => $composableBuilder(
    column: $table.desiredStateId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get dependencyKind => $composableBuilder(
    column: $table.dependencyKind,
    builder: (column) => column,
  );

  GeneratedColumn<int> get dependsOnTaskListId => $composableBuilder(
    column: $table.dependsOnTaskListId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get dependsOnTaskId => $composableBuilder(
    column: $table.dependsOnTaskId,
    builder: (column) => column,
  );
}

class $$DesiredStateDependencyRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DesiredStateDependencyRowsTable,
          DesiredStateDependencyRow,
          $$DesiredStateDependencyRowsTableFilterComposer,
          $$DesiredStateDependencyRowsTableOrderingComposer,
          $$DesiredStateDependencyRowsTableAnnotationComposer,
          $$DesiredStateDependencyRowsTableCreateCompanionBuilder,
          $$DesiredStateDependencyRowsTableUpdateCompanionBuilder,
          (
            DesiredStateDependencyRow,
            BaseReferences<
              _$AppDatabase,
              $DesiredStateDependencyRowsTable,
              DesiredStateDependencyRow
            >,
          ),
          DesiredStateDependencyRow,
          PrefetchHooks Function()
        > {
  $$DesiredStateDependencyRowsTableTableManager(
    _$AppDatabase db,
    $DesiredStateDependencyRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DesiredStateDependencyRowsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$DesiredStateDependencyRowsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$DesiredStateDependencyRowsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> accountId = const Value.absent(),
                Value<int> desiredStateId = const Value.absent(),
                Value<String> dependencyKind = const Value.absent(),
                Value<int?> dependsOnTaskListId = const Value.absent(),
                Value<int?> dependsOnTaskId = const Value.absent(),
              }) => DesiredStateDependencyRowsCompanion(
                id: id,
                accountId: accountId,
                desiredStateId: desiredStateId,
                dependencyKind: dependencyKind,
                dependsOnTaskListId: dependsOnTaskListId,
                dependsOnTaskId: dependsOnTaskId,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int accountId,
                required int desiredStateId,
                required String dependencyKind,
                Value<int?> dependsOnTaskListId = const Value.absent(),
                Value<int?> dependsOnTaskId = const Value.absent(),
              }) => DesiredStateDependencyRowsCompanion.insert(
                id: id,
                accountId: accountId,
                desiredStateId: desiredStateId,
                dependencyKind: dependencyKind,
                dependsOnTaskListId: dependsOnTaskListId,
                dependsOnTaskId: dependsOnTaskId,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DesiredStateDependencyRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DesiredStateDependencyRowsTable,
      DesiredStateDependencyRow,
      $$DesiredStateDependencyRowsTableFilterComposer,
      $$DesiredStateDependencyRowsTableOrderingComposer,
      $$DesiredStateDependencyRowsTableAnnotationComposer,
      $$DesiredStateDependencyRowsTableCreateCompanionBuilder,
      $$DesiredStateDependencyRowsTableUpdateCompanionBuilder,
      (
        DesiredStateDependencyRow,
        BaseReferences<
          _$AppDatabase,
          $DesiredStateDependencyRowsTable,
          DesiredStateDependencyRow
        >,
      ),
      DesiredStateDependencyRow,
      PrefetchHooks Function()
    >;
typedef $$DesiredStateAttemptRowsTableCreateCompanionBuilder =
    DesiredStateAttemptRowsCompanion Function({
      Value<int> id,
      required int accountId,
      required int desiredStateId,
      required int generation,
      required String desiredLifecycle,
      Value<String?> title,
      Value<String?> notes,
      Value<String?> status,
      Value<int?> dueEpochDay,
      Value<int?> desiredTaskListId,
      Value<int?> desiredParentTaskId,
      Value<int?> desiredPreviousTaskId,
      Value<String?> baseRemoteId,
      Value<String?> baseEtag,
      Value<DateTime?> baseRemoteUpdatedAt,
      Value<String?> baseObservedPublicationId,
      Value<String?> baseTitle,
      Value<int?> baseTaskListId,
      Value<int?> baseParentTaskId,
      Value<int?> basePreviousTaskId,
      Value<String?> basePosition,
      Value<String?> baseSiblingOrder,
      Value<DateTime?> notBefore,
      required String state,
      Value<String?> failureCode,
      required DateTime claimedAt,
      required DateTime lastTransitionAt,
    });
typedef $$DesiredStateAttemptRowsTableUpdateCompanionBuilder =
    DesiredStateAttemptRowsCompanion Function({
      Value<int> id,
      Value<int> accountId,
      Value<int> desiredStateId,
      Value<int> generation,
      Value<String> desiredLifecycle,
      Value<String?> title,
      Value<String?> notes,
      Value<String?> status,
      Value<int?> dueEpochDay,
      Value<int?> desiredTaskListId,
      Value<int?> desiredParentTaskId,
      Value<int?> desiredPreviousTaskId,
      Value<String?> baseRemoteId,
      Value<String?> baseEtag,
      Value<DateTime?> baseRemoteUpdatedAt,
      Value<String?> baseObservedPublicationId,
      Value<String?> baseTitle,
      Value<int?> baseTaskListId,
      Value<int?> baseParentTaskId,
      Value<int?> basePreviousTaskId,
      Value<String?> basePosition,
      Value<String?> baseSiblingOrder,
      Value<DateTime?> notBefore,
      Value<String> state,
      Value<String?> failureCode,
      Value<DateTime> claimedAt,
      Value<DateTime> lastTransitionAt,
    });

class $$DesiredStateAttemptRowsTableFilterComposer
    extends Composer<_$AppDatabase, $DesiredStateAttemptRowsTable> {
  $$DesiredStateAttemptRowsTableFilterComposer({
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

  ColumnFilters<int> get desiredStateId => $composableBuilder(
    column: $table.desiredStateId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get desiredLifecycle => $composableBuilder(
    column: $table.desiredLifecycle,
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

  ColumnFilters<int> get desiredTaskListId => $composableBuilder(
    column: $table.desiredTaskListId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get desiredParentTaskId => $composableBuilder(
    column: $table.desiredParentTaskId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get desiredPreviousTaskId => $composableBuilder(
    column: $table.desiredPreviousTaskId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseRemoteId => $composableBuilder(
    column: $table.baseRemoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseEtag => $composableBuilder(
    column: $table.baseEtag,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get baseRemoteUpdatedAt => $composableBuilder(
    column: $table.baseRemoteUpdatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseObservedPublicationId => $composableBuilder(
    column: $table.baseObservedPublicationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseTitle => $composableBuilder(
    column: $table.baseTitle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get baseTaskListId => $composableBuilder(
    column: $table.baseTaskListId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get baseParentTaskId => $composableBuilder(
    column: $table.baseParentTaskId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get basePreviousTaskId => $composableBuilder(
    column: $table.basePreviousTaskId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get basePosition => $composableBuilder(
    column: $table.basePosition,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseSiblingOrder => $composableBuilder(
    column: $table.baseSiblingOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get notBefore => $composableBuilder(
    column: $table.notBefore,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get failureCode => $composableBuilder(
    column: $table.failureCode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get claimedAt => $composableBuilder(
    column: $table.claimedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastTransitionAt => $composableBuilder(
    column: $table.lastTransitionAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DesiredStateAttemptRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $DesiredStateAttemptRowsTable> {
  $$DesiredStateAttemptRowsTableOrderingComposer({
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

  ColumnOrderings<int> get desiredStateId => $composableBuilder(
    column: $table.desiredStateId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get desiredLifecycle => $composableBuilder(
    column: $table.desiredLifecycle,
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

  ColumnOrderings<int> get desiredTaskListId => $composableBuilder(
    column: $table.desiredTaskListId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get desiredParentTaskId => $composableBuilder(
    column: $table.desiredParentTaskId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get desiredPreviousTaskId => $composableBuilder(
    column: $table.desiredPreviousTaskId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseRemoteId => $composableBuilder(
    column: $table.baseRemoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseEtag => $composableBuilder(
    column: $table.baseEtag,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get baseRemoteUpdatedAt => $composableBuilder(
    column: $table.baseRemoteUpdatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseObservedPublicationId => $composableBuilder(
    column: $table.baseObservedPublicationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseTitle => $composableBuilder(
    column: $table.baseTitle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get baseTaskListId => $composableBuilder(
    column: $table.baseTaskListId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get baseParentTaskId => $composableBuilder(
    column: $table.baseParentTaskId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get basePreviousTaskId => $composableBuilder(
    column: $table.basePreviousTaskId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get basePosition => $composableBuilder(
    column: $table.basePosition,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseSiblingOrder => $composableBuilder(
    column: $table.baseSiblingOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get notBefore => $composableBuilder(
    column: $table.notBefore,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get failureCode => $composableBuilder(
    column: $table.failureCode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get claimedAt => $composableBuilder(
    column: $table.claimedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastTransitionAt => $composableBuilder(
    column: $table.lastTransitionAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DesiredStateAttemptRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $DesiredStateAttemptRowsTable> {
  $$DesiredStateAttemptRowsTableAnnotationComposer({
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

  GeneratedColumn<int> get desiredStateId => $composableBuilder(
    column: $table.desiredStateId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => column,
  );

  GeneratedColumn<String> get desiredLifecycle => $composableBuilder(
    column: $table.desiredLifecycle,
    builder: (column) => column,
  );

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

  GeneratedColumn<int> get desiredTaskListId => $composableBuilder(
    column: $table.desiredTaskListId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get desiredParentTaskId => $composableBuilder(
    column: $table.desiredParentTaskId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get desiredPreviousTaskId => $composableBuilder(
    column: $table.desiredPreviousTaskId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get baseRemoteId => $composableBuilder(
    column: $table.baseRemoteId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get baseEtag =>
      $composableBuilder(column: $table.baseEtag, builder: (column) => column);

  GeneratedColumn<DateTime> get baseRemoteUpdatedAt => $composableBuilder(
    column: $table.baseRemoteUpdatedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get baseObservedPublicationId => $composableBuilder(
    column: $table.baseObservedPublicationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get baseTitle =>
      $composableBuilder(column: $table.baseTitle, builder: (column) => column);

  GeneratedColumn<int> get baseTaskListId => $composableBuilder(
    column: $table.baseTaskListId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get baseParentTaskId => $composableBuilder(
    column: $table.baseParentTaskId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get basePreviousTaskId => $composableBuilder(
    column: $table.basePreviousTaskId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get basePosition => $composableBuilder(
    column: $table.basePosition,
    builder: (column) => column,
  );

  GeneratedColumn<String> get baseSiblingOrder => $composableBuilder(
    column: $table.baseSiblingOrder,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get notBefore =>
      $composableBuilder(column: $table.notBefore, builder: (column) => column);

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<String> get failureCode => $composableBuilder(
    column: $table.failureCode,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get claimedAt =>
      $composableBuilder(column: $table.claimedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get lastTransitionAt => $composableBuilder(
    column: $table.lastTransitionAt,
    builder: (column) => column,
  );
}

class $$DesiredStateAttemptRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DesiredStateAttemptRowsTable,
          DesiredStateAttemptRow,
          $$DesiredStateAttemptRowsTableFilterComposer,
          $$DesiredStateAttemptRowsTableOrderingComposer,
          $$DesiredStateAttemptRowsTableAnnotationComposer,
          $$DesiredStateAttemptRowsTableCreateCompanionBuilder,
          $$DesiredStateAttemptRowsTableUpdateCompanionBuilder,
          (
            DesiredStateAttemptRow,
            BaseReferences<
              _$AppDatabase,
              $DesiredStateAttemptRowsTable,
              DesiredStateAttemptRow
            >,
          ),
          DesiredStateAttemptRow,
          PrefetchHooks Function()
        > {
  $$DesiredStateAttemptRowsTableTableManager(
    _$AppDatabase db,
    $DesiredStateAttemptRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DesiredStateAttemptRowsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$DesiredStateAttemptRowsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$DesiredStateAttemptRowsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> accountId = const Value.absent(),
                Value<int> desiredStateId = const Value.absent(),
                Value<int> generation = const Value.absent(),
                Value<String> desiredLifecycle = const Value.absent(),
                Value<String?> title = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<String?> status = const Value.absent(),
                Value<int?> dueEpochDay = const Value.absent(),
                Value<int?> desiredTaskListId = const Value.absent(),
                Value<int?> desiredParentTaskId = const Value.absent(),
                Value<int?> desiredPreviousTaskId = const Value.absent(),
                Value<String?> baseRemoteId = const Value.absent(),
                Value<String?> baseEtag = const Value.absent(),
                Value<DateTime?> baseRemoteUpdatedAt = const Value.absent(),
                Value<String?> baseObservedPublicationId = const Value.absent(),
                Value<String?> baseTitle = const Value.absent(),
                Value<int?> baseTaskListId = const Value.absent(),
                Value<int?> baseParentTaskId = const Value.absent(),
                Value<int?> basePreviousTaskId = const Value.absent(),
                Value<String?> basePosition = const Value.absent(),
                Value<String?> baseSiblingOrder = const Value.absent(),
                Value<DateTime?> notBefore = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<String?> failureCode = const Value.absent(),
                Value<DateTime> claimedAt = const Value.absent(),
                Value<DateTime> lastTransitionAt = const Value.absent(),
              }) => DesiredStateAttemptRowsCompanion(
                id: id,
                accountId: accountId,
                desiredStateId: desiredStateId,
                generation: generation,
                desiredLifecycle: desiredLifecycle,
                title: title,
                notes: notes,
                status: status,
                dueEpochDay: dueEpochDay,
                desiredTaskListId: desiredTaskListId,
                desiredParentTaskId: desiredParentTaskId,
                desiredPreviousTaskId: desiredPreviousTaskId,
                baseRemoteId: baseRemoteId,
                baseEtag: baseEtag,
                baseRemoteUpdatedAt: baseRemoteUpdatedAt,
                baseObservedPublicationId: baseObservedPublicationId,
                baseTitle: baseTitle,
                baseTaskListId: baseTaskListId,
                baseParentTaskId: baseParentTaskId,
                basePreviousTaskId: basePreviousTaskId,
                basePosition: basePosition,
                baseSiblingOrder: baseSiblingOrder,
                notBefore: notBefore,
                state: state,
                failureCode: failureCode,
                claimedAt: claimedAt,
                lastTransitionAt: lastTransitionAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int accountId,
                required int desiredStateId,
                required int generation,
                required String desiredLifecycle,
                Value<String?> title = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<String?> status = const Value.absent(),
                Value<int?> dueEpochDay = const Value.absent(),
                Value<int?> desiredTaskListId = const Value.absent(),
                Value<int?> desiredParentTaskId = const Value.absent(),
                Value<int?> desiredPreviousTaskId = const Value.absent(),
                Value<String?> baseRemoteId = const Value.absent(),
                Value<String?> baseEtag = const Value.absent(),
                Value<DateTime?> baseRemoteUpdatedAt = const Value.absent(),
                Value<String?> baseObservedPublicationId = const Value.absent(),
                Value<String?> baseTitle = const Value.absent(),
                Value<int?> baseTaskListId = const Value.absent(),
                Value<int?> baseParentTaskId = const Value.absent(),
                Value<int?> basePreviousTaskId = const Value.absent(),
                Value<String?> basePosition = const Value.absent(),
                Value<String?> baseSiblingOrder = const Value.absent(),
                Value<DateTime?> notBefore = const Value.absent(),
                required String state,
                Value<String?> failureCode = const Value.absent(),
                required DateTime claimedAt,
                required DateTime lastTransitionAt,
              }) => DesiredStateAttemptRowsCompanion.insert(
                id: id,
                accountId: accountId,
                desiredStateId: desiredStateId,
                generation: generation,
                desiredLifecycle: desiredLifecycle,
                title: title,
                notes: notes,
                status: status,
                dueEpochDay: dueEpochDay,
                desiredTaskListId: desiredTaskListId,
                desiredParentTaskId: desiredParentTaskId,
                desiredPreviousTaskId: desiredPreviousTaskId,
                baseRemoteId: baseRemoteId,
                baseEtag: baseEtag,
                baseRemoteUpdatedAt: baseRemoteUpdatedAt,
                baseObservedPublicationId: baseObservedPublicationId,
                baseTitle: baseTitle,
                baseTaskListId: baseTaskListId,
                baseParentTaskId: baseParentTaskId,
                basePreviousTaskId: basePreviousTaskId,
                basePosition: basePosition,
                baseSiblingOrder: baseSiblingOrder,
                notBefore: notBefore,
                state: state,
                failureCode: failureCode,
                claimedAt: claimedAt,
                lastTransitionAt: lastTransitionAt,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DesiredStateAttemptRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DesiredStateAttemptRowsTable,
      DesiredStateAttemptRow,
      $$DesiredStateAttemptRowsTableFilterComposer,
      $$DesiredStateAttemptRowsTableOrderingComposer,
      $$DesiredStateAttemptRowsTableAnnotationComposer,
      $$DesiredStateAttemptRowsTableCreateCompanionBuilder,
      $$DesiredStateAttemptRowsTableUpdateCompanionBuilder,
      (
        DesiredStateAttemptRow,
        BaseReferences<
          _$AppDatabase,
          $DesiredStateAttemptRowsTable,
          DesiredStateAttemptRow
        >,
      ),
      DesiredStateAttemptRow,
      PrefetchHooks Function()
    >;
typedef $$SyncRunRowsTableCreateCompanionBuilder =
    SyncRunRowsCompanion Function({
      required int accountId,
      required String runId,
      required String triggersJson,
      required String state,
      required DateTime startedAt,
      Value<DateTime?> finishedAt,
      Value<String?> failureCode,
      Value<int> rowid,
    });
typedef $$SyncRunRowsTableUpdateCompanionBuilder =
    SyncRunRowsCompanion Function({
      Value<int> accountId,
      Value<String> runId,
      Value<String> triggersJson,
      Value<String> state,
      Value<DateTime> startedAt,
      Value<DateTime?> finishedAt,
      Value<String?> failureCode,
      Value<int> rowid,
    });

class $$SyncRunRowsTableFilterComposer
    extends Composer<_$AppDatabase, $SyncRunRowsTable> {
  $$SyncRunRowsTableFilterComposer({
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

  ColumnFilters<String> get runId => $composableBuilder(
    column: $table.runId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get triggersJson => $composableBuilder(
    column: $table.triggersJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get failureCode => $composableBuilder(
    column: $table.failureCode,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncRunRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncRunRowsTable> {
  $$SyncRunRowsTableOrderingComposer({
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

  ColumnOrderings<String> get runId => $composableBuilder(
    column: $table.runId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get triggersJson => $composableBuilder(
    column: $table.triggersJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get failureCode => $composableBuilder(
    column: $table.failureCode,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncRunRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncRunRowsTable> {
  $$SyncRunRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<String> get runId =>
      $composableBuilder(column: $table.runId, builder: (column) => column);

  GeneratedColumn<String> get triggersJson => $composableBuilder(
    column: $table.triggersJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<DateTime> get startedAt =>
      $composableBuilder(column: $table.startedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get failureCode => $composableBuilder(
    column: $table.failureCode,
    builder: (column) => column,
  );
}

class $$SyncRunRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SyncRunRowsTable,
          SyncRunRow,
          $$SyncRunRowsTableFilterComposer,
          $$SyncRunRowsTableOrderingComposer,
          $$SyncRunRowsTableAnnotationComposer,
          $$SyncRunRowsTableCreateCompanionBuilder,
          $$SyncRunRowsTableUpdateCompanionBuilder,
          (
            SyncRunRow,
            BaseReferences<_$AppDatabase, $SyncRunRowsTable, SyncRunRow>,
          ),
          SyncRunRow,
          PrefetchHooks Function()
        > {
  $$SyncRunRowsTableTableManager(_$AppDatabase db, $SyncRunRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncRunRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncRunRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncRunRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> accountId = const Value.absent(),
                Value<String> runId = const Value.absent(),
                Value<String> triggersJson = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<DateTime> startedAt = const Value.absent(),
                Value<DateTime?> finishedAt = const Value.absent(),
                Value<String?> failureCode = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncRunRowsCompanion(
                accountId: accountId,
                runId: runId,
                triggersJson: triggersJson,
                state: state,
                startedAt: startedAt,
                finishedAt: finishedAt,
                failureCode: failureCode,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int accountId,
                required String runId,
                required String triggersJson,
                required String state,
                required DateTime startedAt,
                Value<DateTime?> finishedAt = const Value.absent(),
                Value<String?> failureCode = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncRunRowsCompanion.insert(
                accountId: accountId,
                runId: runId,
                triggersJson: triggersJson,
                state: state,
                startedAt: startedAt,
                finishedAt: finishedAt,
                failureCode: failureCode,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncRunRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SyncRunRowsTable,
      SyncRunRow,
      $$SyncRunRowsTableFilterComposer,
      $$SyncRunRowsTableOrderingComposer,
      $$SyncRunRowsTableAnnotationComposer,
      $$SyncRunRowsTableCreateCompanionBuilder,
      $$SyncRunRowsTableUpdateCompanionBuilder,
      (
        SyncRunRow,
        BaseReferences<_$AppDatabase, $SyncRunRowsTable, SyncRunRow>,
      ),
      SyncRunRow,
      PrefetchHooks Function()
    >;
typedef $$TaskDeleteTombstoneRowsTableCreateCompanionBuilder =
    TaskDeleteTombstoneRowsCompanion Function({
      Value<int> id,
      required int accountId,
      required int rootTaskId,
      required int desiredStateId,
      required int deleteGeneration,
      required DateTime notBefore,
      required bool snapshotAvailable,
      required DateTime createdAt,
    });
typedef $$TaskDeleteTombstoneRowsTableUpdateCompanionBuilder =
    TaskDeleteTombstoneRowsCompanion Function({
      Value<int> id,
      Value<int> accountId,
      Value<int> rootTaskId,
      Value<int> desiredStateId,
      Value<int> deleteGeneration,
      Value<DateTime> notBefore,
      Value<bool> snapshotAvailable,
      Value<DateTime> createdAt,
    });

class $$TaskDeleteTombstoneRowsTableFilterComposer
    extends Composer<_$AppDatabase, $TaskDeleteTombstoneRowsTable> {
  $$TaskDeleteTombstoneRowsTableFilterComposer({
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

  ColumnFilters<int> get rootTaskId => $composableBuilder(
    column: $table.rootTaskId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get desiredStateId => $composableBuilder(
    column: $table.desiredStateId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deleteGeneration => $composableBuilder(
    column: $table.deleteGeneration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get notBefore => $composableBuilder(
    column: $table.notBefore,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get snapshotAvailable => $composableBuilder(
    column: $table.snapshotAvailable,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TaskDeleteTombstoneRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $TaskDeleteTombstoneRowsTable> {
  $$TaskDeleteTombstoneRowsTableOrderingComposer({
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

  ColumnOrderings<int> get rootTaskId => $composableBuilder(
    column: $table.rootTaskId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get desiredStateId => $composableBuilder(
    column: $table.desiredStateId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deleteGeneration => $composableBuilder(
    column: $table.deleteGeneration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get notBefore => $composableBuilder(
    column: $table.notBefore,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get snapshotAvailable => $composableBuilder(
    column: $table.snapshotAvailable,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TaskDeleteTombstoneRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $TaskDeleteTombstoneRowsTable> {
  $$TaskDeleteTombstoneRowsTableAnnotationComposer({
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

  GeneratedColumn<int> get rootTaskId => $composableBuilder(
    column: $table.rootTaskId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get desiredStateId => $composableBuilder(
    column: $table.desiredStateId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get deleteGeneration => $composableBuilder(
    column: $table.deleteGeneration,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get notBefore =>
      $composableBuilder(column: $table.notBefore, builder: (column) => column);

  GeneratedColumn<bool> get snapshotAvailable => $composableBuilder(
    column: $table.snapshotAvailable,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$TaskDeleteTombstoneRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TaskDeleteTombstoneRowsTable,
          TaskDeleteTombstoneRow,
          $$TaskDeleteTombstoneRowsTableFilterComposer,
          $$TaskDeleteTombstoneRowsTableOrderingComposer,
          $$TaskDeleteTombstoneRowsTableAnnotationComposer,
          $$TaskDeleteTombstoneRowsTableCreateCompanionBuilder,
          $$TaskDeleteTombstoneRowsTableUpdateCompanionBuilder,
          (
            TaskDeleteTombstoneRow,
            BaseReferences<
              _$AppDatabase,
              $TaskDeleteTombstoneRowsTable,
              TaskDeleteTombstoneRow
            >,
          ),
          TaskDeleteTombstoneRow,
          PrefetchHooks Function()
        > {
  $$TaskDeleteTombstoneRowsTableTableManager(
    _$AppDatabase db,
    $TaskDeleteTombstoneRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TaskDeleteTombstoneRowsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$TaskDeleteTombstoneRowsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$TaskDeleteTombstoneRowsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> accountId = const Value.absent(),
                Value<int> rootTaskId = const Value.absent(),
                Value<int> desiredStateId = const Value.absent(),
                Value<int> deleteGeneration = const Value.absent(),
                Value<DateTime> notBefore = const Value.absent(),
                Value<bool> snapshotAvailable = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
              }) => TaskDeleteTombstoneRowsCompanion(
                id: id,
                accountId: accountId,
                rootTaskId: rootTaskId,
                desiredStateId: desiredStateId,
                deleteGeneration: deleteGeneration,
                notBefore: notBefore,
                snapshotAvailable: snapshotAvailable,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int accountId,
                required int rootTaskId,
                required int desiredStateId,
                required int deleteGeneration,
                required DateTime notBefore,
                required bool snapshotAvailable,
                required DateTime createdAt,
              }) => TaskDeleteTombstoneRowsCompanion.insert(
                id: id,
                accountId: accountId,
                rootTaskId: rootTaskId,
                desiredStateId: desiredStateId,
                deleteGeneration: deleteGeneration,
                notBefore: notBefore,
                snapshotAvailable: snapshotAvailable,
                createdAt: createdAt,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TaskDeleteTombstoneRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TaskDeleteTombstoneRowsTable,
      TaskDeleteTombstoneRow,
      $$TaskDeleteTombstoneRowsTableFilterComposer,
      $$TaskDeleteTombstoneRowsTableOrderingComposer,
      $$TaskDeleteTombstoneRowsTableAnnotationComposer,
      $$TaskDeleteTombstoneRowsTableCreateCompanionBuilder,
      $$TaskDeleteTombstoneRowsTableUpdateCompanionBuilder,
      (
        TaskDeleteTombstoneRow,
        BaseReferences<
          _$AppDatabase,
          $TaskDeleteTombstoneRowsTable,
          TaskDeleteTombstoneRow
        >,
      ),
      TaskDeleteTombstoneRow,
      PrefetchHooks Function()
    >;
typedef $$TaskDeleteSnapshotRowsTableCreateCompanionBuilder =
    TaskDeleteSnapshotRowsCompanion Function({
      Value<int> id,
      required int accountId,
      required int tombstoneId,
      required int taskId,
      required int taskListId,
      Value<int?> parentTaskId,
      Value<String?> remoteId,
      required String title,
      Value<String?> notes,
      required String status,
      Value<int?> dueEpochDay,
      required String position,
    });
typedef $$TaskDeleteSnapshotRowsTableUpdateCompanionBuilder =
    TaskDeleteSnapshotRowsCompanion Function({
      Value<int> id,
      Value<int> accountId,
      Value<int> tombstoneId,
      Value<int> taskId,
      Value<int> taskListId,
      Value<int?> parentTaskId,
      Value<String?> remoteId,
      Value<String> title,
      Value<String?> notes,
      Value<String> status,
      Value<int?> dueEpochDay,
      Value<String> position,
    });

class $$TaskDeleteSnapshotRowsTableFilterComposer
    extends Composer<_$AppDatabase, $TaskDeleteSnapshotRowsTable> {
  $$TaskDeleteSnapshotRowsTableFilterComposer({
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

  ColumnFilters<int> get tombstoneId => $composableBuilder(
    column: $table.tombstoneId,
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
}

class $$TaskDeleteSnapshotRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $TaskDeleteSnapshotRowsTable> {
  $$TaskDeleteSnapshotRowsTableOrderingComposer({
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

  ColumnOrderings<int> get tombstoneId => $composableBuilder(
    column: $table.tombstoneId,
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
}

class $$TaskDeleteSnapshotRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $TaskDeleteSnapshotRowsTable> {
  $$TaskDeleteSnapshotRowsTableAnnotationComposer({
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

  GeneratedColumn<int> get tombstoneId => $composableBuilder(
    column: $table.tombstoneId,
    builder: (column) => column,
  );

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
}

class $$TaskDeleteSnapshotRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TaskDeleteSnapshotRowsTable,
          TaskDeleteSnapshotRow,
          $$TaskDeleteSnapshotRowsTableFilterComposer,
          $$TaskDeleteSnapshotRowsTableOrderingComposer,
          $$TaskDeleteSnapshotRowsTableAnnotationComposer,
          $$TaskDeleteSnapshotRowsTableCreateCompanionBuilder,
          $$TaskDeleteSnapshotRowsTableUpdateCompanionBuilder,
          (
            TaskDeleteSnapshotRow,
            BaseReferences<
              _$AppDatabase,
              $TaskDeleteSnapshotRowsTable,
              TaskDeleteSnapshotRow
            >,
          ),
          TaskDeleteSnapshotRow,
          PrefetchHooks Function()
        > {
  $$TaskDeleteSnapshotRowsTableTableManager(
    _$AppDatabase db,
    $TaskDeleteSnapshotRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TaskDeleteSnapshotRowsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$TaskDeleteSnapshotRowsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$TaskDeleteSnapshotRowsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> accountId = const Value.absent(),
                Value<int> tombstoneId = const Value.absent(),
                Value<int> taskId = const Value.absent(),
                Value<int> taskListId = const Value.absent(),
                Value<int?> parentTaskId = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int?> dueEpochDay = const Value.absent(),
                Value<String> position = const Value.absent(),
              }) => TaskDeleteSnapshotRowsCompanion(
                id: id,
                accountId: accountId,
                tombstoneId: tombstoneId,
                taskId: taskId,
                taskListId: taskListId,
                parentTaskId: parentTaskId,
                remoteId: remoteId,
                title: title,
                notes: notes,
                status: status,
                dueEpochDay: dueEpochDay,
                position: position,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int accountId,
                required int tombstoneId,
                required int taskId,
                required int taskListId,
                Value<int?> parentTaskId = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                required String title,
                Value<String?> notes = const Value.absent(),
                required String status,
                Value<int?> dueEpochDay = const Value.absent(),
                required String position,
              }) => TaskDeleteSnapshotRowsCompanion.insert(
                id: id,
                accountId: accountId,
                tombstoneId: tombstoneId,
                taskId: taskId,
                taskListId: taskListId,
                parentTaskId: parentTaskId,
                remoteId: remoteId,
                title: title,
                notes: notes,
                status: status,
                dueEpochDay: dueEpochDay,
                position: position,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TaskDeleteSnapshotRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TaskDeleteSnapshotRowsTable,
      TaskDeleteSnapshotRow,
      $$TaskDeleteSnapshotRowsTableFilterComposer,
      $$TaskDeleteSnapshotRowsTableOrderingComposer,
      $$TaskDeleteSnapshotRowsTableAnnotationComposer,
      $$TaskDeleteSnapshotRowsTableCreateCompanionBuilder,
      $$TaskDeleteSnapshotRowsTableUpdateCompanionBuilder,
      (
        TaskDeleteSnapshotRow,
        BaseReferences<
          _$AppDatabase,
          $TaskDeleteSnapshotRowsTable,
          TaskDeleteSnapshotRow
        >,
      ),
      TaskDeleteSnapshotRow,
      PrefetchHooks Function()
    >;
typedef $$TaskDueChangeGroupRowsTableCreateCompanionBuilder =
    TaskDueChangeGroupRowsCompanion Function({
      Value<int> id,
      required int accountId,
      required int editedTaskId,
      required int snapshotCount,
      required bool cascadedParent,
      required DateTime createdAt,
    });
typedef $$TaskDueChangeGroupRowsTableUpdateCompanionBuilder =
    TaskDueChangeGroupRowsCompanion Function({
      Value<int> id,
      Value<int> accountId,
      Value<int> editedTaskId,
      Value<int> snapshotCount,
      Value<bool> cascadedParent,
      Value<DateTime> createdAt,
    });

class $$TaskDueChangeGroupRowsTableFilterComposer
    extends Composer<_$AppDatabase, $TaskDueChangeGroupRowsTable> {
  $$TaskDueChangeGroupRowsTableFilterComposer({
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

  ColumnFilters<int> get editedTaskId => $composableBuilder(
    column: $table.editedTaskId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get snapshotCount => $composableBuilder(
    column: $table.snapshotCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get cascadedParent => $composableBuilder(
    column: $table.cascadedParent,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TaskDueChangeGroupRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $TaskDueChangeGroupRowsTable> {
  $$TaskDueChangeGroupRowsTableOrderingComposer({
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

  ColumnOrderings<int> get editedTaskId => $composableBuilder(
    column: $table.editedTaskId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get snapshotCount => $composableBuilder(
    column: $table.snapshotCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get cascadedParent => $composableBuilder(
    column: $table.cascadedParent,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TaskDueChangeGroupRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $TaskDueChangeGroupRowsTable> {
  $$TaskDueChangeGroupRowsTableAnnotationComposer({
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

  GeneratedColumn<int> get editedTaskId => $composableBuilder(
    column: $table.editedTaskId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get snapshotCount => $composableBuilder(
    column: $table.snapshotCount,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get cascadedParent => $composableBuilder(
    column: $table.cascadedParent,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$TaskDueChangeGroupRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TaskDueChangeGroupRowsTable,
          TaskDueChangeGroupRow,
          $$TaskDueChangeGroupRowsTableFilterComposer,
          $$TaskDueChangeGroupRowsTableOrderingComposer,
          $$TaskDueChangeGroupRowsTableAnnotationComposer,
          $$TaskDueChangeGroupRowsTableCreateCompanionBuilder,
          $$TaskDueChangeGroupRowsTableUpdateCompanionBuilder,
          (
            TaskDueChangeGroupRow,
            BaseReferences<
              _$AppDatabase,
              $TaskDueChangeGroupRowsTable,
              TaskDueChangeGroupRow
            >,
          ),
          TaskDueChangeGroupRow,
          PrefetchHooks Function()
        > {
  $$TaskDueChangeGroupRowsTableTableManager(
    _$AppDatabase db,
    $TaskDueChangeGroupRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TaskDueChangeGroupRowsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$TaskDueChangeGroupRowsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$TaskDueChangeGroupRowsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> accountId = const Value.absent(),
                Value<int> editedTaskId = const Value.absent(),
                Value<int> snapshotCount = const Value.absent(),
                Value<bool> cascadedParent = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
              }) => TaskDueChangeGroupRowsCompanion(
                id: id,
                accountId: accountId,
                editedTaskId: editedTaskId,
                snapshotCount: snapshotCount,
                cascadedParent: cascadedParent,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int accountId,
                required int editedTaskId,
                required int snapshotCount,
                required bool cascadedParent,
                required DateTime createdAt,
              }) => TaskDueChangeGroupRowsCompanion.insert(
                id: id,
                accountId: accountId,
                editedTaskId: editedTaskId,
                snapshotCount: snapshotCount,
                cascadedParent: cascadedParent,
                createdAt: createdAt,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TaskDueChangeGroupRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TaskDueChangeGroupRowsTable,
      TaskDueChangeGroupRow,
      $$TaskDueChangeGroupRowsTableFilterComposer,
      $$TaskDueChangeGroupRowsTableOrderingComposer,
      $$TaskDueChangeGroupRowsTableAnnotationComposer,
      $$TaskDueChangeGroupRowsTableCreateCompanionBuilder,
      $$TaskDueChangeGroupRowsTableUpdateCompanionBuilder,
      (
        TaskDueChangeGroupRow,
        BaseReferences<
          _$AppDatabase,
          $TaskDueChangeGroupRowsTable,
          TaskDueChangeGroupRow
        >,
      ),
      TaskDueChangeGroupRow,
      PrefetchHooks Function()
    >;
typedef $$TaskDueChangeSnapshotRowsTableCreateCompanionBuilder =
    TaskDueChangeSnapshotRowsCompanion Function({
      Value<int> id,
      required int accountId,
      required int groupId,
      required int taskId,
      Value<int?> priorDueEpochDay,
    });
typedef $$TaskDueChangeSnapshotRowsTableUpdateCompanionBuilder =
    TaskDueChangeSnapshotRowsCompanion Function({
      Value<int> id,
      Value<int> accountId,
      Value<int> groupId,
      Value<int> taskId,
      Value<int?> priorDueEpochDay,
    });

class $$TaskDueChangeSnapshotRowsTableFilterComposer
    extends Composer<_$AppDatabase, $TaskDueChangeSnapshotRowsTable> {
  $$TaskDueChangeSnapshotRowsTableFilterComposer({
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

  ColumnFilters<int> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get taskId => $composableBuilder(
    column: $table.taskId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get priorDueEpochDay => $composableBuilder(
    column: $table.priorDueEpochDay,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TaskDueChangeSnapshotRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $TaskDueChangeSnapshotRowsTable> {
  $$TaskDueChangeSnapshotRowsTableOrderingComposer({
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

  ColumnOrderings<int> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get taskId => $composableBuilder(
    column: $table.taskId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get priorDueEpochDay => $composableBuilder(
    column: $table.priorDueEpochDay,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TaskDueChangeSnapshotRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $TaskDueChangeSnapshotRowsTable> {
  $$TaskDueChangeSnapshotRowsTableAnnotationComposer({
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

  GeneratedColumn<int> get groupId =>
      $composableBuilder(column: $table.groupId, builder: (column) => column);

  GeneratedColumn<int> get taskId =>
      $composableBuilder(column: $table.taskId, builder: (column) => column);

  GeneratedColumn<int> get priorDueEpochDay => $composableBuilder(
    column: $table.priorDueEpochDay,
    builder: (column) => column,
  );
}

class $$TaskDueChangeSnapshotRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TaskDueChangeSnapshotRowsTable,
          TaskDueChangeSnapshotRow,
          $$TaskDueChangeSnapshotRowsTableFilterComposer,
          $$TaskDueChangeSnapshotRowsTableOrderingComposer,
          $$TaskDueChangeSnapshotRowsTableAnnotationComposer,
          $$TaskDueChangeSnapshotRowsTableCreateCompanionBuilder,
          $$TaskDueChangeSnapshotRowsTableUpdateCompanionBuilder,
          (
            TaskDueChangeSnapshotRow,
            BaseReferences<
              _$AppDatabase,
              $TaskDueChangeSnapshotRowsTable,
              TaskDueChangeSnapshotRow
            >,
          ),
          TaskDueChangeSnapshotRow,
          PrefetchHooks Function()
        > {
  $$TaskDueChangeSnapshotRowsTableTableManager(
    _$AppDatabase db,
    $TaskDueChangeSnapshotRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TaskDueChangeSnapshotRowsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$TaskDueChangeSnapshotRowsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$TaskDueChangeSnapshotRowsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> accountId = const Value.absent(),
                Value<int> groupId = const Value.absent(),
                Value<int> taskId = const Value.absent(),
                Value<int?> priorDueEpochDay = const Value.absent(),
              }) => TaskDueChangeSnapshotRowsCompanion(
                id: id,
                accountId: accountId,
                groupId: groupId,
                taskId: taskId,
                priorDueEpochDay: priorDueEpochDay,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int accountId,
                required int groupId,
                required int taskId,
                Value<int?> priorDueEpochDay = const Value.absent(),
              }) => TaskDueChangeSnapshotRowsCompanion.insert(
                id: id,
                accountId: accountId,
                groupId: groupId,
                taskId: taskId,
                priorDueEpochDay: priorDueEpochDay,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TaskDueChangeSnapshotRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TaskDueChangeSnapshotRowsTable,
      TaskDueChangeSnapshotRow,
      $$TaskDueChangeSnapshotRowsTableFilterComposer,
      $$TaskDueChangeSnapshotRowsTableOrderingComposer,
      $$TaskDueChangeSnapshotRowsTableAnnotationComposer,
      $$TaskDueChangeSnapshotRowsTableCreateCompanionBuilder,
      $$TaskDueChangeSnapshotRowsTableUpdateCompanionBuilder,
      (
        TaskDueChangeSnapshotRow,
        BaseReferences<
          _$AppDatabase,
          $TaskDueChangeSnapshotRowsTable,
          TaskDueChangeSnapshotRow
        >,
      ),
      TaskDueChangeSnapshotRow,
      PrefetchHooks Function()
    >;
typedef $$BulkOperationRowsTableCreateCompanionBuilder =
    BulkOperationRowsCompanion Function({
      Value<int> id,
      required int accountId,
      required String kind,
      required int selectedCount,
      required int affectedCount,
      required DateTime createdAt,
    });
typedef $$BulkOperationRowsTableUpdateCompanionBuilder =
    BulkOperationRowsCompanion Function({
      Value<int> id,
      Value<int> accountId,
      Value<String> kind,
      Value<int> selectedCount,
      Value<int> affectedCount,
      Value<DateTime> createdAt,
    });

class $$BulkOperationRowsTableFilterComposer
    extends Composer<_$AppDatabase, $BulkOperationRowsTable> {
  $$BulkOperationRowsTableFilterComposer({
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

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get selectedCount => $composableBuilder(
    column: $table.selectedCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get affectedCount => $composableBuilder(
    column: $table.affectedCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$BulkOperationRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $BulkOperationRowsTable> {
  $$BulkOperationRowsTableOrderingComposer({
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

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get selectedCount => $composableBuilder(
    column: $table.selectedCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get affectedCount => $composableBuilder(
    column: $table.affectedCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$BulkOperationRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $BulkOperationRowsTable> {
  $$BulkOperationRowsTableAnnotationComposer({
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

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<int> get selectedCount => $composableBuilder(
    column: $table.selectedCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get affectedCount => $composableBuilder(
    column: $table.affectedCount,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$BulkOperationRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $BulkOperationRowsTable,
          BulkOperationRow,
          $$BulkOperationRowsTableFilterComposer,
          $$BulkOperationRowsTableOrderingComposer,
          $$BulkOperationRowsTableAnnotationComposer,
          $$BulkOperationRowsTableCreateCompanionBuilder,
          $$BulkOperationRowsTableUpdateCompanionBuilder,
          (
            BulkOperationRow,
            BaseReferences<
              _$AppDatabase,
              $BulkOperationRowsTable,
              BulkOperationRow
            >,
          ),
          BulkOperationRow,
          PrefetchHooks Function()
        > {
  $$BulkOperationRowsTableTableManager(
    _$AppDatabase db,
    $BulkOperationRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BulkOperationRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BulkOperationRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BulkOperationRowsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> accountId = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<int> selectedCount = const Value.absent(),
                Value<int> affectedCount = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
              }) => BulkOperationRowsCompanion(
                id: id,
                accountId: accountId,
                kind: kind,
                selectedCount: selectedCount,
                affectedCount: affectedCount,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int accountId,
                required String kind,
                required int selectedCount,
                required int affectedCount,
                required DateTime createdAt,
              }) => BulkOperationRowsCompanion.insert(
                id: id,
                accountId: accountId,
                kind: kind,
                selectedCount: selectedCount,
                affectedCount: affectedCount,
                createdAt: createdAt,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$BulkOperationRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $BulkOperationRowsTable,
      BulkOperationRow,
      $$BulkOperationRowsTableFilterComposer,
      $$BulkOperationRowsTableOrderingComposer,
      $$BulkOperationRowsTableAnnotationComposer,
      $$BulkOperationRowsTableCreateCompanionBuilder,
      $$BulkOperationRowsTableUpdateCompanionBuilder,
      (
        BulkOperationRow,
        BaseReferences<
          _$AppDatabase,
          $BulkOperationRowsTable,
          BulkOperationRow
        >,
      ),
      BulkOperationRow,
      PrefetchHooks Function()
    >;
typedef $$BulkOperationMemberRowsTableCreateCompanionBuilder =
    BulkOperationMemberRowsCompanion Function({
      Value<int> id,
      required int accountId,
      required int operationId,
      required int taskId,
      required int desiredStateId,
      required int generation,
      required String outcome,
    });
typedef $$BulkOperationMemberRowsTableUpdateCompanionBuilder =
    BulkOperationMemberRowsCompanion Function({
      Value<int> id,
      Value<int> accountId,
      Value<int> operationId,
      Value<int> taskId,
      Value<int> desiredStateId,
      Value<int> generation,
      Value<String> outcome,
    });

class $$BulkOperationMemberRowsTableFilterComposer
    extends Composer<_$AppDatabase, $BulkOperationMemberRowsTable> {
  $$BulkOperationMemberRowsTableFilterComposer({
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

  ColumnFilters<int> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get taskId => $composableBuilder(
    column: $table.taskId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get desiredStateId => $composableBuilder(
    column: $table.desiredStateId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get outcome => $composableBuilder(
    column: $table.outcome,
    builder: (column) => ColumnFilters(column),
  );
}

class $$BulkOperationMemberRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $BulkOperationMemberRowsTable> {
  $$BulkOperationMemberRowsTableOrderingComposer({
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

  ColumnOrderings<int> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get taskId => $composableBuilder(
    column: $table.taskId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get desiredStateId => $composableBuilder(
    column: $table.desiredStateId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get outcome => $composableBuilder(
    column: $table.outcome,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$BulkOperationMemberRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $BulkOperationMemberRowsTable> {
  $$BulkOperationMemberRowsTableAnnotationComposer({
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

  GeneratedColumn<int> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get taskId =>
      $composableBuilder(column: $table.taskId, builder: (column) => column);

  GeneratedColumn<int> get desiredStateId => $composableBuilder(
    column: $table.desiredStateId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => column,
  );

  GeneratedColumn<String> get outcome =>
      $composableBuilder(column: $table.outcome, builder: (column) => column);
}

class $$BulkOperationMemberRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $BulkOperationMemberRowsTable,
          BulkOperationMemberRow,
          $$BulkOperationMemberRowsTableFilterComposer,
          $$BulkOperationMemberRowsTableOrderingComposer,
          $$BulkOperationMemberRowsTableAnnotationComposer,
          $$BulkOperationMemberRowsTableCreateCompanionBuilder,
          $$BulkOperationMemberRowsTableUpdateCompanionBuilder,
          (
            BulkOperationMemberRow,
            BaseReferences<
              _$AppDatabase,
              $BulkOperationMemberRowsTable,
              BulkOperationMemberRow
            >,
          ),
          BulkOperationMemberRow,
          PrefetchHooks Function()
        > {
  $$BulkOperationMemberRowsTableTableManager(
    _$AppDatabase db,
    $BulkOperationMemberRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BulkOperationMemberRowsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$BulkOperationMemberRowsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$BulkOperationMemberRowsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> accountId = const Value.absent(),
                Value<int> operationId = const Value.absent(),
                Value<int> taskId = const Value.absent(),
                Value<int> desiredStateId = const Value.absent(),
                Value<int> generation = const Value.absent(),
                Value<String> outcome = const Value.absent(),
              }) => BulkOperationMemberRowsCompanion(
                id: id,
                accountId: accountId,
                operationId: operationId,
                taskId: taskId,
                desiredStateId: desiredStateId,
                generation: generation,
                outcome: outcome,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int accountId,
                required int operationId,
                required int taskId,
                required int desiredStateId,
                required int generation,
                required String outcome,
              }) => BulkOperationMemberRowsCompanion.insert(
                id: id,
                accountId: accountId,
                operationId: operationId,
                taskId: taskId,
                desiredStateId: desiredStateId,
                generation: generation,
                outcome: outcome,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$BulkOperationMemberRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $BulkOperationMemberRowsTable,
      BulkOperationMemberRow,
      $$BulkOperationMemberRowsTableFilterComposer,
      $$BulkOperationMemberRowsTableOrderingComposer,
      $$BulkOperationMemberRowsTableAnnotationComposer,
      $$BulkOperationMemberRowsTableCreateCompanionBuilder,
      $$BulkOperationMemberRowsTableUpdateCompanionBuilder,
      (
        BulkOperationMemberRow,
        BaseReferences<
          _$AppDatabase,
          $BulkOperationMemberRowsTable,
          BulkOperationMemberRow
        >,
      ),
      BulkOperationMemberRow,
      PrefetchHooks Function()
    >;
typedef $$SyncFactRowsTableCreateCompanionBuilder =
    SyncFactRowsCompanion Function({
      Value<int> accountId,
      Value<DateTime?> lastSuccessfulSyncAt,
      Value<String?> latestFailureReason,
      Value<DateTime?> latestFailureAt,
      Value<String?> latestFailureDiagnosticCode,
      Value<String?> latestFailureAction,
      Value<int> pendingCount,
      Value<int> inFlightCount,
      Value<int> uncertainCount,
      Value<int> failedCount,
      Value<bool> reauthorizationRequired,
      Value<bool> retryWaiting,
      Value<bool> automaticRetryExhausted,
      Value<DateTime?> retryEpisodeStartedAt,
      Value<DateTime?> retryEpisodeDeadlineAt,
      Value<DateTime?> retryNextAttemptAt,
      Value<DateTime?> retryServerNotBeforeAt,
      Value<DateTime?> retryLastObservedAt,
      Value<int> retryAttemptCount,
      Value<bool> requiredScopeIncomplete,
      Value<bool> followUpRequired,
    });
typedef $$SyncFactRowsTableUpdateCompanionBuilder =
    SyncFactRowsCompanion Function({
      Value<int> accountId,
      Value<DateTime?> lastSuccessfulSyncAt,
      Value<String?> latestFailureReason,
      Value<DateTime?> latestFailureAt,
      Value<String?> latestFailureDiagnosticCode,
      Value<String?> latestFailureAction,
      Value<int> pendingCount,
      Value<int> inFlightCount,
      Value<int> uncertainCount,
      Value<int> failedCount,
      Value<bool> reauthorizationRequired,
      Value<bool> retryWaiting,
      Value<bool> automaticRetryExhausted,
      Value<DateTime?> retryEpisodeStartedAt,
      Value<DateTime?> retryEpisodeDeadlineAt,
      Value<DateTime?> retryNextAttemptAt,
      Value<DateTime?> retryServerNotBeforeAt,
      Value<DateTime?> retryLastObservedAt,
      Value<int> retryAttemptCount,
      Value<bool> requiredScopeIncomplete,
      Value<bool> followUpRequired,
    });

class $$SyncFactRowsTableFilterComposer
    extends Composer<_$AppDatabase, $SyncFactRowsTable> {
  $$SyncFactRowsTableFilterComposer({
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

  ColumnFilters<DateTime> get lastSuccessfulSyncAt => $composableBuilder(
    column: $table.lastSuccessfulSyncAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get latestFailureReason => $composableBuilder(
    column: $table.latestFailureReason,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get latestFailureAt => $composableBuilder(
    column: $table.latestFailureAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get latestFailureDiagnosticCode => $composableBuilder(
    column: $table.latestFailureDiagnosticCode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get latestFailureAction => $composableBuilder(
    column: $table.latestFailureAction,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get pendingCount => $composableBuilder(
    column: $table.pendingCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get inFlightCount => $composableBuilder(
    column: $table.inFlightCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get uncertainCount => $composableBuilder(
    column: $table.uncertainCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get failedCount => $composableBuilder(
    column: $table.failedCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get reauthorizationRequired => $composableBuilder(
    column: $table.reauthorizationRequired,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get retryWaiting => $composableBuilder(
    column: $table.retryWaiting,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get automaticRetryExhausted => $composableBuilder(
    column: $table.automaticRetryExhausted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get retryEpisodeStartedAt => $composableBuilder(
    column: $table.retryEpisodeStartedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get retryEpisodeDeadlineAt => $composableBuilder(
    column: $table.retryEpisodeDeadlineAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get retryNextAttemptAt => $composableBuilder(
    column: $table.retryNextAttemptAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get retryServerNotBeforeAt => $composableBuilder(
    column: $table.retryServerNotBeforeAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get retryLastObservedAt => $composableBuilder(
    column: $table.retryLastObservedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get retryAttemptCount => $composableBuilder(
    column: $table.retryAttemptCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get requiredScopeIncomplete => $composableBuilder(
    column: $table.requiredScopeIncomplete,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get followUpRequired => $composableBuilder(
    column: $table.followUpRequired,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncFactRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncFactRowsTable> {
  $$SyncFactRowsTableOrderingComposer({
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

  ColumnOrderings<DateTime> get lastSuccessfulSyncAt => $composableBuilder(
    column: $table.lastSuccessfulSyncAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get latestFailureReason => $composableBuilder(
    column: $table.latestFailureReason,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get latestFailureAt => $composableBuilder(
    column: $table.latestFailureAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get latestFailureDiagnosticCode => $composableBuilder(
    column: $table.latestFailureDiagnosticCode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get latestFailureAction => $composableBuilder(
    column: $table.latestFailureAction,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get pendingCount => $composableBuilder(
    column: $table.pendingCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get inFlightCount => $composableBuilder(
    column: $table.inFlightCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get uncertainCount => $composableBuilder(
    column: $table.uncertainCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get failedCount => $composableBuilder(
    column: $table.failedCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get reauthorizationRequired => $composableBuilder(
    column: $table.reauthorizationRequired,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get retryWaiting => $composableBuilder(
    column: $table.retryWaiting,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get automaticRetryExhausted => $composableBuilder(
    column: $table.automaticRetryExhausted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get retryEpisodeStartedAt => $composableBuilder(
    column: $table.retryEpisodeStartedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get retryEpisodeDeadlineAt => $composableBuilder(
    column: $table.retryEpisodeDeadlineAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get retryNextAttemptAt => $composableBuilder(
    column: $table.retryNextAttemptAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get retryServerNotBeforeAt => $composableBuilder(
    column: $table.retryServerNotBeforeAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get retryLastObservedAt => $composableBuilder(
    column: $table.retryLastObservedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get retryAttemptCount => $composableBuilder(
    column: $table.retryAttemptCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get requiredScopeIncomplete => $composableBuilder(
    column: $table.requiredScopeIncomplete,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get followUpRequired => $composableBuilder(
    column: $table.followUpRequired,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncFactRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncFactRowsTable> {
  $$SyncFactRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<DateTime> get lastSuccessfulSyncAt => $composableBuilder(
    column: $table.lastSuccessfulSyncAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get latestFailureReason => $composableBuilder(
    column: $table.latestFailureReason,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get latestFailureAt => $composableBuilder(
    column: $table.latestFailureAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get latestFailureDiagnosticCode => $composableBuilder(
    column: $table.latestFailureDiagnosticCode,
    builder: (column) => column,
  );

  GeneratedColumn<String> get latestFailureAction => $composableBuilder(
    column: $table.latestFailureAction,
    builder: (column) => column,
  );

  GeneratedColumn<int> get pendingCount => $composableBuilder(
    column: $table.pendingCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get inFlightCount => $composableBuilder(
    column: $table.inFlightCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get uncertainCount => $composableBuilder(
    column: $table.uncertainCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get failedCount => $composableBuilder(
    column: $table.failedCount,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get reauthorizationRequired => $composableBuilder(
    column: $table.reauthorizationRequired,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get retryWaiting => $composableBuilder(
    column: $table.retryWaiting,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get automaticRetryExhausted => $composableBuilder(
    column: $table.automaticRetryExhausted,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get retryEpisodeStartedAt => $composableBuilder(
    column: $table.retryEpisodeStartedAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get retryEpisodeDeadlineAt => $composableBuilder(
    column: $table.retryEpisodeDeadlineAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get retryNextAttemptAt => $composableBuilder(
    column: $table.retryNextAttemptAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get retryServerNotBeforeAt => $composableBuilder(
    column: $table.retryServerNotBeforeAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get retryLastObservedAt => $composableBuilder(
    column: $table.retryLastObservedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get retryAttemptCount => $composableBuilder(
    column: $table.retryAttemptCount,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get requiredScopeIncomplete => $composableBuilder(
    column: $table.requiredScopeIncomplete,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get followUpRequired => $composableBuilder(
    column: $table.followUpRequired,
    builder: (column) => column,
  );
}

class $$SyncFactRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SyncFactRowsTable,
          SyncFactRow,
          $$SyncFactRowsTableFilterComposer,
          $$SyncFactRowsTableOrderingComposer,
          $$SyncFactRowsTableAnnotationComposer,
          $$SyncFactRowsTableCreateCompanionBuilder,
          $$SyncFactRowsTableUpdateCompanionBuilder,
          (
            SyncFactRow,
            BaseReferences<_$AppDatabase, $SyncFactRowsTable, SyncFactRow>,
          ),
          SyncFactRow,
          PrefetchHooks Function()
        > {
  $$SyncFactRowsTableTableManager(_$AppDatabase db, $SyncFactRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncFactRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncFactRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncFactRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> accountId = const Value.absent(),
                Value<DateTime?> lastSuccessfulSyncAt = const Value.absent(),
                Value<String?> latestFailureReason = const Value.absent(),
                Value<DateTime?> latestFailureAt = const Value.absent(),
                Value<String?> latestFailureDiagnosticCode =
                    const Value.absent(),
                Value<String?> latestFailureAction = const Value.absent(),
                Value<int> pendingCount = const Value.absent(),
                Value<int> inFlightCount = const Value.absent(),
                Value<int> uncertainCount = const Value.absent(),
                Value<int> failedCount = const Value.absent(),
                Value<bool> reauthorizationRequired = const Value.absent(),
                Value<bool> retryWaiting = const Value.absent(),
                Value<bool> automaticRetryExhausted = const Value.absent(),
                Value<DateTime?> retryEpisodeStartedAt = const Value.absent(),
                Value<DateTime?> retryEpisodeDeadlineAt = const Value.absent(),
                Value<DateTime?> retryNextAttemptAt = const Value.absent(),
                Value<DateTime?> retryServerNotBeforeAt = const Value.absent(),
                Value<DateTime?> retryLastObservedAt = const Value.absent(),
                Value<int> retryAttemptCount = const Value.absent(),
                Value<bool> requiredScopeIncomplete = const Value.absent(),
                Value<bool> followUpRequired = const Value.absent(),
              }) => SyncFactRowsCompanion(
                accountId: accountId,
                lastSuccessfulSyncAt: lastSuccessfulSyncAt,
                latestFailureReason: latestFailureReason,
                latestFailureAt: latestFailureAt,
                latestFailureDiagnosticCode: latestFailureDiagnosticCode,
                latestFailureAction: latestFailureAction,
                pendingCount: pendingCount,
                inFlightCount: inFlightCount,
                uncertainCount: uncertainCount,
                failedCount: failedCount,
                reauthorizationRequired: reauthorizationRequired,
                retryWaiting: retryWaiting,
                automaticRetryExhausted: automaticRetryExhausted,
                retryEpisodeStartedAt: retryEpisodeStartedAt,
                retryEpisodeDeadlineAt: retryEpisodeDeadlineAt,
                retryNextAttemptAt: retryNextAttemptAt,
                retryServerNotBeforeAt: retryServerNotBeforeAt,
                retryLastObservedAt: retryLastObservedAt,
                retryAttemptCount: retryAttemptCount,
                requiredScopeIncomplete: requiredScopeIncomplete,
                followUpRequired: followUpRequired,
              ),
          createCompanionCallback:
              ({
                Value<int> accountId = const Value.absent(),
                Value<DateTime?> lastSuccessfulSyncAt = const Value.absent(),
                Value<String?> latestFailureReason = const Value.absent(),
                Value<DateTime?> latestFailureAt = const Value.absent(),
                Value<String?> latestFailureDiagnosticCode =
                    const Value.absent(),
                Value<String?> latestFailureAction = const Value.absent(),
                Value<int> pendingCount = const Value.absent(),
                Value<int> inFlightCount = const Value.absent(),
                Value<int> uncertainCount = const Value.absent(),
                Value<int> failedCount = const Value.absent(),
                Value<bool> reauthorizationRequired = const Value.absent(),
                Value<bool> retryWaiting = const Value.absent(),
                Value<bool> automaticRetryExhausted = const Value.absent(),
                Value<DateTime?> retryEpisodeStartedAt = const Value.absent(),
                Value<DateTime?> retryEpisodeDeadlineAt = const Value.absent(),
                Value<DateTime?> retryNextAttemptAt = const Value.absent(),
                Value<DateTime?> retryServerNotBeforeAt = const Value.absent(),
                Value<DateTime?> retryLastObservedAt = const Value.absent(),
                Value<int> retryAttemptCount = const Value.absent(),
                Value<bool> requiredScopeIncomplete = const Value.absent(),
                Value<bool> followUpRequired = const Value.absent(),
              }) => SyncFactRowsCompanion.insert(
                accountId: accountId,
                lastSuccessfulSyncAt: lastSuccessfulSyncAt,
                latestFailureReason: latestFailureReason,
                latestFailureAt: latestFailureAt,
                latestFailureDiagnosticCode: latestFailureDiagnosticCode,
                latestFailureAction: latestFailureAction,
                pendingCount: pendingCount,
                inFlightCount: inFlightCount,
                uncertainCount: uncertainCount,
                failedCount: failedCount,
                reauthorizationRequired: reauthorizationRequired,
                retryWaiting: retryWaiting,
                automaticRetryExhausted: automaticRetryExhausted,
                retryEpisodeStartedAt: retryEpisodeStartedAt,
                retryEpisodeDeadlineAt: retryEpisodeDeadlineAt,
                retryNextAttemptAt: retryNextAttemptAt,
                retryServerNotBeforeAt: retryServerNotBeforeAt,
                retryLastObservedAt: retryLastObservedAt,
                retryAttemptCount: retryAttemptCount,
                requiredScopeIncomplete: requiredScopeIncomplete,
                followUpRequired: followUpRequired,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncFactRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SyncFactRowsTable,
      SyncFactRow,
      $$SyncFactRowsTableFilterComposer,
      $$SyncFactRowsTableOrderingComposer,
      $$SyncFactRowsTableAnnotationComposer,
      $$SyncFactRowsTableCreateCompanionBuilder,
      $$SyncFactRowsTableUpdateCompanionBuilder,
      (
        SyncFactRow,
        BaseReferences<_$AppDatabase, $SyncFactRowsTable, SyncFactRow>,
      ),
      SyncFactRow,
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
  $$DesiredStateRowsTableTableManager get desiredStateRows =>
      $$DesiredStateRowsTableTableManager(_db, _db.desiredStateRows);
  $$DesiredStateDependencyRowsTableTableManager
  get desiredStateDependencyRows =>
      $$DesiredStateDependencyRowsTableTableManager(
        _db,
        _db.desiredStateDependencyRows,
      );
  $$DesiredStateAttemptRowsTableTableManager get desiredStateAttemptRows =>
      $$DesiredStateAttemptRowsTableTableManager(
        _db,
        _db.desiredStateAttemptRows,
      );
  $$SyncRunRowsTableTableManager get syncRunRows =>
      $$SyncRunRowsTableTableManager(_db, _db.syncRunRows);
  $$TaskDeleteTombstoneRowsTableTableManager get taskDeleteTombstoneRows =>
      $$TaskDeleteTombstoneRowsTableTableManager(
        _db,
        _db.taskDeleteTombstoneRows,
      );
  $$TaskDeleteSnapshotRowsTableTableManager get taskDeleteSnapshotRows =>
      $$TaskDeleteSnapshotRowsTableTableManager(
        _db,
        _db.taskDeleteSnapshotRows,
      );
  $$TaskDueChangeGroupRowsTableTableManager get taskDueChangeGroupRows =>
      $$TaskDueChangeGroupRowsTableTableManager(
        _db,
        _db.taskDueChangeGroupRows,
      );
  $$TaskDueChangeSnapshotRowsTableTableManager get taskDueChangeSnapshotRows =>
      $$TaskDueChangeSnapshotRowsTableTableManager(
        _db,
        _db.taskDueChangeSnapshotRows,
      );
  $$BulkOperationRowsTableTableManager get bulkOperationRows =>
      $$BulkOperationRowsTableTableManager(_db, _db.bulkOperationRows);
  $$BulkOperationMemberRowsTableTableManager get bulkOperationMemberRows =>
      $$BulkOperationMemberRowsTableTableManager(
        _db,
        _db.bulkOperationMemberRows,
      );
  $$SyncFactRowsTableTableManager get syncFactRows =>
      $$SyncFactRowsTableTableManager(_db, _db.syncFactRows);
  $$TaskListPreferenceRowsTableTableManager get taskListPreferenceRows =>
      $$TaskListPreferenceRowsTableTableManager(
        _db,
        _db.taskListPreferenceRows,
      );
  $$ViewPreferenceRowsTableTableManager get viewPreferenceRows =>
      $$ViewPreferenceRowsTableTableManager(_db, _db.viewPreferenceRows);
}
