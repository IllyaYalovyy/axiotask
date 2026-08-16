import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'src/app/axiotask_app.dart';
import 'src/app/composition/development_composition.dart';
import 'src/app/composition/linux_read_transport.dart';
import 'src/app/connectivity.dart';
import 'src/app/lifecycle.dart';
import 'src/app/tasks_feature_runtime.dart';
import 'src/data/auth/authorization.dart';
import 'src/features/diagnostics/development_diagnostics_view.dart';

const String _expectedSubject = String.fromEnvironment(
  'AXIOTASK_DEVELOPMENT_ACCOUNT_SUBJECT',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final composition = await DevelopmentComposition.open(
    expectedDedicatedSubject: _expectedSubject.isEmpty
        ? null
        : const AccountSubject(_expectedSubject),
    linuxReadConfiguration: const LinuxReadConfiguration(
      clientId: String.fromEnvironment('AXIOTASK_LINUX_AUTH_CLIENT_ID'),
      clientSecret: String.fromEnvironment('AXIOTASK_LINUX_AUTH_CLIENT_SECRET'),
    ),
  );
  final lifecycle = Platform.isLinux ? LinuxLifecycleBridge() : null;
  final connectivity = Platform.isLinux
      ? await LinuxConnectivityBridge.open()
      : null;
  final runtime = await TasksFeatureRuntime.open(
    composition,
    lifecycle: lifecycle,
    connectivity: connectivity,
  );
  runApp(
    AxiotaskApp(
      viewModel: runtime.viewModel,
      diagnosticsBuilder: (_) => DevelopmentDiagnosticsHost(
        history: composition.diagnosticHistory,
        exporter: composition.diagnosticExporter,
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(runtime.start());
  });
}
