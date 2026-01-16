import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:math' show pow;
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

  String fetchError = "";

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    fetchWeather();
    _refreshTimer =
        Timer.periodic(const Duration(minutes: 5), (_) => fetchWeather());
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
            // 'https://api.weather.gc.ca/collections/citypageweather-realtime/items/on-117?f=json',
            'http://192.168.123.128:5001/envcanada_api',
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
    } catch (e) {
      // intentionally silent for screensaver use
      // print('Weather fetch error');
      if (mounted) {
        setState(() => fetchError = e.toString());
      }      
    } finally {
      _fetching = false;
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  // IconData getIcon(int code) {
  //   if (code <= 9) return Icons.wb_sunny;
  //   if (code <= 18) return Icons.cloud;
  //   if (code <= 29) return Icons.grain;
  //   if (code <= 39) return Icons.ac_unit;
  //   return Icons.help;
  // }

  Widget weatherIcon(dynamic iconField, {double size = 50}) {
    if (iconField == null) return Icon(Icons.help, size: size);

    String? url;

    if (iconField is String) {
      url = iconField;
    } else if (iconField is Map) {
      if (iconField['url'] is String) url = iconField['url'];
      // if (url == null && iconField['value'] is num) {
      //   return Icon(getIcon(iconField['value']), size: size);
      // }
    // } else if (iconField is num) {
    //   return Icon(getIcon(iconField.toInt()), size: size);
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

  Color colorScaffoldBackground() {
    final sunrise = data?['riseSet']['sunrise']['en'];
    final Color dayColor = const Color.fromARGB(255, 17, 124, 167);
    final sunset = data?['riseSet']['sunset']['en'];
    final Color nightColor = const Color(0xFF181A20);
    if (sunrise != null && sunset != null) {
      if (DateTime.now().isAfter(DateTime.parse(sunrise)) &&
          DateTime.now().isBefore(DateTime.parse(sunset))) {
        return dayColor;
      } else {
        // return dayColor;
        return nightColor;
      }
    }
    return dayColor;
  }

  String getLocalDateString(apiDate) {
    final utcDate = DateTime.parse(apiDate);
    final localDate = utcDate.toLocal();
    final strDate =
    '${localDate.year.toString().padLeft(4, '0')}-'
    '${localDate.month.toString().padLeft(2, '0')}-'
    '${localDate.day.toString().padLeft(2, '0')} '
    '${localDate.hour.toString().padLeft(2, '0')}:'
    '${localDate.minute.toString().padLeft(2, '0')}:'
    '${localDate.second.toString().padLeft(2, '0')}';
    return strDate;
  }

  num getWindchill(num temp, num windspeed) {
    if (temp < 10 && windspeed >= 5) {
      final powTerm = pow(windspeed.toDouble(), 0.16);
      final windchill = 13.12 + 0.6215 * temp - 11.37 * powTerm + 0.3965 * temp * powTerm;
      return windchill;
    } else {
      return temp;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading && data == null) {
      return const Scaffold(
        body: Center(child: Text('Loading weather…')),
      );
    }

    if (data == null) {
      return Scaffold(
        body: Center(child: Text('Weather unavailable: $fetchError')),
      );
    }

    final cur = data!['currentConditions'];
    final curTemp = cur['temperature']['value']['en'];
    // final curFeel = cur['windChill']['value']['en'];
    final windSpeed = cur['wind']['speed']['value']['en'];
    final curCond = cur['condition']['en'];
    // final curIconField = cur['iconCode'];

    final curIconOriginal = cur['iconCode']['url'];
    String curIconOriginalString = curIconOriginal.toString();
    dynamic curIconField = curIconOriginalString.replaceAll('https://weather.gc.ca/weathericons', 'http://192.168.123.128:5001/envcanada');    

    final forecasts =
            (data!['forecastGroup']['forecasts'] as List).take(4).toList();
    final lastUpdated = data!['lastUpdated'];

    final lastUpdatedStr = getLocalDateString(lastUpdated);

    // Wind Speed handling (sometimes values like "calm" will appear instead of a wind speed number)
    // Get string from json and see whether or not it can be parsed to int
    final windSpeedString = windSpeed.toString();
    // Default to 0 if parsing fails
    int? windSpeedNum = int.tryParse(windSpeedString);
    windSpeedNum ??= 0;

    final curFeel = getWindchill(curTemp, windSpeedNum);

    return Scaffold(
      backgroundColor: colorScaffoldBackground(),
      body: Stack(
        children: [
          Padding(
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
                        style:
                            TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 16),
                      weatherIcon(curIconField, size: 80),
                      const SizedBox(height: 12),
                      Text(
                        '$curTemp°C',
                        style: const TextStyle(
                            fontSize: 50, fontWeight: FontWeight.bold),
                      ),
                      if (curFeel != curTemp)
                        Text(
                          "Feels like ${curFeel.toStringAsFixed(1)}°C",
                          textAlign: TextAlign.center,
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
                          temp =
                              picked?['value']?['en']?.toString() ?? '—';
                        }

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            const SizedBox(height: 60),

                            // PERIOD NAME (fixed height)
                            SizedBox(
                              height: 52,
                              child: Text(
                                titleCase(f['period']['textForecastName']['en']),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),

                            // ICON (fixed height)
                            SizedBox(
                              height: 44,
                              child: Center(
                                child: weatherIcon(
                                  f['abbreviatedForecast']['icon'],
                                  size: 40,
                                ),
                              ),
                            ),

                            const SizedBox(height: 8),

                            // TEMPERATURE (fixed height)
                            SizedBox(
                              // height: 28,
                              height: 44,
                              child: Text(
                                '$temp°C',
                                style: const TextStyle(
                                  fontSize: 25,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),

                            const SizedBox(height: 10),

                            // SUMMARY (fixed height prevents shifting)
                            SizedBox(
                              height: 48,
                              child: Text(
                                f['abbreviatedForecast']['textSummary']['en'],
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 12),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),

          // UPDATED TIMESTAMP (top-right overlay)
          Positioned(
            top: 12,
            right: 16,
            child: Text(
              'Updated: $lastUpdatedStr',
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withOpacity(0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }
}