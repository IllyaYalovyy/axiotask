import 'package:axiotask/main.dart';
import 'package:axiotask/src/app/composition/test_composition.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('launches the Axiotask shell', (tester) async {
    await tester.pumpWidget(
      AxiotaskApp(composition: TestComposition.create(instanceId: 'smoke')),
    );

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text('Axiotask'), findsOneWidget);
    expect(find.text('Google Tasks for Linux and Android'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
