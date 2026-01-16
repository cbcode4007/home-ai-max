/*
  © 2025 Colin Bond
  All rights reserved.

  Version:     4.1.3
               - weather screen bug where the screen would go white whenever API wind speed value was not a number is fixed (handled)      
               - weather screen requests changed to be from flask server endpoint for older phone compatibility

  Description: Main file that assembles, and controls the logic of the Home AI Max Flutter app.
*/

import 'dart:io';
import 'package:home_ai_max/widgets/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:window_size/window_size.dart';


void main() {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    setWindowTitle('Home AI Max');
    setWindowMinSize(const Size(705, 300));
    setWindowMaxSize(const Size(705, 300));
    setWindowFrame(const Rect.fromLTWH(200, 200, 705, 300));
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const HomeAIMaxApp(),
    );
  }
}
