import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'src/app/axiotask_product.dart';
import 'src/app/composition/linux_read_transport.dart';
import 'src/app/composition/release_composition.dart';
import 'src/app/config/linux_profile_configuration.dart';
import 'src/app/connectivity.dart';
import 'src/app/lifecycle.dart';
import 'src/app/tasks_feature_runtime.dart';

export 'src/app/axiotask_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final linuxConfiguration = Platform.isLinux
      ? await _loadLinuxConfiguration(LinuxApplicationProfile.production)
      : null;
  final composition = await ReleaseComposition.open(
    linuxReadConfiguration:
        linuxConfiguration?.google ??
        const LinuxReadConfiguration(clientId: '', clientSecret: ''),
  );
  final lifecycle = Platform.isLinux ? LinuxLifecycleBridge() : null;
  final connectivity = Platform.isLinux
      ? await LinuxConnectivityBridge.open()
      : null;
  runApp(
    AxiotaskProduct(
      clock: composition.clock,
      diagnostics: composition.diagnostics,
      diagnosticHistory: composition.diagnosticHistory,
      diagnosticExporter: composition.diagnosticExporter,
      services: ProductPlatformServices.forPlatform(defaultTargetPlatform),
      openRuntime: () => TasksFeatureRuntime.open(
        composition,
        lifecycle: lifecycle,
        connectivity: connectivity,
      ),
    ),
  );
}

Future<LinuxProfileConfiguration> _loadLinuxConfiguration(
  LinuxApplicationProfile profile,
) async {
  try {
    return await LinuxProfileConfiguration.load(profile: profile);
  } on LinuxProfileConfigurationException catch (error) {
    stderr.writeln(error);
    exit(78);
  }
}
