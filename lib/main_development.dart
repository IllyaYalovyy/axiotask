import 'package:flutter/widgets.dart';

import 'src/app/axiotask_app.dart';
import 'src/app/composition/development_composition.dart';
import 'src/data/auth/authorization.dart';

const String _expectedSubject = String.fromEnvironment(
  'AXIOTASK_DEVELOPMENT_ACCOUNT_SUBJECT',
);

void main() {
  final composition = DevelopmentComposition.create(
    expectedDedicatedSubject: _expectedSubject.isEmpty
        ? null
        : const AccountSubject(_expectedSubject),
  );
  runApp(AxiotaskApp(composition: composition));
}
