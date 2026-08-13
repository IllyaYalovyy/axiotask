import 'package:flutter/material.dart';

void main() => runApp(const AxiotaskApp());

class AxiotaskApp extends StatelessWidget {
  const AxiotaskApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Axiotask',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const Scaffold(
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
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
