import 'package:flutter/widgets.dart';

import 'src/app/axiotask_app.dart';
import 'src/app/composition/test_composition.dart';
import 'src/app/tasks_feature_runtime.dart';

const String _instanceId = String.fromEnvironment(
  'AXIOTASK_TEST_INSTANCE',
  defaultValue: 'manual-synthetic',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final composition = TestComposition.create(instanceId: _instanceId);
  final runtime = await TasksFeatureRuntime.open(composition);
  runApp(AxiotaskApp(viewModel: runtime.viewModel));
}
