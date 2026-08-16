import 'dart:async';

import 'package:flutter/material.dart';

import '../core/diagnostics/diagnostics.dart';
import '../data/database/schema_verifier.dart';
import '../domain/model/tasks.dart';
import '../domain/repository/account_backup_repository.dart';
import '../sync/health/sync_health_repository.dart';
import 'axiotask_app.dart';
import 'tasks_feature_runtime.dart';

typedef AxiotaskRuntimeOpener = Future<AxiotaskRuntime> Function();
typedef AccountBackupPageBuilder =
    Widget Function(
      BuildContext context,
      AccountId accountId,
      AccountBackupRepository repository,
      AccountBackupRestoreRepository restoreRepository,
      SyncHealthRepository syncHealthRepository,
      Future<void> Function()? importCommitted,
    );

final class AxiotaskBootstrap extends StatefulWidget {
  const AxiotaskBootstrap({
    required this.openRuntime,
    required this.diagnostics,
    this.diagnosticsBuilder,
    this.accountBackupBuilder,
    super.key,
  });

  final AxiotaskRuntimeOpener openRuntime;
  final DiagnosticSink diagnostics;
  final WidgetBuilder? diagnosticsBuilder;
  final AccountBackupPageBuilder? accountBackupBuilder;

  @override
  State<AxiotaskBootstrap> createState() => _AxiotaskBootstrapState();
}

final class _AxiotaskBootstrapState extends State<AxiotaskBootstrap> {
  AxiotaskRuntime? _runtime;
  StreamSubscription<Object>? _storageFailureSubscription;
  var _opening = true;
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    final generation = ++_generation;
    if (mounted) {
      setState(() {
        _opening = true;
      });
    }
    try {
      final runtime = await widget.openRuntime();
      if (!mounted || generation != _generation) {
        await runtime.close();
        return;
      }
      setState(() {
        _runtime = runtime;
        _opening = false;
      });
      _storageFailureSubscription = runtime.fatalStorageFailures.listen(
        _storageFailed,
      );
      unawaited(_start(runtime));
    } on Object catch (error) {
      if (!mounted || generation != _generation) return;
      final code = _safeDatabaseFailureCode(error);
      widget.diagnostics.record(
        DiagnosticEvent(
          subsystem: DiagnosticSubsystem.storage,
          kind: DiagnosticEventKind.failure,
          code: 'database.open_failed',
          operation: 'open_database',
          fields: <DiagnosticField>[DiagnosticField.safe('failure_code', code)],
        ),
      );
      setState(() {
        _opening = false;
      });
    }
  }

  Future<void> _start(AxiotaskRuntime runtime) async {
    try {
      await runtime.start();
    } on Object {
      widget.diagnostics.record(
        const DiagnosticEvent(
          subsystem: DiagnosticSubsystem.application,
          kind: DiagnosticEventKind.failure,
          code: 'application.runtime_start_failed',
          operation: 'start_runtime',
        ),
      );
    }
  }

  @override
  void dispose() {
    _generation += 1;
    final runtime = _runtime;
    unawaited(_storageFailureSubscription?.cancel());
    if (runtime != null) unawaited(runtime.close());
    super.dispose();
  }

  void _storageFailed(Object error) {
    if (!mounted || _runtime == null) return;
    final runtime = _runtime!;
    _runtime = null;
    unawaited(_storageFailureSubscription?.cancel());
    _storageFailureSubscription = null;
    unawaited(runtime.close());
    final code = _safeDatabaseFailureCode(error);
    widget.diagnostics.record(
      DiagnosticEvent(
        subsystem: DiagnosticSubsystem.storage,
        kind: DiagnosticEventKind.failure,
        code: 'database.became_unavailable',
        operation: 'use_database',
        fields: <DiagnosticField>[DiagnosticField.safe('failure_code', code)],
      ),
    );
    setState(() {
      _opening = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final runtime = _runtime;
    if (runtime != null) {
      final repository = runtime.accountBackupRepository;
      final restoreRepository = runtime.accountBackupRestoreRepository;
      final syncHealthRepository = runtime.syncHealthRepository;
      return AxiotaskApp(
        viewModel: runtime.viewModel,
        diagnosticsBuilder: widget.diagnosticsBuilder,
        accountBackupBuilder:
            repository == null ||
                restoreRepository == null ||
                syncHealthRepository == null ||
                widget.accountBackupBuilder == null
            ? null
            : (context) => widget.accountBackupBuilder!(
                context,
                runtime.viewModel.accountId,
                repository,
                restoreRepository,
                syncHealthRepository,
                runtime.viewModel.localEditCommitted,
              ),
      );
    }
    return DatabaseRecoveryApp(
      opening: _opening,
      retryOpen: _opening ? null : _open,
    );
  }
}

final class DatabaseRecoveryApp extends StatelessWidget {
  const DatabaseRecoveryApp({
    required this.opening,
    required this.retryOpen,
    super.key,
  });

  final bool opening;
  final VoidCallback? retryOpen;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Axiotask',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(title: const Text('Axiotask')),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      opening ? Icons.storage_rounded : Icons.warning_amber,
                      size: 52,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      opening ? 'Opening task storage…' : 'Tasks unavailable',
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      opening
                          ? 'Checking the saved task database before the app starts.'
                          : 'Axiotask could not safely open saved tasks. Your '
                                'local data has been left in place. Editing and '
                                'Google synchronization are stopped.',
                      textAlign: TextAlign.center,
                    ),
                    if (!opening) ...<Widget>[
                      const SizedBox(height: 12),
                      Text(
                        'Diagnostic code: database.open_failed',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 24),
                      Semantics(
                        label: 'Retry opening task storage',
                        button: true,
                        child: FilledButton.icon(
                          onPressed: retryOpen,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry Open'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _safeDatabaseFailureCode(Object error) {
  if (error case SchemaVerificationException(:final code)) {
    return switch (code) {
      'database_unreadable' ||
      'integrity_check_failed' ||
      'foreign_key_check_failed' ||
      'schema_version_mismatch' ||
      'schema_objects_mismatch' ||
      'schema_contract_mismatch' ||
      'schema_sql_missing' ||
      'pragma_result_malformed' => code,
      _ => 'database_validation_failed',
    };
  }
  return 'database_unavailable';
}
