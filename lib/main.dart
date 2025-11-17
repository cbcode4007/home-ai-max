/*
  File:        lib/main.dart

  Author:      Colin Fajardo

  Version:     4.0.4               
               - restructured code to be nicer and more practical for debugging               

  Description: Main file that assembles, and controls the logic of the Home AI Max Flutter app.
*/


import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:audioplayers/audioplayers.dart';
import 'widgets/orb_visualizer.dart';
import 'stt/stt_manager.dart';
import 'config.dart';
import 'device_utils.dart';
import 'porcupine_service.dart';
import 'local_server/local_server.dart';


final DeviceUtils deviceUtils = DeviceUtils();

void main() {
  runApp(const HomeAIMaxApp());
}

class HomeAIMaxApp extends StatelessWidget {
  const HomeAIMaxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Home AI Max',
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.dark(
          primary: Colors.deepPurpleAccent,
          secondary: Colors.blueAccent,
        ),
        scaffoldBackgroundColor: const Color(0xFF181A20),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Color(0xFF23243A),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      home: const MainScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final List<String> _debugLog = [];
  bool _isSpeaking = false;
  late final FlutterTts _tts;
  LocalServer? _localServer;
  late final AudioPlayer _audioPlayer;
  final Map<String, String> _config = {};
  bool _debugLogVisible = false;
  bool _autoSendSpeech = false;
  bool _hostMode = false;
  double _userBrightness = 0.2;
  PorcupineService? porcupineService;

  // Called when Porcupine detects a wake word. Toggles listening if not already listening.
  void _onWakeDetected(int keywordIndex) {
    _addDebug('Porcupine detected keyword index=$keywordIndex');
    // Only trigger UI actions on the main thread
    if (!mounted) return;
    // If we're already listening via the orb, do nothing
    if (_isListening) return;
    // Toggle listening (do not await to avoid blocking the detection callback)
    _toggleListening();
  }

  void _addDebug(String message) {
    setState(() {
      _debugLog.add('[${DateTime.now().toIso8601String().substring(11,19)}] $message');
      if (_debugLog.length > 10) {
        _debugLog.removeAt(0);
      }
    });
  }

  // Helper method to update brightness based on orb state (only if host mode is enabled)
  Future<void> _updateBrightnessForOrbState() async {
    if (!_hostMode) return; // Don't touch brightness if host mode is off
    
    final isOrbActive = _isListening || _isSpeaking;
    if (isOrbActive) {
      await deviceUtils.setBrightness(1.0);
      _addDebug('Brightness set to max (orb active)');
    } else {
      await deviceUtils.setBrightness(_userBrightness);
      _addDebug('Brightness reset to user setting (orb inactive)');
    }
  }

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    // Load config early into a centralized variable used across the app
    await _initConfig();
    // Store the initial device brightness set by the user beforehand to return to later
    // This preserves the user's current brightness setting without changing it
    _userBrightness = await deviceUtils.getBrightness();
    _addDebug('Preserved user brightness: $_userBrightness');
    // Create STT manager and wire callbacks into the UI/state
    _sttManager = SttManager(
      onResult: (words) {
        setState(() {
          _lastRecognized = words;
          _controller.text = _lastRecognized;
          _controller.selection = TextSelection.fromPosition(
            TextPosition(offset: _controller.text.length),
          );
        });
    _addDebug('Transcribing (mic button): "$words"');
      },
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          setState(() {
            _isListening = false;
          });
          _addDebug('Listening stopped (mic button) - status: $status');
          // Update brightness based on orb state
          _updateBrightnessForOrbState();
          // Auto-send only when speech recognition is truly complete ('done' status)
          final shouldAutoSend = MediaQuery.of(context).orientation == Orientation.landscape ||
                               (_autoSendSpeech && _controller.text.trim().isNotEmpty);
          if (status == 'done' && shouldAutoSend && !_autoSentThisSession) {
            _autoSentThisSession = true;
            _addDebug('Auto-sending speech: "${_controller.text.trim()}"');
            _sendText();
          }
        }
      },
      onError: (err) {
        setState(() {
          _isListening = false;
        });
        _addDebug('Listening error: $err');
        // Update brightness based on orb state
        _updateBrightnessForOrbState();
        // Listen to wake word again (don't do anything else until it is ready; 4.0.3)
        if (_hostMode) {
          porcupineService?.start();
        }
      },
      onLog: _addDebug,
    );
    _tts = FlutterTts();
    _audioPlayer = AudioPlayer();
    _audioPlayer.onPlayerComplete.listen((event) {
      setState(() => _isSpeaking = false);
      _addDebug('AudioPlayer: playback complete');
      // Update brightness based on orb state
      _updateBrightnessForOrbState();
    });    
    // 4.0.4, turned repeated starting Flask server and initializing Porcupine into a separate method
    if (_hostMode) {
      await _startHostServices();
    }    
    _addDebug('Initializing TTS');
    _tts.setStartHandler(() {
      setState(() => _isSpeaking = true);
      _addDebug('TTS: start handler called');
      // Update brightness based on orb state
      _updateBrightnessForOrbState();
    });
    _tts.setCompletionHandler(() {
      setState(() => _isSpeaking = false);
      _addDebug('TTS: completion handler called');
      // Update brightness based on orb state
      _updateBrightnessForOrbState();
    });
    _tts.setErrorHandler((msg) {
      setState(() => _isSpeaking = false);
      _addDebug('TTS: error handler called: $msg');
      // Update brightness based on orb state
      _updateBrightnessForOrbState();
    });
  }

  Future<void> _initConfig() async {
    try {
      final webhook = await ConfigManager.getWebhookUrl();
      final tts = await ConfigManager.getTtsServerUrl();
      final debugVisible = await ConfigManager.getDebugLogVisible();
      final autoSend = await ConfigManager.getAutoSendSpeech();
      final hostMode = await ConfigManager.getHostMode();
      setState(() {
        _config['webhook'] = webhook;
        _config['tts'] = tts;
        _debugLogVisible = debugVisible;
        _autoSendSpeech = autoSend;
        _hostMode = hostMode;
      });
      _addDebug('Config loaded: webhook=$webhook tts=$tts debugVisible=$debugVisible autoSend=$autoSend hostMode=$hostMode');
      // Note: Brightness is handled separately in _initializeApp() to preserve user's current setting
    } catch (e) {
      _addDebug('Failed to load config: $e');
    }
  }

  Future<void> _startHostServices() async {
    if (_localServer == null) {
      // Start local server to receive notifications from Flask
      _addDebug('Starting local server...');
      _localServer = LocalServer(
        onSpeak: (String message) async {
          if (!mounted) return;
          setState(() {
            _feedbackMessage = message;
          });
          _addDebug('Received message: $message');
          await _playTtsServer(message);
        },
        onControl: (Map<String, dynamic> data) async {
          try {
            final vol = data['volume'] as Map<String, dynamic>;
            if (vol.containsKey('level')) {
              String volLevel = vol['level'].toString().toLowerCase();
              _addDebug("Level was provided: $volLevel");
              deviceUtils.setVolume(double.parse(volLevel));
            } else if (vol.containsKey('tune')) {
              String volTune = vol['tune'].toString().toLowerCase();
              _addDebug("Tune was provided: $volTune");
              if (volTune == "increment") {
                deviceUtils.volumeUp();
              } else if (volTune == "decrement") {
                deviceUtils.volumeDown();
              } else {
                _addDebug('tune key provided with no valid value');
              }
            } else {
              _addDebug('/control called with no valid keys');
            }
          } catch (e) {
            _addDebug('Control handler exception: $e');
          }
        },
        onLog: _addDebug,
      );
        try {
          await _localServer?.start();
        } catch (e) {
          _addDebug('Failed to start local server: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Local server failed to start: $e')),
            );
          }
          // If server fails, we don't proceed to start porcupine
          return;
        }
    }
    if (porcupineService == null) {
      // Start porcupine service to constantly listen for Maxine wake word
        _addDebug('Starting porcupine service...');
        porcupineService = PorcupineService(onWake: _onWakeDetected);
        try {
          await porcupineService!.initFromAssetPaths(
            "smt9H1XEv468kWRh0SnXkmOnDxCx2/DEXOwkTXFwzwPmM1IKwg1ykQ==",
            ["assets/Maxine_en_android_v3_0_0.ppn"],
          );
          await porcupineService!.start();
        } catch (e) {
          _addDebug('Failed to initialize/start porcupine: $e');
          // Clean up if initialization failed
          try {
            await porcupineService?.dispose();
          } catch (_) {}
          porcupineService = null;
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Wake-word service failed to start: $e')),
            );
          }
          return;
        }
    }
    return;
  }

  Future<void> _stopHostServices() async {
    if (_localServer != null) {
      _addDebug('Shutting down local server...');
      await _localServer?.stop();
      _localServer = null;
    }
    if (porcupineService != null) {
      _addDebug('Shutting down porcupine service...');
      await porcupineService?.dispose();
      porcupineService = null;
    }
  }

  Future<void> _resetSettings() async {
    try {
      await ConfigManager.setConfigValue('webhook_url', ConfigManager.defaultWebhookUrl);
      await ConfigManager.setConfigValue('tts_server_url', ConfigManager.defaultTtsUrl);
      await ConfigManager.setDebugLogVisible(false);
      await ConfigManager.setAutoSendSpeech(false);
      await ConfigManager.setHostMode(false);
      // When disabling host mode, close the server and porcupine service (when already running)
      // 4.0.4, turned stopping Flask server and disposing Porcupine into a separate method
      _stopHostServices();
      _addDebug('Host mode disabled: local server and porcupine service stopped');
      await _initConfig();
    } catch (e) {
      _addDebug('Failed to reset defaults: $e');
    }
  }

  final TextEditingController _controller = TextEditingController();
  bool _isLoading = false;
  String? _feedbackMessage;

  late SttManager _sttManager;
  bool _isListening = false;
  String _lastRecognized = '';
  bool _autoSentThisSession = false;

  @override
  void dispose() {
    _sttManager.dispose();
    _tts.stop();
    _audioPlayer.dispose();
    _localServer?.stop();
    // Stop and dispose porcupine service if active
    porcupineService?.dispose();
    super.dispose();
  }

  // 4.0.4, Local server logic has been moved to 'lib/local_server/local_server.dart'

  // On orb press
  Future<void> _toggleListening() async {
    // When STT listening
    if (_isListening) {
      _addDebug('Stopping listening');
      await _sttManager.stop();
      setState(() {
        _isListening = false;
      });
      _addDebug('Listening stopped');
      if (_hostMode) {
        // Listen for wake word again instead (don't do anything else until it is ready; 4.0.3)
        await porcupineService?.start();
        _addDebug('Porcupine service restarted');
      }      
      // Update brightness based on orb state
      _updateBrightnessForOrbState();
      
    // When STT not listening and needs to initialize
    } else {
      _addDebug('Initializing listening');
      if (_hostMode) {
        // Free up microphone from porcupine service (don't do anything else until it is done; 4.0.3)
        await porcupineService?.stop();
        _addDebug('Porcupine service stopped for transcription');
      }
      bool available = await _sttManager.initialize();

      // When STT not listening and already initialized
      if (available) {
        setState(() {
          _isListening = true;
          _controller.clear();
          _autoSentThisSession = false;
        });
        _addDebug('Listening started (mic button)');
        // Update brightness based on orb state
        _updateBrightnessForOrbState();
        // Produces onResult and onStatus events (handled by STT manager callbacks)
        await _sttManager.startListening(localeId: 'en_US');
      } else {
        _addDebug('Speech recognizer not available (mic button)');
      }
    }
  }

  Future<void> _sendText() async {
    final text = _controller.text.trim();
    final encodedBody = jsonEncode({'query': text});
    final headers = {'Content-Type': 'application/json'};
    if (text.isEmpty) {
      // Listen to wake word again (don't do anything else until it is ready; 4.0.3)
      if (_hostMode) {
        await porcupineService?.start();
      }
      return;
    }
    setState(() {
      _isLoading = true;
      _feedbackMessage = null;
    });
    try {
      final webhookUrl = _config['webhook'] ?? await ConfigManager.getWebhookUrl();
      _addDebug('Payload: $encodedBody');
      final response = await http.post(
        Uri.parse(webhookUrl),
        headers: headers,
        body: encodedBody,
      // Timeout modified from 5 to 20 seconds for AI with reasoning effort
      ).timeout(const Duration(seconds: 20));
      _addDebug('Response: ${response.statusCode} ${response.reasonPhrase}');
      if (response.statusCode >= 200 && response.statusCode < 300) {        
        try {
          final decoded = jsonDecode(response.body);
          _addDebug('Response JSON decoded');

          if (decoded['status'] == 'ok') {
            final message = decoded['message'] ?? '';
            final audioB64 = decoded['audio_b64'];

            if (message.isNotEmpty) {
              _addDebug('Server reply: $message');
              setState(() {
                _feedbackMessage = message;
              });

              // Listen to wake word again (don't do anything else until it is ready; 4.0.3)
              if (_hostMode) {
                await porcupineService?.start();
                _addDebug('Porcupine service restarted');
              }

              // Play audio if available
              if (audioB64 != null && audioB64.isNotEmpty) {
                _addDebug('Playing GTTS base64 audio from response');
                setState(() => _isSpeaking = true);
                // Update brightness based on orb state
                await _updateBrightnessForOrbState();
                try {
                  // Decode base64 audio
                  final audioBytes = base64Decode(audioB64);
                  await _audioPlayer.play(BytesSource(audioBytes));
                } catch (e) {
                  _addDebug('Base64 audio playback error: $e');
                  // Fallback to local TTS
                  await _playTtsLocal(message);
                }
              } else {
                // No audio, use local TTS
                setState(() => _isSpeaking = true);
                // Update brightness based on orb state
                await _updateBrightnessForOrbState();
                await _playTtsLocal(message);
              }              
            } else {
              setState(() {
                _feedbackMessage = 'Message sent successfully! (no reply)';
              });
            }
          } else {
            // Error status from server
            final errorMessage = decoded['message'] ?? 'Unknown error';
            setState(() {
              _feedbackMessage = 'Server error: $errorMessage';
            });
          }
        } catch (e) {
          _addDebug('JSON parsing error: $e');
          setState(() {
            _feedbackMessage = 'Response parsing error: $e';
          });
        }
        _controller.clear();
      } else {
        setState(() {
          _feedbackMessage = 'Failed to send: \n${response.statusCode} ${response.reasonPhrase}';
        });
      }
    } catch (e) {
      _addDebug('Error sending: $e');
      setState(() {
        _feedbackMessage = 'Error: \n${e.toString()}';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _playTtsServer(String text) async {
    try {
      final ttsUrl = _config['tts'] ?? await ConfigManager.getTtsServerUrl();
      final uri = Uri.parse(ttsUrl);
      _addDebug('Requesting TTS from $uri');
      final resp = await http.post(uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'text': text}),
      ).timeout(const Duration(seconds: 8));
      _addDebug('TTS response: ${resp.statusCode} ${resp.reasonPhrase}');
      _addDebug('TTS response headers: ${resp.headers}');
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final contentType = resp.headers['content-type'] ?? '';
        if (contentType.contains('audio') && resp.bodyBytes.isNotEmpty) {
          _addDebug('Playing returned audio (${resp.bodyBytes.length} bytes)');
          setState(() => _isSpeaking = true);
          // Update brightness based on orb state
          await _updateBrightnessForOrbState();
          try {
            await _audioPlayer.play(BytesSource(resp.bodyBytes));
          } catch (e) {
            _addDebug('AudioPlayer.play error: $e');
            // fallback to local TTS
            await _playTtsLocal(text);
          }
        } else {
          // Not audio, maybe JSON with text reply
          _addDebug('TTS response is not audio, falling back to local TTS');
          String? reply;
          try {
            final decoded = jsonDecode(resp.body);
            if (decoded is Map) reply = decoded['reply'] ?? decoded['message'] ?? decoded['text'];
          } catch (_) {
            // ignore
          }
          await _playTtsLocal(reply ?? text);
        }
      } else {
        _addDebug('TTS request failed: ${resp.statusCode}');
        await _playTtsLocal(text);
      }
    } catch (e) {
      _addDebug('Error requesting TTS: $e');
      await _playTtsLocal(text);
    }
  }

  Future<void> _playTtsLocal(String text) async {
    try {
      _addDebug('TTS: using local TTS');
      _addDebug('TTS: preparing to speak');
      await _tts.setLanguage('en-US');
      await _tts.setPitch(1.0);
      final speakResult = await _tts.speak(text);
      _addDebug('TTS.speak returned: $speakResult');
      // some platforms return immediately and call completion handler later
    } catch (e, st) {
      _addDebug('TTS speak error: $e\n$st');
      setState(() => _isSpeaking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final orientation = MediaQuery.of(context).orientation;
    return Scaffold(
      appBar: orientation == Orientation.landscape ? null : AppBar(
        title: const Text('Home AI Max'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showConfigDialog,
          ),
        ],
      ),
      body: SafeArea(
        child: OrientationBuilder(
          builder: (context, orientation) {
            // Landscape: minimal UI — centered orb and subtitles beneath
            if (orientation == Orientation.landscape) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    OrbVisualizer(
                      isSpeaking: _isSpeaking,
                      isListening: _isListening,
                      size: 120,
                      onTap: _isLoading ? null : _toggleListening,
                    ),
                    const SizedBox(height: 12),
                    if (_feedbackMessage != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24.0),
                        child: Text(
                          _feedbackMessage!,
                          style: const TextStyle(fontSize: 18, color: Colors.white),
                          textAlign: TextAlign.center,
                        ),
                      ),
                  ],
                ),
              );
            }

            // Portrait: full UI (existing layout)
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Orb visual (animates when speaking or listening)
                    OrbVisualizer(
                      isSpeaking: _isSpeaking,
                      isListening: _isListening,
                      size: 120,
                      onTap: _isLoading ? null : _toggleListening,
                    ),
                    const SizedBox(height: 48),
                    _buildTextInput(context),
                    const SizedBox(height: 16),
                    if (_isLoading) const CircularProgressIndicator(),
                    if (_feedbackMessage != null && !_isLoading)
                      Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: Builder(builder: (context) {
                          final msg = _feedbackMessage!;
                          Color color;
                          final lower = msg.toLowerCase();
                          if (msg.startsWith('Message sent') || msg.startsWith('Config reloaded')) {
                            color = Colors.greenAccent;
                          } else if (lower.startsWith('error') || lower.contains('failed') || lower.contains('error')) {
                            color = Colors.redAccent;
                          } else {
                            // Normal server-returned text should be white
                            color = Colors.white;
                          }
                          return Text(
                            msg,
                            style: TextStyle(
                              color: color,
                              fontWeight: FontWeight.w500,
                            ),
                            textAlign: TextAlign.center,
                          );
                        }),
                      ),
                    const SizedBox(height: 32),
                    // Debug log area (only shown if enabled)
                    if (_debugLogVisible)
                      Container(
                        alignment: Alignment.bottomLeft,
                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                        decoration: BoxDecoration(
                          color: Color.fromARGB((0.7 * 255).round(), 0, 0, 0),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        constraints: const BoxConstraints(maxHeight: 120),
                        child: SingleChildScrollView(
                          reverse: true,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: _debugLog.map((msg) => Text(
                              msg,
                              style: const TextStyle(fontSize: 12, color: Colors.greenAccent),
                            )).toList(),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildTextInput(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            minLines: 1,
            maxLines: 5,
            style: const TextStyle(fontSize: 18),
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _sendText(),
            decoration: const InputDecoration(
              hintText: 'Type your message...'
            ),
            onChanged: (_) => setState(() {}),
            enabled: !_isLoading && !_isListening,
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.send_rounded),
          color: Theme.of(context).colorScheme.primary,
          onPressed: _controller.text.trim().isEmpty || _isLoading || _isListening ? null : _sendText,
        ),
      ],
    );
  }

  Future<void> _showConfigDialog() async {
    final webhook = await ConfigManager.getWebhookUrl();
    final tts = await ConfigManager.getTtsServerUrl();
    bool debugVisible = await ConfigManager.getDebugLogVisible();
    bool autoSend = await ConfigManager.getAutoSendSpeech();
    bool hostMode = await ConfigManager.getHostMode();
    if (!mounted) return;
    final webhookCtrl = TextEditingController(text: webhook);
    final ttsCtrl = TextEditingController(text: tts);
    final formKey = GlobalKey<FormState>();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Settings (v4.0.3)'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 20),
              TextFormField(
                controller: webhookCtrl,
                decoration: const InputDecoration(labelText: 'Server Base URL'),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Server URL cannot be empty';
                  if (!v.startsWith('http')) return 'Must be a valid URL';
                  return null;
                },
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: ttsCtrl,
                decoration: const InputDecoration(labelText: 'TTS Server URL'),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'TTS server cannot be empty';
                  if (!v.startsWith('http')) return 'Must be a valid URL';
                  return null;
                },
              ),
              const SizedBox(height: 20),
              StatefulBuilder(
                builder: (context, setState) => SwitchListTile(
                  title: const Text('Show Debug Log'),
                  value: debugVisible,
                  onChanged: (value) {
                    setState(() {
                      debugVisible = value;
                    });
                  },
                ),
              ),
              const SizedBox(height: 6),
              StatefulBuilder(
                builder: (context, setState) => SwitchListTile(
                  title: const Text('Auto-Send Speech'),
                  value: autoSend,
                  onChanged: (value) {
                    setState(() {
                      autoSend = value;
                    });
                  },
                ),
              ),
              const SizedBox(height: 6),
              StatefulBuilder(
                builder: (context, setState) => SwitchListTile(
                  title: const Text('Host Mode'),
                  value: hostMode,
                  onChanged: (value) async {
                    bool? confirm = await showDialog<bool>(
                      context: context,
                      builder: (BuildContext context) {
                        return AlertDialog(
                          title: Text('Confirm Host Mode Toggle'),
                          content: hostMode == true 
                          ? Text('Are you sure you want to disable Host Mode? This will shut down the local server without exiting the app, quickly stopping incoming requests.')
                          : Text('Are you sure you want to enable Host Mode? This will start up a local server to receive requests from other devices on the network.'),
                          actions: <Widget>[
                            TextButton(
                              child: Text('Cancel'),
                              onPressed: () {
                                Navigator.of(context).pop(false); // User canceled
                              },
                            ),
                            TextButton(
                              child: Text('Confirm'),
                              onPressed: () {
                                Navigator.of(context).pop(true); // User confirmed
                              },
                            ),
                          ],
                        );
                      }
                    );
                    // If user confirmed, update the switch state
                    if (confirm == true) {
                      setState(() {
                        hostMode = value;
                      });
                    }
                  }
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              if (mounted) Navigator.of(context).pop();
            },
            child: const Text('Cancel'),
          ),
          // Save button
          TextButton(
            onPressed: () async {
              // Save entered values
              if (formKey.currentState?.validate() != true) return;
              final newWebhook = webhookCtrl.text.trim();
              final newTts = ttsCtrl.text.trim();
              await ConfigManager.setConfigValue('webhook_url', newWebhook);
              await ConfigManager.setConfigValue('tts_server_url', newTts);
              await ConfigManager.setDebugLogVisible(debugVisible);
              await ConfigManager.setAutoSendSpeech(autoSend);
              await ConfigManager.setHostMode(hostMode);
              if (hostMode) {
                // When enabling host mode, start the server and porcupine wake word service (not already running)
                // Await this so we can surface errors immediately instead of waiting for a restart
                _addDebug('Enabling host mode (starting host services)...');
                await _startHostServices();
                _addDebug('Host mode enabled: local server and porcupine service started');
              }
              else {
                // When disabling host mode, close the server and porcupine service (when already running)
                // Await to ensure resources are released immediately
                await _stopHostServices();
                _addDebug('Host mode disabled: local server and porcupine service stopped');
              }
              // Ensure the state is still mounted before using the State's context
              if (!mounted) return;
              Navigator.of(this.context).pop();
              _addDebug('Settings saved');
              // refresh in-memory config cache
              await _initConfig();
              // user-visible confirmation
              if (mounted) {
                ScaffoldMessenger.of(this.context).showSnackBar(
                  const SnackBar(content: Text('Settings saved')),
                );
              }
            },
            child: const Text('Save'),
          ),
          // Reset button
          TextButton(
            onPressed: () async {
              // Show confirmation dialog
              final confirmed = await showDialog<bool>(
                context: context,
                useRootNavigator: true,
                builder: (context) => AlertDialog(
                  title: const Text('Confirm Reset'),
                  content: const Text('Reset these settings to default and save?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('Reset'),
                    ),
                  ],
                ),
              ) ?? false;
              if (!confirmed) return;
              // Reset stored values to defaults
              await _resetSettings();              
              // refresh in-memory config cache immediately so UI updates
              if (!mounted) return;
              Navigator.of(this.context).pop();
              _addDebug('Settings reset to defaults');
              ScaffoldMessenger.of(this.context).showSnackBar(
                const SnackBar(content: Text('Settings reset to defaults')),
              );
            },
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }
}
