import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;

typedef TtsLog = void Function(String msg);
typedef TtsStart = void Function();
typedef TtsComplete = void Function();
typedef TtsError = void Function(String msg);

class TtsManager {
  final FlutterTts _tts = FlutterTts();
  final AudioPlayer _player = AudioPlayer();
  final TtsLog? onLog;
  final TtsStart? onStart;
  final TtsComplete? onComplete;
  final TtsError? onError;

  TtsManager({this.onLog, this.onStart, this.onComplete, this.onError});

  void init() {
    _player.onPlayerComplete.listen((_) {
      onLog?.call('TtsManager: player complete');
      try {
        onComplete?.call();
      } catch (_) {}
    });
    _tts.setStartHandler(() {
      onLog?.call('TtsManager: flutter_tts start');
      try { onStart?.call(); } catch (_) {}
    });
    _tts.setCompletionHandler(() {
      onLog?.call('TtsManager: flutter_tts complete');
      try { onComplete?.call(); } catch (_) {}
    });
    _tts.setErrorHandler((msg) {
      onLog?.call('TtsManager: flutter_tts error: $msg');
      try { onError?.call(msg); } catch (_) {}
    });
  }

  Future<void> playAudioBytes(Uint8List bytes) async {
    try {
      onLog?.call('TtsManager: playing audio bytes (${bytes.length} bytes)');
      onStart?.call();
      await _player.play(BytesSource(bytes));
    } catch (e) {
      onLog?.call('TtsManager: audio player error: $e');
      try { onError?.call(e.toString()); } catch (_) {}
      rethrow;
    }
  }

  Future<void> speakLocal(String text) async {
    try {
      onLog?.call('TtsManager: speaking locally: $text');
      await _tts.setLanguage('en-US');
      await _tts.setPitch(1.0);
      onStart?.call();
      await _tts.speak(text);
    } catch (e) {
      onLog?.call('TtsManager: local TTS error: $e');
      try { onError?.call(e.toString()); } catch (_) {}
      rethrow;
    }
  }

  /// Request TTS from server URL (POST {'text': text})
  /// If server returns audio bytes (content-type audio) play them, otherwise fall back to local TTS
  Future<void> requestAndPlayFromServer(String ttsUrl, String text, {Duration timeout = const Duration(seconds: 8)}) async {
    try {
      onLog?.call('TtsManager: requesting TTS from $ttsUrl');
      final resp = await http.post(Uri.parse(ttsUrl), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'text': text})).timeout(timeout);
      onLog?.call('TtsManager: TTS response ${resp.statusCode}');
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final contentType = resp.headers['content-type'] ?? '';
        if (contentType.contains('audio') && resp.bodyBytes.isNotEmpty) {
          await playAudioBytes(Uint8List.fromList(resp.bodyBytes));
          return;
        }
        // not audio, try to interpret as JSON with a reply field
        try {
          final decoded = jsonDecode(resp.body);
          String? reply;
          if (decoded is Map) reply = decoded['reply'] ?? decoded['message'] ?? decoded['text'];
          await speakLocal(reply ?? text);
          return;
        } catch (_) {
          await speakLocal(text);
          return;
        }
      } else {
        onLog?.call('TtsManager: TTS server returned non-2xx: ${resp.statusCode}');
        await speakLocal(text);
        return;
      }
    } catch (e) {
      onLog?.call('TtsManager: error requesting TTS: $e');
      await speakLocal(text);
    }
  }

  /// Given a decoded payload response (from PayloadService), play any included audio or speak the message
  Future<void> playPayloadResponse(Map<String, dynamic> decoded) async {
    final message = decoded['message'] ?? '';
    final audioB64 = decoded['audio_b64'];
    if (audioB64 != null && (audioB64 as String).isNotEmpty) {
      try {
        final bytes = base64Decode(audioB64);
        await playAudioBytes(Uint8List.fromList(bytes));
        return;
      } catch (e) {
        onLog?.call('TtsManager: error decoding base64 audio: $e');
        if (message != null && (message as String).isNotEmpty) {
          await speakLocal(message);
          return;
        }
      }
    }
    if (message != null && (message as String).isNotEmpty) {
      await speakLocal(message);
      return;
    }
  }

  Future<void> dispose() async {
    try {
      await _player.dispose();
    } catch (_) {}
    try {
      await _tts.stop();
    } catch (_) {}
  }
}