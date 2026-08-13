import 'package:flutter/widgets.dart';

import 'src/app/axiotask_app.dart';
import 'src/app/composition/test_composition.dart';

const String _instanceId = String.fromEnvironment(
  'AXIOTASK_TEST_INSTANCE',
  defaultValue: 'manual-synthetic',
);

void main() {
  final composition = TestComposition.create(instanceId: _instanceId);
  runApp(AxiotaskApp(composition: composition));
}
