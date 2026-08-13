import 'package:flutter/material.dart';

import 'src/data/database/native_database_probe.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const instanceName = String.fromEnvironment(
    'AXIOTASK_DATABASE_PROBE_INSTANCE',
  );
  runApp(DatabaseProbeApp(instanceName: instanceName));
}

final class DatabaseProbeApp extends StatelessWidget {
  const DatabaseProbeApp({required this.instanceName, super.key});

  final String instanceName;

  Future<NativeDatabaseProbeResult> _run() =>
      runNativeDatabaseProductionPathProbe(instanceName);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: FutureBuilder<NativeDatabaseProbeResult>(
            future: _run(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const Text(
                  'DATABASE PROBE FAILED',
                  key: Key('database-probe-failed'),
                );
              }
              final result = snapshot.data;
              if (result == null) {
                return const CircularProgressIndicator();
              }
              return Column(
                key: const Key('database-probe-passed'),
                mainAxisSize: MainAxisSize.min,
                children: result
                    .toRecord()
                    .entries
                    .map((entry) {
                      return Text('${entry.key}=${entry.value}');
                    })
                    .toList(growable: false),
              );
            },
          ),
        ),
      ),
    );
  }
}
