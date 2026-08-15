import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'src/app/axiotask_app.dart';
import 'src/app/composition/linux_read_transport.dart';
import 'src/app/composition/release_composition.dart';
import 'src/app/connectivity.dart';
import 'src/app/lifecycle.dart';
import 'src/app/tasks_feature_runtime.dart';

export 'src/app/axiotask_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final composition = ReleaseComposition.create(
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
  runApp(AxiotaskApp(viewModel: runtime.viewModel));
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(runtime.start());
  });
}
