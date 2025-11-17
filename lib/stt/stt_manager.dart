import 'package:speech_to_text/speech_to_text.dart' as stt;

typedef SttResultCallback = void Function(String recognizedWords);
typedef SttStatusCallback = void Function(String status);
typedef SttErrorCallback = void Function(String errorMsg);
typedef LogCallback = void Function(String msg);

class SttManager {
  final SttResultCallback onResult;
  final SttStatusCallback onStatus;
  final SttErrorCallback onError;
  final LogCallback? onLog;

  late final stt.SpeechToText _speech;
  bool _initialized = false;
  bool _isListening = false;

  SttManager({
    required this.onResult,
    required this.onStatus,
    required this.onError,
    this.onLog,
  }) {
    _speech = stt.SpeechToText();
  }

  bool get isInitialized => _initialized;
  bool get isListening => _isListening;

  /// Initialize the speech recognizer, returns true if available/ready
  Future<bool> initialize() async {
    try {
      final available = await _speech.initialize(
        onStatus: (status) {
          onLog?.call('STT onStatus: $status');
          onStatus(status);
        },
        onError: (error) {
          final msg = error.errorMsg;
          onLog?.call('STT onError: $msg');
          onError(msg);
        },
      );
      _initialized = available;
      onLog?.call('STT initialize returned: $available');
      return available;
    } catch (e) {
      onLog?.call('STT initialize exception: $e');
      onError(e.toString());
      _initialized = false;
      return false;
    }
  }

  // Start listening (assumes initialize() was called and returned true),
  // returns true if listen was requested
  Future<bool> startListening({String localeId = 'en_US'}) async {
    if (!_initialized) {
      final ok = await initialize();
      if (!ok) return false;
    }
    try {
      _speech.listen(
        onResult: (result) {
          onLog?.call('STT onResult: ${result.recognizedWords}');
          onResult(result.recognizedWords);
        },
        localeId: localeId,
      );
      _isListening = true;
      onLog?.call('STT listen requested');
      return true;
    } catch (e) {
      onLog?.call('STT listen error: $e');
      onError(e.toString());
      _isListening = false;
      return false;
    }
  }

  // Stop listening if doing so
  Future<void> stop() async {
    try {
      await _speech.stop();
    } catch (_) {}
    _isListening = false;
    onLog?.call('STT stopped');
  }

  Future<void> dispose() async {
    try {
      await _speech.stop();
    } catch (_) {}
    _initialized = false;
    _isListening = false;
    onLog?.call('STT disposed');
  }
}
