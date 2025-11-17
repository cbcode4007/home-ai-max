import 'dart:convert';
import 'dart:io';

typedef SpeakCallback = Future<void> Function(String message);
typedef LogCallback = void Function(String msg);

class SpeakHandler {
  final SpeakCallback onSpeak;
  final LogCallback? onLog;

  SpeakHandler(this.onSpeak, {this.onLog});

  Future<void> handle(HttpRequest request) async {
    int status = 200;
    String resp = 'Received';
    try {
      final body = await utf8.decoder.bind(request).join();
      final data = jsonDecode(body);
      final message = (data['message'] ?? '').toString();
      if (message.isEmpty) {
        status = 400;
        resp = 'Bad Request';
        onLog?.call('SpeakHandler: missing message field');
      } else {
        onLog?.call('SpeakHandler: received message');
        await onSpeak(message);
        resp = 'OK';
      }
    } catch (e) {
      onLog?.call('SpeakHandler error: $e');
      status = 400;
      resp = 'Bad Request';
    }

    try {
      request.response.statusCode = status;
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.write(resp);
      await request.response.close();
    } catch (_) {}
  }
}
