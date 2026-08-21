import 'package:flutter/material.dart';

import 'src/data/auth/linux/secure_storage_probe.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const instanceName = String.fromEnvironment(
    'AXIOTASK_SECURE_STORAGE_PROBE_INSTANCE',
  );
  runApp(SecureStorageProbeApp(instanceName: instanceName));
}

typedef SecureStorageProbeRunner =
    Future<LinuxSecureStorageProbeResult> Function(String instanceName);

final class SecureStorageProbeApp extends StatefulWidget {
  const SecureStorageProbeApp({
    required this.instanceName,
    this.runner = runLinuxSecureStorageProbe,
    super.key,
  });

  final String instanceName;
  final SecureStorageProbeRunner runner;

  @override
  State<SecureStorageProbeApp> createState() => _SecureStorageProbeAppState();
}

final class _SecureStorageProbeAppState extends State<SecureStorageProbeApp> {
  late final Future<LinuxSecureStorageProbeResult> _result = widget.runner(
    widget.instanceName,
  );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: FutureBuilder<LinuxSecureStorageProbeResult>(
            future: _result,
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
