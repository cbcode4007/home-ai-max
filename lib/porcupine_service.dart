/*
  © 2025 Colin Bond
  All rights reserved.

  Version:     1.0.0                            

  Description: Lightweight Porcupine wrapper for apps with wake words, simple initialization, start/stop, callback for detections.
*/

import 'package:flutter/foundation.dart';
import 'package:porcupine_flutter/porcupine_manager.dart';
// import 'package:porcupine_flutter/porcupine.dart';
import 'package:porcupine_flutter/porcupine_error.dart';

typedef WakeCallback = void Function(int keywordIndex);

class PorcupineService {
  PorcupineManager? _manager;
  bool _isListening = false;

  // Optional external callback for detections
  final WakeCallback? onWake;

  PorcupineService({this.onWake});

  bool get isInitialized => _manager != null;
  bool get isListening => _isListening;

  /// Initialize with custom keyword asset paths (e.g. ["assets/Maxine.ppn"]).
  Future<void> initFromAssetPaths(String accessKey, List<String> assetPaths) async {
    if (kIsWeb) {
      throw PorcupineException('Porcupine is not supported on web.');
    }

    try {
      _manager = await PorcupineManager.fromKeywordPaths(
        accessKey,
        assetPaths,
        _internalWakeCallback,
      );
    } on PorcupineException {
      rethrow;
    }
  }

  /// Internal callback invoked by the native Porcupine manager.
  void _internalWakeCallback(int index) {
    // Forward to registered callback if any
    try {
      onWake?.call(index);
    } catch (_) {}
  }

  /// Start detection (begin audio capture). Returns when started or throws.
  Future<void> start() async {
    if (_manager == null) throw StateError('Porcupine not initialized');
    try {
      await _manager?.start();
      _isListening = true;
    } on PorcupineException {
      _isListening = false;
      rethrow;
    }
  }

  /// Stop detection and release the microphone.
  Future<void> stop() async {
    if (_manager == null) return;
    try {
      await _manager?.stop();
    } catch (_) {}
    _isListening = false;
  }

  /// Dispose/cleanup - best-effort stop.
  Future<void> dispose() async {
    try {
      await _manager?.stop();
    } catch (_) {}
    _manager = null;
    _isListening = false;
  }
}
