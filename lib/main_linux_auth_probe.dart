import 'dart:io';

import 'package:flutter/material.dart';

import 'src/data/auth/linux/linux_auth_probe.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(LinuxAuthProbeApp(configuration: configurationFromEnvironment()));
}

LinuxAuthProbeConfiguration configurationFromEnvironment() =>
    LinuxAuthProbeConfiguration(
      clientId: const String.fromEnvironment('AXIOTASK_LINUX_AUTH_CLIENT_ID'),
      clientSecret: const String.fromEnvironment(
        'AXIOTASK_LINUX_AUTH_CLIENT_SECRET',
      ),
      subjectFile: File(
        const String.fromEnvironment('AXIOTASK_LINUX_AUTH_SUBJECT_FILE'),
      ),
      instanceName: const String.fromEnvironment(
        'AXIOTASK_LINUX_AUTH_PROBE_INSTANCE',
      ),
    );

final class LinuxAuthProbeApp extends StatefulWidget {
  const LinuxAuthProbeApp({required this.configuration, super.key});

  final LinuxAuthProbeConfiguration configuration;

  @override
  State<LinuxAuthProbeApp> createState() => _LinuxAuthProbeAppState();
}

final class _LinuxAuthProbeAppState extends State<LinuxAuthProbeApp> {
  late final Future<LinuxAuthProbeResult> _result = _runProbe();

  Future<LinuxAuthProbeResult> _runProbe() async {
    try {
      return await runLinuxAuthProbe(widget.configuration);
    } catch (error, stackTrace) {
      debugPrint('Linux authorization probe failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Axiotask Linux authorization proof')),
        body: SelectionArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: FutureBuilder<LinuxAuthProbeResult>(
              future: _result,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Column(
                    key: const Key('linux-auth-probe-failed'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Icon(Icons.error_outline),
                      const Text('LINUX AUTHORIZATION PROBE FAILED'),
                      const SizedBox(height: 12),
                      SelectableText(snapshot.error.toString()),
                      const SizedBox(height: 12),
                      const Text('No Google Tasks changes were made.'),
                    ],
                  );
                }
                final result = snapshot.data;
                if (result == null) {
                  return const Column(
                    key: Key('linux-auth-probe-pending'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Complete authorization in the system browser.'),
                      Text('Only the dedicated test account is allowed.'),
                    ],
                  );
                }
                return Column(
                  key: const Key('linux-auth-probe-passed'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: result
                      .toRecord()
                      .entries
                      .map((entry) => Text('${entry.key}=${entry.value}'))
                      .toList(growable: false),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
