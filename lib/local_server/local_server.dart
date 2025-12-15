/*
  © 2025 Colin Bond
  All rights reserved.

  Version:     1.0.0                            

  Description: Class for instantiating a local HTTP server for an app to handle incoming requests.
*/

import 'dart:io';

import 'speak_handler.dart';
import 'control_handler.dart';

typedef LogCallback = void Function(String msg);
typedef SpeakCallback = Future<void> Function(String message);
typedef ControlCallback = Future<void> Function(Map<String, dynamic> data);

class LocalServer {
  HttpServer? _server;
  final int port;
  final SpeakCallback onSpeak;
  final ControlCallback onControl;
  final LogCallback? onLog;

  LocalServer({
    this.port = 5000,
    required this.onSpeak,
    required this.onControl,
    this.onLog,
  });

  Future<void> start() async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      onLog?.call('Local server listening on port $port');

      final speak = SpeakHandler(onSpeak, onLog: onLog);
      final control = ControlHandler(onControl, onLog: onLog);

      _server!.listen((HttpRequest request) async {
        try {
          if (request.method == 'OPTIONS') {
            request.response.statusCode = 200;
            request.response.headers.set('Access-Control-Allow-Origin', '*');
            request.response.headers.set('Access-Control-Allow-Methods', 'POST, OPTIONS');
            request.response.write('OK');
            await request.response.close();
            return;
          }

          final path = request.uri.path;
          if (request.method == 'POST' && path == '/speak') {
            await speak.handle(request);
          } else if (request.method == 'POST' && path == '/control') {
            await control.handle(request);
          } else {
            request.response.statusCode = 404;
            request.response.write('Not found');
            await request.response.close();
          }
        } catch (e) {
          onLog?.call('LocalServer handler error: $e');
          try {
            request.response.statusCode = 500;
            request.response.write('Error');
            await request.response.close();
          } catch (_) {}
        }
      });
    } catch (e) {
      onLog?.call('Failed to start local server: $e');
      rethrow;
    }
  }

  Future<void> stop() async {
    try {
      await _server?.close(force: true);
      onLog?.call('Local server stopped');
    } catch (e) {
      onLog?.call('Error stopping server: $e');
    } finally {
      _server = null;
    }
  }
}
