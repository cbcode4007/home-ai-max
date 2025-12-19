import 'package:flutter/material.dart';

class ScreensaverShell extends StatelessWidget {
  final Widget child;

  const ScreensaverShell({super.key, required this.child});

  void _exitScreensaver(BuildContext context) {
    // Pop the current route (the screensaver) using the local navigator so
    // we return to the route that pushed the screensaver (usually home).
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Listener(
        // Use opaque so interactions are reliably detected
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _exitScreensaver(context),
        onPointerMove: (_) => _exitScreensaver(context),
        onPointerSignal: (_) => _exitScreensaver(context),
        child: Focus(
          autofocus: true,
          onKeyEvent: (_, __) {
            _exitScreensaver(context);
            return KeyEventResult.handled;
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _exitScreensaver(context),
            onPanDown: (_) => _exitScreensaver(context),
            child: ColoredBox(
              color: Colors.black,
              child: SafeArea(
                child: Center(child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

