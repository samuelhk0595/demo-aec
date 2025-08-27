import 'package:flutter/material.dart';
import 'screens/walkie_talkie_screen.dart';

void main() {
  runApp(const WalkieTalkieApp());
}

class WalkieTalkieApp extends StatelessWidget {
  const WalkieTalkieApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Walkie Talkie',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange),
        useMaterial3: true,
      ),
      home: const WalkieTalkieScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
