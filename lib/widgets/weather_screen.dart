import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:window_size/window_size.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    setWindowTitle('Weather');
    setWindowMinSize(const Size(705, 300));
    setWindowMaxSize(const Size(705, 300));
    setWindowFrame(const Rect.fromLTWH(100, 100, 705, 300));
  }

  runApp(const WeatherApp());
}

/// Root app — safe to embed or host
class WeatherApp extends StatelessWidget {
  const WeatherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        colorScheme: const ColorScheme.dark(
          primary: Colors.deepPurpleAccent,
          secondary: Colors.blueAccent,
        ),
        scaffoldBackgroundColor: const Color(0xFF181A20),
      ),
      home: const IgnorePointer(
        child: WeatherScreen(),
      ),
    );
  }
}

class WeatherScreen extends StatefulWidget {
  const WeatherScreen({super.key});

  @override
  State<WeatherScreen> createState() => _WeatherScreenState();
}

class _WeatherScreenState extends State<WeatherScreen>
    with WidgetsBindingObserver {
  Map<String, dynamic>? data;
  bool loading = true;

  Timer? _refreshTimer;
  bool _fetching = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    fetchWeather();
    _refreshTimer =
        Timer.periodic(const Duration(minutes: 1), (_) => fetchWeather());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      fetchWeather();
    }
  }

  // Fetch weather data from Environment Canada API
  Future<void> fetchWeather() async {
    if (_fetching) return;
    _fetching = true;

    try {
      final resp = await http
          .get(Uri.parse(
            'https://api.weather.gc.ca/collections/citypageweather-realtime/items/on-117?f=json',
          ))
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final decoded = json.decode(resp.body);
        if (decoded['properties'] != null) {
          setState(() {
            data = decoded['properties'];
          });
          // print('Weather fetch successful');
        }                
      }
    } catch (_) {
      // intentionally silent for screensaver use
      // print('Weather fetch error');      
    } finally {
      _fetching = false;
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  IconData getIcon(int code) {
    if (code <= 9) return Icons.wb_sunny;
    if (code <= 18) return Icons.cloud;
    if (code <= 29) return Icons.grain;
    if (code <= 39) return Icons.ac_unit;
    return Icons.help;
  }

  Widget weatherIcon(dynamic iconField, {double size = 50}) {
    if (iconField == null) return Icon(Icons.help, size: size);

    String? url;

    if (iconField is String) {
      url = iconField;
    } else if (iconField is Map) {
      if (iconField['url'] is String) url = iconField['url'];
      if (url == null && iconField['value'] is num) {
        return Icon(getIcon(iconField['value']), size: size);
      }
    } else if (iconField is num) {
      return Icon(getIcon(iconField.toInt()), size: size);
    }

    if (url != null && url.startsWith('http')) {
      return Image.network(
        url,
        width: size,
        height: size,
        errorBuilder: (_, __, ___) => Icon(Icons.help, size: size),
      );
    }

    return Icon(Icons.help, size: size);
  }

  String titleCase(String input) {
    return input
        .split(' ')
        .map((w) =>
            w.isEmpty ? w : w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join(' ');
  }

  @override
  Widget build(BuildContext context) {
    if (loading && data == null) {
      return const Scaffold(
        body: Center(child: Text('Loading weather…')),
      );
    }

    if (data == null) {
      return const Scaffold(
        body: Center(child: Text('Weather unavailable')),
      );
    }

    final cur = data!['currentConditions'];
    final curTemp = cur['temperature']['value']['en'];
    final curCond = cur['condition']['en'];
    final curIconField = cur['iconCode'];

    final forecasts =
        (data!['forecastGroup']['forecasts'] as List).take(4).toList();

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // CURRENT
            Expanded(
              flex: 2,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'Current',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  weatherIcon(curIconField, size: 80),
                  const SizedBox(height: 12),
                  Text(
                    '$curTemp°C',
                    style: const TextStyle(
                        fontSize: 40, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(curCond, textAlign: TextAlign.center),
                ],
              ),
            ),

            // FORECASTS
            for (final f in forecasts)
              Expanded(
                child: Builder(
                  builder: (_) {
                    final name =
                        (f['period']?['textForecastName']?['en'] ?? '')
                            .toLowerCase();
                    final temps =
                        f['temperatures']?['temperature'] as List?;
                    String temp = '—';

                    if (temps != null && temps.isNotEmpty) {
                      final prefersLow = name.contains('night') ||
                          name.contains('overnight') ||
                          name.contains('evening');

                      Map? picked;
                      try {
                        picked = temps.firstWhere((t) =>
                            t['class']?['en'] ==
                            (prefersLow ? 'low' : 'high'));
                      } catch (_) {}

                      picked ??= temps.first;
                      temp = picked?['value']?['en']?.toString() ?? '—';
                    }

                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          titleCase(
                              f['period']['textForecastName']['en']),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 12),
                        weatherIcon(f['abbreviatedForecast']['icon'], size: 40),
                        const SizedBox(height: 6),
                        Text(
                          '$temp°C',
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          f['abbreviatedForecast']['textSummary']['en'],
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}