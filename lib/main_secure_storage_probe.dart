import 'package:flutter/material.dart';

import 'src/data/auth/linux/secure_storage_probe.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const instanceName = String.fromEnvironment(
    'AXIOTASK_SECURE_STORAGE_PROBE_INSTANCE',
  );
  runApp(SecureStorageProbeApp(instanceName: instanceName));
}

final class SecureStorageProbeApp extends StatelessWidget {
  const SecureStorageProbeApp({required this.instanceName, super.key});

  final String instanceName;

  Future<LinuxSecureStorageProbeResult> _run() =>
      runLinuxSecureStorageProbe(instanceName);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: FutureBuilder<LinuxSecureStorageProbeResult>(
            future: _run(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const Text(
                  'SECURE STORAGE PROBE FAILED',
                  key: Key('secure-storage-probe-failed'),
                );
              }
              final result = snapshot.data;
              if (result == null) {
                return const CircularProgressIndicator();
              }
              return Column(
                key: const Key('secure-storage-probe-passed'),
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
