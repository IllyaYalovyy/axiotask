import 'package:flutter/widgets.dart';

import 'src/app/axiotask_app.dart';
import 'src/app/composition/release_composition.dart';

export 'src/app/axiotask_app.dart';

void main() {
  final composition = ReleaseComposition.create();
  runApp(AxiotaskApp(composition: composition));
}
