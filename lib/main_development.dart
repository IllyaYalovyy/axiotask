import 'package:flutter/widgets.dart';

import 'src/app/axiotask_app.dart';
import 'src/app/composition/development_composition.dart';
import 'src/app/tasks_feature_runtime.dart';
import 'src/data/auth/authorization.dart';

const String _expectedSubject = String.fromEnvironment(
  'AXIOTASK_DEVELOPMENT_ACCOUNT_SUBJECT',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final composition = DevelopmentComposition.create(
    expectedDedicatedSubject: _expectedSubject.isEmpty
        ? null
        : const AccountSubject(_expectedSubject),
  );
  final runtime = await TasksFeatureRuntime.open(composition);
  runApp(AxiotaskApp(viewModel: runtime.viewModel));
}
