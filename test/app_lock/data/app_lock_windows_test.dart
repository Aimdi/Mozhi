import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/app_lock/data/app_lock_windows.dart';
import 'package:mozhi/quick_translate/quick_translate_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  QuickTranslateHost host(String route) => QuickTranslateHost(
    channel: const MethodChannel('test/quick_translate'),
    initialRoute: () => route,
  );

  group(AppLockWindow, () {
    test('is the main window for a normal start', () {
      expect(
        AppLockWindow.current(initialRoute: () => '/', quickHost: host('/')),
        AppLockWindow.main,
      );
      expect(
        AppLockWindow.current(
          initialRoute: () => '/translate?text=hola',
          quickHost: host('/translate?text=hola'),
        ),
        AppLockWindow.main,
      );
    });

    test('is the quick translate window', () {
      expect(
        AppLockWindow.current(
          initialRoute: () => QuickTranslateHost.location,
          quickHost: host(QuickTranslateHost.location),
        ),
        AppLockWindow.quickTranslate,
      );
    });

    test('is the screen-translate window', () {
      expect(
        AppLockWindow.current(
          initialRoute: () => screenTranslateLocation,
          quickHost: host(screenTranslateLocation),
        ),
        AppLockWindow.screenTranslate,
      );
    });

    test('reads the platform route by default', () {
      expect(AppLockWindow.current(), AppLockWindow.main);
    });

    test('protects only the main window', () {
      expect(AppLockWindow.main.protectsWindow, isTrue);
      expect(AppLockWindow.quickTranslate.protectsWindow, isFalse);
      expect(AppLockWindow.screenTranslate.protectsWindow, isFalse);
    });
  });
}
