import 'dart:io';

import 'package:flutter/material.dart';

import 'src/data/google_tasks/mutation_probe.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    GoogleTasksMutationProbeApp(configuration: configurationFromEnvironment()),
  );
}

GoogleTasksMutationProbeConfiguration configurationFromEnvironment() =>
    GoogleTasksMutationProbeConfiguration(
      clientId: const String.fromEnvironment('AXIOTASK_LINUX_AUTH_CLIENT_ID'),
      clientSecret: const String.fromEnvironment(
        'AXIOTASK_LINUX_AUTH_CLIENT_SECRET',
      ),
      subjectFile: File(
        const String.fromEnvironment('AXIOTASK_LINUX_AUTH_SUBJECT_FILE'),
      ),
      instanceName: const String.fromEnvironment(
        'AXIOTASK_GOOGLE_TASKS_MUTATION_PROBE_INSTANCE',
      ),
    );

final class GoogleTasksMutationProbeApp extends StatefulWidget {
  const GoogleTasksMutationProbeApp({required this.configuration, super.key});

  final GoogleTasksMutationProbeConfiguration configuration;

  @override
  State<GoogleTasksMutationProbeApp> createState() =>
      _GoogleTasksMutationProbeAppState();
}

final class _GoogleTasksMutationProbeAppState
    extends State<GoogleTasksMutationProbeApp> {
  late final Future<GoogleTasksMutationProbeResult> _result =
      runGoogleTasksMutationProbe(widget.configuration);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Axiotask Google mutation proof')),
        body: SelectionArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: FutureBuilder<GoogleTasksMutationProbeResult>(
              future: _result,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Column(
                    key: const Key('google-mutation-probe-failed'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Icon(Icons.error_outline),
                      const Text('GOOGLE TASKS MUTATION PROBE FAILED'),
                      const SizedBox(height: 12),
                      SelectableText(snapshot.error.toString()),
                    ],
                  );
                }
                final result = snapshot.data;
                if (result == null) {
                  return const Column(
                    key: Key('google-mutation-probe-pending'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Complete authorization in the system browser.'),
                      Text(
                        'Only the pinned dedicated test account is allowed.',
                      ),
                    ],
                  );
                }
                return Column(
                  key: const Key('google-mutation-probe-passed'),
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
