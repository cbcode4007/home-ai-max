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
