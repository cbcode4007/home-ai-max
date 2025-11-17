import 'dart:convert';
import 'dart:io';

typedef ControlCallback = Future<void> Function(Map<String, dynamic> data);
typedef LogCallback = void Function(String msg);

class ControlHandler {
  final ControlCallback onControl;
  final LogCallback? onLog;

  ControlHandler(this.onControl, {this.onLog});

  Future<void> handle(HttpRequest request) async {
    int status = 200;
    String resp = 'Received';
    try {
      final body = await utf8.decoder.bind(request).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      // Basic validation: expect a `volume` key
      if (!data.containsKey('volume')) {
        status = 400;
        resp = 'Bad Request';
        onLog?.call('ControlHandler: missing volume key');
      } else {
        onLog?.call('ControlHandler: received control payload');
        await onControl(data);
        resp = 'OK';
      }
    } catch (e) {
      onLog?.call('ControlHandler error: $e');
      status = 400;
      resp = 'Bad Request';
    }

    try {
      request.response.statusCode = status;
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.headers.set('Access-Control-Allow-Methods', 'POST, OPTIONS');
      request.response.write(resp);
      await request.response.close();
    } catch (_) {}
  }
}
