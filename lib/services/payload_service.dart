/*
  © 2025 Colin Bond
  All rights reserved.

  Version:     1.0.0                            

  Description: Simple service class for encapsulating all text payload sending and response handling.
*/

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'dart:async';

typedef PayloadLog = void Function(String msg);

class PayloadService {
  final http.Client _client;
  final PayloadLog? onLog;

  PayloadService({http.Client? client, this.onLog}) : _client = client ?? http.Client();

  /// Sends the text payload to the provided webhookUrl and returns the decoded JSON map
  /// Throws an exception when the request fails or the response cannot be parsed
  Future<Map<String, dynamic>> sendText(String text, String webhookUrl, {Duration timeout = const Duration(seconds: 20)}) async {
    onLog?.call('PayloadService: sending payload to $webhookUrl');
    final body = jsonEncode({'query': text});
    try {
      final resp = await _client.post(Uri.parse(webhookUrl), headers: {'Content-Type': 'application/json'}, body: body).timeout(timeout);
      onLog?.call('PayloadService: response ${resp.statusCode}');
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        try {
          final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
          return decoded;
        } catch (e) {
          onLog?.call('PayloadService: JSON decode error: $e');
          throw Exception('Response parsing error: $e');
        }
      } else {
        onLog?.call('PayloadService: non-2xx response: ${resp.statusCode}');
        throw Exception('Failed to send: ${resp.statusCode} ${resp.reasonPhrase}');
      }
    } on TimeoutException catch (e) {
      onLog?.call('PayloadService: timeout: $e');
      throw Exception('Request timed out');
    } catch (e) {
      onLog?.call('PayloadService: error: $e');
      rethrow;
    }
  }

  void dispose() {
    try {
      _client.close();
    } catch (_) {}
  }
}