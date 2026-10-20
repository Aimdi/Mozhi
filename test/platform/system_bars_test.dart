import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/system_bars.dart';

void main() {
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
  });

  group(SystemBarsStyle, () {
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
    });

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
      await pump(tester);

      expect(
        calls.where(
          (call) => call.method == 'SystemChrome.setEnabledSystemUIMode',
        ),
        isEmpty,
      );
    });
  });
}
