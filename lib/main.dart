import 'package:flutter/widgets.dart';

import 'src/app/axiotask_app.dart';
import 'src/app/composition/release_composition.dart';
import 'src/app/tasks_feature_runtime.dart';

export 'src/app/axiotask_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final composition = ReleaseComposition.create();
  final runtime = await TasksFeatureRuntime.open(composition);
  runApp(AxiotaskApp(viewModel: runtime.viewModel));
}
