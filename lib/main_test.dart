import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'src/app/axiotask_app.dart';
import 'src/app/composition/test_composition.dart';
import 'src/app/connectivity.dart';
import 'src/app/lifecycle.dart';
import 'src/app/tasks_feature_runtime.dart';

const String _instanceId = String.fromEnvironment(
  'AXIOTASK_TEST_INSTANCE',
  defaultValue: 'manual-synthetic',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final composition = TestComposition.create(instanceId: _instanceId);
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
