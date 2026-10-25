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

  AppLockWindow window(String route, AppLockWindow? platformWindow) =>
      AppLockWindow.current(
        initialRoute: () => route,
        quickHost: host(route),
        platformWindow: platformWindow,
      );

  tearDown(() => AppLockWindow.declared = null);

  group(AppLockWindow, () {
    test('is the main window for a normal start', () {
      expect(window('/', AppLockWindow.main), AppLockWindow.main);
      expect(window('/', null), AppLockWindow.main);
      expect(
        window('/translate?text=hola', AppLockWindow.main),
        AppLockWindow.main,
      );
    });

    test('is the quick translate window', () {
      expect(
        window(QuickTranslateHost.location, AppLockWindow.quickTranslate),
        AppLockWindow.quickTranslate,
      );
    });

    test('is the screen-translate window', () {
      expect(
        window(screenTranslateLocation, AppLockWindow.screenTranslate),
        AppLockWindow.screenTranslate,
      );
    });

    test('does not trust the route alone', () {
      // Another app started the main activity at a window's route.
      for (final platformWindow in [AppLockWindow.main, null]) {
        expect(
          window(screenTranslateLocation, platformWindow),
          AppLockWindow.main,
        );
        expect(
          window('https://example.org$screenTranslateLocation', platformWindow),
          AppLockWindow.main,
        );
        expect(
          window(QuickTranslateHost.location, platformWindow),
          AppLockWindow.main,
        );
      }
      // Nor routes that disagree with what the platform said.
      expect(
        window(screenTranslateLocation, AppLockWindow.quickTranslate),
        AppLockWindow.main,
      );
      expect(
        window(QuickTranslateHost.location, AppLockWindow.screenTranslate),
        AppLockWindow.main,
      );
    });

    test("does not trust the platform's word alone", () {
      expect(window('/', AppLockWindow.screenTranslate), AppLockWindow.main);
      expect(window('/', AppLockWindow.quickTranslate), AppLockWindow.main);
    });

    test('reads the declared window by default', () {
      AppLockWindow.declare(['window=screenTranslate']);
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

  group('AppLockWindow.fromEntrypointArgs', () {
    test('reads the window argument', () {
      for (final value in AppLockWindow.values) {
        expect(
          AppLockWindow.fromEntrypointArgs([
            'other',
            '${AppLockWindow.entrypointArgumentPrefix}${value.name}',
          ]),
          value,
        );
      }
    });

    test('is null without one or for an unknown window', () {
      expect(AppLockWindow.fromEntrypointArgs(const []), isNull);
      expect(AppLockWindow.fromEntrypointArgs(['window=']), isNull);
      expect(AppLockWindow.fromEntrypointArgs(['window=bubble']), isNull);
      expect(AppLockWindow.fromEntrypointArgs(['screenTranslate']), isNull);
    });

    test('takes the first window argument only', () {
      expect(
        AppLockWindow.fromEntrypointArgs([
          'window=main',
          'window=screenTranslate',
        ]),
        AppLockWindow.main,
      );
    });

    test('declare sets the declared window', () {
      AppLockWindow.declare(['window=quickTranslate']);
      expect(AppLockWindow.declared, AppLockWindow.quickTranslate);
      AppLockWindow.declare(const []);
      expect(AppLockWindow.declared, isNull);
    });
  });
}
