// Basic UI package
import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
// Unique component of UI
import 'orb_visualizer.dart';
// Manages translation of recorded speech into text to send
import '../stt/stt_manager.dart';
// Manages the configuration of the app by loading and saving its settings
import '../config.dart';
// Manages utility settings for the device itself, namely volume and brightness
import '../device_utils.dart';
// Manages a specific wake word the device will listen for to proceed with an operation
import '../services/porcupine_service.dart';
// Manages a server that listens for incoming requests so that the AI backend can set things such as volume or brightness
import '../local_server/local_server.dart';
// Manages the transmission of HTTP payloads and their responses through the app
import '../services/payload_service.dart';
// Manages translation of responses into spoken audio, default through a server but can fall back to local device TTS
import '../tts/tts_manager.dart';

// Introduces the ability to use another app as a screen saver after enough inactivity
import '../screen_saver/screensaver_shell.dart';
// Screen saver for weather information
import 'weather_screen.dart';


// 4.0.9, main.dart is now the entry point and this file exposes the home screen of the app

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
  // Variables
  static const String version = '4.1.3';
  
  final List<String> _debugLog = [];
  bool _isSpeaking = false;
  LocalServer? _localServer;
  late PayloadService _payloadService;
  late TtsManager _ttsManager;
  final Map<String, String> _config = {};
  bool _debugLogVisible = false;
  bool _autoSendSpeech = false;
  bool _hostMode = false;
  double _userBrightness = 0.2;
  PorcupineService? porcupineService;
  final TextEditingController _controller = TextEditingController();
  bool _isLoading = false;
  String? _feedbackMessage;
  late SttManager _sttManager;
  bool _isListening = false;
  String _lastRecognized = '';
  bool _autoSentThisSession = false;  
  final DeviceUtils deviceUtils = DeviceUtils();
  // Determine whether we are running on desktop (Windows, Linux, macOS).
  // Desktop builds may not support device brightness/volume manipulation,
  // so gate those features during testing.
  final bool _isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  // 4.0.7, initialize variable for environment key
  String pKey = '';
  // 4.0.8, initialize flag for whether the program last listened to input via orb or wake word
  bool _lastListened = false;
  // Tracks whether any speech was detected during the current listening session
  bool _heardSpeechDuringSession = false;
  // 4.1.0
  // Timestamp when listening last started. Used to ignore spurious immediate
  // 'notListening'/'done' status events coming right after starting.
  DateTime? _lastListenStart;
  // 4.0.9, screensaver timer settings (persisted via ConfigManager)
  int _screensaverDelaySeconds = ConfigManager.defaultScreensaverDelaySeconds;
  Timer? _screensaverTimer;
  int _remaining = 0;

  /* Startup Functions (may run automatically during app startup) */

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  // Print a debug line to the in-app log, 20 are visible at a time
  void _addDebug(String message) {
    setState(() {
      // _debugLog.add('[${DateTime.now().toIso8601String().substring(11,19)}] $message');

      // _debugLog.add(
      //   '[${DateTime.now().toIso8601String().substring(11, 23)}] $message'
      // );

      final now = DateTime.now();
      final timestamp =
          '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}:'
          '${now.second.toString().padLeft(2, '0')}.'
          '${now.millisecond.toString().padLeft(3, '0')}';

      _debugLog.add('[$timestamp] $message');

      // if (_debugLog.length > 20) {
      //   _debugLog.removeAt(0);
      // }
    });
  }

  Future<void> _initializeApp() async {
    // Load config early into a centralized variable used across the app
    _addDebug("Entering _initConfig");
    await _initConfig();
    // Store the initial device brightness set by the user beforehand to return to later
    // This preserves the user's current brightness setting without changing it
    if (!_isDesktop) {
      _addDebug("Entering getBrightness");
      _userBrightness = await deviceUtils.getBrightness();
      // _addDebug('Preserved user brightness: $_userBrightness');
    }
    // Create STT manager and wire callbacks into the UI/state
    _sttManager = SttManager(
      onResult: (words) {
        _addDebug("Entering _initializeApp onResult callback");
        setState(() {
          _lastRecognized = words;
          _controller.text = _lastRecognized;
          _controller.selection = TextSelection.fromPosition(
            TextPosition(offset: _controller.text.length),
          );
          // Mark that we heard audio during this session
          _heardSpeechDuringSession = true;
        });
        _addDebug('Transcribing (mic button): "$words"');
      },
      // Callback for when a status is returned
      onStatus: (status) {
        // 4.1.0
        // Ignore very quick stop statuses that occur immediately after
        // starting listening, some platforms emit a transient 'notListening'
        // or 'done' right away when no audio is present, so if the status
        // arrives within a short grace period after requested start,
        // ignore it
        if ((status == 'done' || status == 'notListening') &&
            _lastListenStart != null &&
            DateTime.now().difference(_lastListenStart!) < const Duration(milliseconds: 400)) {
          _addDebug('Ignoring quick STT status "$status" (${DateTime.now().difference(_lastListenStart!).inMilliseconds}ms since start)');
          return;
        }

        if (status == 'done' || status == 'notListening') {
          // Clear the last-start marker now that we've seen a terminal status
          _lastListenStart = null;
          setState(() {
            _isListening = false;
          });
          _addDebug('Listening stopped (mic button) - status: $status');
          // Update brightness based on orb state
          _addDebug("Entering _updateBrightnessForOrbState");
          _updateBrightnessForOrbState();
          // If the listener stopped due to silence without any captured
          // speech in this session, clear the ongoing-conversation flag so
          // we don't treat the next action as a continuation
          if (!_heardSpeechDuringSession) {
            setState(() { _lastListened = false; });
            _addDebug('Listener timed out from silence, clearing _lastListened');
          }
          // Reset session-speech marker
          _heardSpeechDuringSession = false;
          // Auto-send only when speech recognition is truly complete ('done' status)
          // and always in landscape, only when auto-send is enabled in portrait
          final shouldAutoSend = MediaQuery.of(context).orientation == Orientation.landscape && _controller.text.trim().isNotEmpty ||
                               (_autoSendSpeech && _controller.text.trim().isNotEmpty);
          if (status == 'done' && shouldAutoSend && !_autoSentThisSession) {
            _autoSentThisSession = true;
            _addDebug('Auto-sending: "${_controller.text.trim()}"');
            _sendText();
          }
        }
      },
      // Callback for when an error occurs
      onError: (err) {
        setState(() {
          _isListening = false;
          // 4.0.8, end ongoing conversation if error occurs during listening
          _lastListened = false;
        });
        _addDebug('Listening error: $err');
        // Update brightness based on orb state
        _addDebug("Entering _updateBrightnessForOrbState");
        _updateBrightnessForOrbState();
        // Listen to wake word again (don't do anything else until it is ready; 4.0.3)
        if (_hostMode) {          
          porcupineService?.start();
        }
      },
      onLog: _addDebug,
    );
    // Initialize payload and TTS managers
    _payloadService = PayloadService(onLog: _addDebug);
    _ttsManager = TtsManager(
      onLog: _addDebug,
      onStart: () {
        setState(() => _isSpeaking = true);
        _addDebug('TTS: start handler');
        _addDebug("Entering _updateBrightnessForOrbState");
        _updateBrightnessForOrbState();
      },
      onComplete: () {
        setState(() => _isSpeaking = false);
        _addDebug('TTS: complete handler');
        _addDebug("Entering _updateBrightnessForOrbState");
        _updateBrightnessForOrbState();
      },
      onError: (msg) {
        setState(() => _isSpeaking = false);
        _addDebug('TTS: error handler: $msg');
        _addDebug("Entering _updateBrightnessForOrbState");
        _updateBrightnessForOrbState();
      },
    );
    _ttsManager.init();
    // 4.0.4, turned repeated starting Flask server and initializing Porcupine into a separate method
    if (_hostMode) {
      _addDebug("Entering _startHostServices");
      await _startHostServices();
    }    

    // Start the screensaver countdown after initialization
    setState(() => _remaining = _screensaverDelaySeconds);
    _startTimer();
  }

  Future<void> _initConfig() async {
    try {
      // Load all config values into the app
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
      // Load persisted screensaver delay (0 disables it)
      int screensaverDelay = await ConfigManager.getScreensaverDelaySeconds();
      if (_isDesktop) {
        screensaverDelay = 5;
      }
      setState(() {
        _screensaverDelaySeconds = screensaverDelay;
      });
      _addDebug('Config loaded: webhook=$webhook tts=$tts debugVisible=$debugVisible autoSend=$autoSend hostMode=$hostMode');
    } catch (e) {
      _addDebug('Failed to load config: $e');
    }
  }

  Future<void> _startHostServices() async {
    if (_localServer == null) {
      _addDebug('Starting local server...');
      _localServer = LocalServer(
        // Callback for when a command is received on the /speak endpoint
        // Play a received message using TTS manager
        onSpeak: (String message) async {
          if (!mounted) return;
          setState(() {
            _feedbackMessage = message;
          });
          _addDebug('Received message: $message');
          try {
            final ttsUrl = _config['tts'] ?? await ConfigManager.getTtsServerUrl();
            await _ttsManager.requestAndPlayFromServer(ttsUrl, message);
          } catch (e) {
            _addDebug('Error playing speak request: $e');
          }
        },
        // Callback for when a command is received on the /control endpoint
        onControl: (Map<String, dynamic> data) async {
          try {
            final vol = data['volume'] as Map<String, dynamic>;
            if (vol.containsKey('level')) {
              // Set volume to specified level
              String volLevel = vol['level'].toString().toLowerCase();
              _addDebug("Level was provided: $volLevel");
              if (!_isDesktop) {
                deviceUtils.setVolume(double.parse(volLevel));
              } else {
                _addDebug('Skipping volume change (desktop build)');
              }
            }
            else if (vol.containsKey('tune')) {
              // Change volume by arbitrary positive or negative amount
              String volTune = vol['tune'].toString().toLowerCase();
              _addDebug("Tune was provided: $volTune");
              if (volTune == "increment") {
                if (!_isDesktop) {
                  deviceUtils.volumeUp();
                } else {
                  _addDebug('Skipping volume up (desktop build)');
                }
              } else if (volTune == "decrement") {
                if (!_isDesktop) {
                  deviceUtils.volumeDown();
                } else {
                  _addDebug('Skipping volume down (desktop build)');
                }
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
        }
    }
    if (porcupineService == null) {
      // Start porcupine service to constantly listen for Maxine wake word
        _addDebug('Starting porcupine service...');
        porcupineService = PorcupineService(onWake: _onWakeDetected);
        try {
          _addDebug('Fetching API Key...');
          pKey = await _loadKey();
          _addDebug('Returned API Key: $pKey');
          await porcupineService!.initFromAssetPaths(
            pKey,
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

  Future<String> _loadKey() async {
    // 4.0.7, load API key from environment variable passed at compile time
    const apiKey = String.fromEnvironment('API_KEY', defaultValue: '');
    if (apiKey.isEmpty) {
      throw Exception('Missing API_KEY. Add it via --dart-define=API_KEY=... or provide a server-side proxy.');
    }
    return apiKey;
  }

  /* Input Functions (run after a user interaction with the interface) */

  @override
  void dispose() {
    _sttManager.dispose();
    _ttsManager.dispose();
    _payloadService.dispose();
    _localServer?.stop();
    porcupineService?.dispose();
    // Cancel screensaver timer
    _screensaverTimer?.cancel();
    super.dispose();
  }

  // 4.0.9
  void _startTimer() {
    _screensaverTimer?.cancel();
    // If screensaver is disabled (0 seconds), don't start a timer
    if (_screensaverDelaySeconds <= 0) {
      setState(() => _remaining = 0);
      return;
    }

    // Ensure remaining starts at configured delay
    setState(() => _remaining = _screensaverDelaySeconds);
    _screensaverTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_remaining <= 1) {
        t.cancel();
        _openScreensaver();
      } else {
        setState(() => _remaining--);
      }
    });
  }

  // 4.0.9, calls the weather screen widget to replace this one as a screensaver
  Future<void> _openScreensaver() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ScreensaverShell(
          child: WeatherScreen(),
        ),
      ),
    );

    // Returned from screensaver, reset timer
    setState(() => _remaining = _screensaverDelaySeconds);
    _startTimer();
  }

  // 4.0.9
  void _handleUserInteraction() {
    // Any touch or pointer input counts as activity, reset the timer
    if (_screensaverDelaySeconds <= 0) return;
    setState(() => _remaining = _screensaverDelaySeconds);
    _startTimer();
  }

  Future<void> _resetSettings() async {
    try {
      await ConfigManager.setConfigValue('webhook_url', ConfigManager.defaultWebhookUrl);
      await ConfigManager.setConfigValue('tts_server_url', ConfigManager.defaultTtsUrl);
      await ConfigManager.setScreensaverDelaySeconds(ConfigManager.defaultScreensaverDelaySeconds);
      await ConfigManager.setDebugLogVisible(false);
      await ConfigManager.setAutoSendSpeech(false);
      await ConfigManager.setHostMode(false);
      // Apply reset screensaver value immediately
      setState(() {
        _screensaverDelaySeconds = ConfigManager.defaultScreensaverDelaySeconds;
        _remaining = _screensaverDelaySeconds;
      });
      _startTimer();
      // When disabling host mode, close the server and porcupine service (when already running)
      // 4.0.4, turned stopping Flask server and disposing Porcupine into a separate method
      _stopHostServices();
      _addDebug('Host mode disabled: local server and porcupine service stopped');
      await _initConfig();
    } catch (e) {
      _addDebug('Failed to reset defaults: $e');
    }
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

  // On orb press, act with listeners depending on their current conditions
  Future<void> _toggleListening() async {
    // When STT listening
    if (_isListening) {
      _addDebug('Already listening, toggling listening off');
      await _sttManager.stop();
      setState(() {
        _isListening = false;
        _lastListened = false;
      });      
      _addDebug('Listening stopped');
      _addDebug("Conversation ended");
      if (_hostMode) {
        // Listen for wake word again instead (don't do anything else until it is ready; 4.0.3)
        await porcupineService?.start();
        _addDebug('Porcupine service restarted');
      }      
      // Update brightness based on orb state
      _addDebug("Entering _updateBrightnessForOrbState");
      _updateBrightnessForOrbState();
      
    // When STT not listening and needs to initialize
    } else {
      _addDebug('Not already listening, toggling listening on');
      if (_hostMode) {
        // Free up microphone from porcupine service (don't do anything else until this is done; 4.0.3)
        await porcupineService?.stop();
        _addDebug('Porcupine service stopped for transcription');
      }
      _addDebug("Entering STT manager initializer");
      bool available = await _sttManager.initialize();

      // When STT not listening and already initialized
      if (available) {
        _addDebug("STT available, starting listening");
        setState(() {
          _isListening = true;
          // 4.0.8, set flag for the last input method being the orb or a call word
          _lastListened = true;
          _controller.clear();
          _autoSentThisSession = false;
        });
        _addDebug('Listening started (mic button)');
        // Update brightness based on orb state
        _updateBrightnessForOrbState();
        // 4.1.0
        // Produces onResult and onStatus events (handled by STT manager callbacks)
        // Record the start time and request listening, this helps ignore
        // any immediate 'notListening' status some platforms emit right
        // after starting when no audio is present
        _lastListenStart = DateTime.now();

        await _sttManager.startListening(localeId: 'en_US');
        _addDebug('STT manager startListening returned true');
      } else {
        _addDebug('Speech recognizer not available (mic button)');
      }
    }
  }

  // POST the contents of text input to specified server endpoint, and try to display as well as read its response
  Future<void> _sendText() async {
    final text = _controller.text.trim();
    // Abort, end conversation and go back to listening to porcupine wake word if the text field got through while empty    
    if (text.isEmpty) {
      _addDebug("Text is empty, returning");
      if (_hostMode) await porcupineService?.start();
      setState(() {
        _lastListened = false;
      });      
      return;
    }
    setState(() {
      _isLoading = true;
      _feedbackMessage = null;
    });
    try {
      // POST to the set URL
      final webhookUrl = _config['webhook'] ?? await ConfigManager.getWebhookUrl();
      _addDebug('Sending payload to webhook: $webhookUrl');
      
      // Return response
      final decoded = await _payloadService.sendText(text, webhookUrl);
      _addDebug('PayloadService returned');

      final message = decoded['message'] ?? '';
      if (message != null && (message as String).isNotEmpty) {
        setState(() {
          _isLoading = false;
          _feedbackMessage = message;
        });
      }
      _controller.clear();
      try {
        // Play response
        await _ttsManager.playPayloadResponse(decoded);
      } catch (e) {
        _addDebug('TTS playback failed: $e');
      }

      // 4.0.8, listen for speech again after sending a spoken input and then
      // enable porcupine upon timeout if in host mode. Ensure porcupine is
      // restarted only after the payload response and any playback have fully
      // completed (TtsManager now awaits actual playback completion).
      if (_lastListened) {
        _addDebug('Ongoing conversation: listening again after spoken input');
        await _toggleListening();
      } else if (_hostMode) {
        // Only restart the wake-word listener when we're not continuing an
        // immediate voice conversation (i.e., when we aren't toggling STT).
        try {
          await porcupineService?.start();
          _addDebug('Porcupine service restarted');
        } catch (e) {
          _addDebug('Failed to restart porcupine after response: $e');
        }
      }

    } catch (e) {
      _addDebug('Error sending payload: $e');
      if (!mounted) return;
      setState(() {
        _feedbackMessage = 'Error: ${e.toString()}';
      });
    } 
    // finally {
    //   if (mounted) setState(() => _isLoading = false);
    // }
  }

  // Called when Porcupine detects a wake word, toggles listening if not already listening
  void _onWakeDetected(int keywordIndex) {
    _addDebug('Porcupine detected keyword index=$keywordIndex');
    // Only trigger UI actions on the main thread
    if (!mounted) return;
    // If we're already listening via the orb, do nothing
    if (_isListening) return;
    // Toggle listening (do not await to avoid blocking the detection callback)
    _toggleListening();
  }

  // Helper method to update brightness based on orb state (only if host mode is enabled)
  Future<void> _updateBrightnessForOrbState() async {
    if (!_hostMode) {
      _addDebug("Not host mode, returning");
      return;
    }

    // Skip brightness changes on desktop builds — not all platforms support
    // programmatic brightness control and it isn't useful when testing on desktop.
    if (_isDesktop) {
      // _addDebug('Desktop build detected — skipping brightness adjustments');
      return;
    }

    final isOrbActive = _isListening || _isSpeaking;
    if (isOrbActive) {
      await deviceUtils.setBrightness(1.0);
      // _addDebug('Brightness set to max (orb active)');
    } else {
      await deviceUtils.setBrightness(_userBrightness);
      // _addDebug('Brightness reset to user setting (orb inactive)');
    }
  }

  /* UI */

  @override
  Widget build(BuildContext context) {
    final orientation = MediaQuery.of(context).orientation;
    // Get the total screen height including any insets (keyboard space)
    final totalHeight = MediaQuery.of(context).size.height;
    // Calculate the height of the safe area (excluding system status bars/notches)
    final safeAreaHeight = MediaQuery.of(context).padding.top + MediaQuery.of(context).padding.bottom;
    // Calculate the actual usable height for the UI
    final usableHeight = totalHeight - safeAreaHeight;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _handleUserInteraction(),
      onPointerMove: (_) => _handleUserInteraction(),
      onPointerHover: (_) => _handleUserInteraction(),
      onPointerSignal: (_) => _handleUserInteraction(),
      child: Scaffold(
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
          child: SingleChildScrollView(
            child: SizedBox(
              height: usableHeight,
              child: OrientationBuilder(
                builder: (context, orientation) {
                  // Landscape, minimal UI with centered orb and subtitles beneath for dedicated use with voice
                  if (orientation == Orientation.landscape) {
                    return Center(
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
                          const SizedBox(height: 12),
                          if (_isLoading) const CircularProgressIndicator(),
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
                  // Portrait, full UI with the text input and debug log for feature rich use on a more convenient orientation
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
          ),
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
    final screensaverDelayCurrent = await ConfigManager.getScreensaverDelaySeconds();
    if (!mounted) return;
    final webhookCtrl = TextEditingController(text: webhook);
    final ttsCtrl = TextEditingController(text: tts);
    final screensaverCtrl = TextEditingController(text: screensaverDelayCurrent.toString());
    final formKey = GlobalKey<FormState>();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Settings (v$version)'),
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
              // Screensaver timeout input
              TextFormField(
                controller: screensaverCtrl,
                decoration: const InputDecoration(
                  labelText: 'Screensaver Timeout (seconds, 0 = disabled)',
                ),
                keyboardType: TextInputType.number,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Enter a number (0 to disable)';
                  final val = int.tryParse(v.trim());
                  if (val == null || val < 0) return 'Must be 0 or a positive integer';
                  return null;
                },
              ),
              const SizedBox(height: 16),
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
              const SizedBox(height: 4),
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
              const SizedBox(height: 4),             
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
                  final newScreensaver = int.tryParse(screensaverCtrl.text.trim()) ?? ConfigManager.defaultScreensaverDelaySeconds;
              await ConfigManager.setConfigValue('webhook_url', newWebhook);
                  await ConfigManager.setConfigValue('tts_server_url', newTts);
                  await ConfigManager.setScreensaverDelaySeconds(newScreensaver);
                  // Apply immediately in-memory and restart timer
                  setState(() {
                    _screensaverDelaySeconds = newScreensaver;
                    _remaining = newScreensaver;
                  });
                  _startTimer();
              await ConfigManager.setDebugLogVisible(debugVisible);
              await ConfigManager.setAutoSendSpeech(autoSend);
              await ConfigManager.setHostMode(hostMode);
              if (hostMode) {
                // When enabling host mode, start the server and porcupine wake word service (not already running)
                // Await this so errors surface immediately instead of waiting for a restart
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
              // Ensure the state is still mounted before using the State's context.
              // Use the dialog's `context` to pop only the dialog route (avoids
              // accidentally popping the app's main route and leaving a black
              // screen behind).
              if (!mounted) return;
              Navigator.of(context).pop();
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
              // Close the Settings dialog (use dialog context)
              Navigator.of(context).pop();
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
