import 'package:flutter/material.dart';

import 'composition/app_composition.dart';

class AxiotaskApp extends StatelessWidget {
  const AxiotaskApp({required this.composition, super.key});

  final AppComposition composition;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Axiotask',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const <Widget>[
                Text('Axiotask', style: TextStyle(fontSize: 32)),
                SizedBox(height: 8),
                Text('Google Tasks for Linux and Android'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
