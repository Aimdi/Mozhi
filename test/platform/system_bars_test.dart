import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/privacy_channel.dart';
import 'package:mozhi/platform/system_bars.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('systemBarsStyle', () {
    test('dark icons over a light theme', () {
      final style = systemBarsStyle(Brightness.light);
      expect(style.statusBarIconBrightness, Brightness.dark);
      expect(style.systemNavigationBarIconBrightness, Brightness.dark);
      expect(style.statusBarBrightness, Brightness.light);
    });

    test('light icons over a dark theme', () {
      final style = systemBarsStyle(Brightness.dark);
      expect(style.statusBarIconBrightness, Brightness.light);
      expect(style.systemNavigationBarIconBrightness, Brightness.light);
      expect(style.statusBarBrightness, Brightness.dark);
    });

    test('transparent bars; contrast left to the system', () {
      for (final brightness in Brightness.values) {
        final style = systemBarsStyle(brightness);
        expect(style.statusBarColor, Colors.transparent);
        expect(style.systemNavigationBarColor, Colors.transparent);
        expect(style.systemNavigationBarDividerColor, Colors.transparent);
        expect(style.systemNavigationBarContrastEnforced, isNull);
        expect(style.systemStatusBarContrastEnforced, isNull);
      }
    });

    test('an opaque navigation bar keeps the icons of the theme', () {
      const surface = Color(0xFF101010);
      final style = systemBarsStyle(
        Brightness.dark,
        navigationBarColor: surface,
      );
      expect(style.systemNavigationBarColor, surface);
      expect(style.systemNavigationBarIconBrightness, Brightness.light);
      // The status bar stays transparent: the app is drawn behind it.
      expect(style.statusBarColor, Colors.transparent);
    });
  });

  group(SystemBarsStyle, () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<MethodCall> calls;
    late List<MethodCall> privacyCalls;

    setUp(() {
      calls = [];
      privacyCalls = [];
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
    });

    /// Android answers [sdk] for its API level.
    void androidVersion(int sdk) {
      messenger.setMockMethodCallHandler(privacyChannel(), (call) async {
        privacyCalls.add(call);
        return call.method == 'sdkInt' ? sdk : null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(privacyChannel(), null),
      );
    }

    Future<void> pump(
      WidgetTester tester, {
      ThemeMode themeMode = ThemeMode.light,
      bool isAndroid = false,
      Widget home = const Scaffold(body: SizedBox.expand()),
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.light),
          darkTheme: ThemeData(brightness: Brightness.dark),
          themeMode: themeMode,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) =>
              SystemBarsStyle(isAndroid: isAndroid, child: child!),
          home: home,
        ),
      );
      // The style is sent after the frame, in a microtask.
      await tester.pump();
    }

    SystemUiOverlayStyle region(WidgetTester tester) => tester
        .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
          find
              .byWidgetPredicate(
                (widget) => widget is AnnotatedRegion<SystemUiOverlayStyle>,
              )
              .first,
        )
        .value;

    testWidgets('follows the light theme', (tester) async {
      await pump(tester);

      expect(region(tester), systemBarsStyle(Brightness.light));
      expect(SystemChrome.latestStyle, systemBarsStyle(Brightness.light));
    });

    testWidgets('follows the dark theme', (tester) async {
      await pump(tester, themeMode: ThemeMode.dark);

      expect(region(tester), systemBarsStyle(Brightness.dark));
      expect(
        SystemChrome.latestStyle?.systemNavigationBarIconBrightness,
        Brightness.light,
      );
    });

    testWidgets('follows a change of theme', (tester) async {
      await pump(tester);
      await pump(tester, themeMode: ThemeMode.dark);
      await tester.pumpAndSettle();

      expect(region(tester), systemBarsStyle(Brightness.dark));
    });

    testWidgets('styles the navigation bar below an app bar', (tester) async {
      await pump(
        tester,
        themeMode: ThemeMode.dark,
        home: Scaffold(
          appBar: AppBar(title: const Text('Mozhi')),
          body: const SizedBox.expand(),
        ),
      );

      final style = SystemChrome.latestStyle;
      // The app bar's own region sets the status bar ...
      expect(style?.statusBarIconBrightness, Brightness.light);
      // ... and this one the navigation bar, which nothing else styles.
      expect(style?.systemNavigationBarColor, Colors.transparent);
      expect(style?.systemNavigationBarIconBrightness, Brightness.light);
    });

    testWidgets('switches Android to edge to edge once', (tester) async {
      await pump(tester, isAndroid: true);
      await pump(tester, isAndroid: true, themeMode: ThemeMode.dark);

      final modes = calls.where(
        (call) => call.method == 'SystemChrome.setEnabledSystemUIMode',
      );
      expect(modes, hasLength(1));
      expect(modes.single.arguments, SystemUiMode.edgeToEdge.toString());
    });

    testWidgets('leaves the system UI mode alone elsewhere', (tester) async {
      androidVersion(28);
      await pump(tester);

      expect(
        calls.where(
          (call) => call.method == 'SystemChrome.setEnabledSystemUIMode',
        ),
        isEmpty,
      );
      expect(privacyCalls, isEmpty);
      expect(region(tester).systemNavigationBarColor, Colors.transparent);
    });

    testWidgets('keeps the navigation bar transparent from Android 10', (
      tester,
    ) async {
      androidVersion(29);
      await pump(tester, isAndroid: true, themeMode: ThemeMode.dark);
      await tester.pump();

      expect(privacyCalls.single.method, 'sdkInt');
      expect(region(tester), systemBarsStyle(Brightness.dark));
    });

    testWidgets('makes the navigation bar opaque below Android 10', (
      tester,
    ) async {
      // A dark app on Android 9: not drawn behind the bar, whose window
      // background follows the (light) system theme.
      androidVersion(28);
      await pump(tester, isAndroid: true, themeMode: ThemeMode.dark);
      await tester.pump();

      final surface = ThemeData(brightness: Brightness.dark)
          .colorScheme
          .surface;
      final style = region(tester);
      expect(style.systemNavigationBarColor, surface);
      expect(style.systemNavigationBarIconBrightness, Brightness.light);
      expect(SystemChrome.latestStyle?.systemNavigationBarColor, surface);

      // It follows a change of theme.
      await pump(tester, isAndroid: true);
      await tester.pumpAndSettle();
      expect(
        region(tester).systemNavigationBarColor,
        ThemeData(brightness: Brightness.light).colorScheme.surface,
      );
      expect(region(tester).systemNavigationBarIconBrightness, Brightness.dark);
      expect(privacyCalls, hasLength(1));
    });

    testWidgets('stays transparent when Android cannot tell its version', (
      tester,
    ) async {
      await pump(tester, isAndroid: true);
      await tester.pump();

      expect(region(tester).systemNavigationBarColor, Colors.transparent);
    });
  });
}
