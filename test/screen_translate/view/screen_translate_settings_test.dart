import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/screen_translate/screen_translate.dart';

import '../helpers.dart';

void main() {
  late MockScreenTranslateControls controls;
  late ScreenTranslateSupport support;

  setUp(() {
    controls = MockScreenTranslateControls();
    support = const ScreenTranslateSupport(canAddTile: true);
    when(() => controls.isSupported).thenReturn(true);
    when(controls.status).thenAnswer((_) async => support);
    when(controls.requestOverlayPermission).thenAnswer((_) async {
      support = const ScreenTranslateSupport(canDrawOverlays: true);
      return true;
    });
    when(controls.requestNotificationPermission).thenAnswer((_) async => true);
    when(controls.startBubble).thenAnswer((_) async => true);
    when(controls.stopBubble).thenAnswer((_) async {});
    when(controls.requestAddTile)
        .thenAnswer((_) async => TileRequestResult.added);
  });

  Future<void> pump(WidgetTester tester, {ThemeMode? themeMode}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        themeMode: themeMode ?? ThemeMode.light,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: ScreenTranslateSettingsSection(controls: controls),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  SwitchListTile bubbleSwitch(WidgetTester tester) =>
      tester.widget(find.byKey(const Key('settings_screen_translate_bubble')));

  testWidgets('says it needs the Android app elsewhere', (tester) async {
    when(() => controls.isSupported).thenReturn(false);
    await pump(tester);

    expect(find.text('Android integration'), findsOneWidget);
    expect(
      find.byKey(const Key('settings_screen_translate_unavailable')),
      findsOneWidget,
    );
    expect(find.text('Needs the Android app'), findsOneWidget);
    expect(
      find.byKey(const Key('settings_screen_translate_bubble')),
      findsNothing,
    );
    verifyNever(controls.status);
  });

  testWidgets('explains the feature and shows the bubble state', (
    tester,
  ) async {
    support = const ScreenTranslateSupport(
      bubbleRunning: true,
      canDrawOverlays: true,
    );
    await pump(tester);

    expect(find.byKey(const Key('settings_screen_translate')), findsOneWidget);
    expect(bubbleSwitch(tester).value, isTrue);
    // Android 12 and older: no tile request.
    expect(
      find.byKey(const Key('settings_screen_translate_add_tile')),
      findsNothing,
    );
  });

  testWidgets('turning the bubble on explains the permission first', (
    tester,
  ) async {
    await pump(tester);
    expect(bubbleSwitch(tester).value, isFalse);

    await tester.tap(find.byKey(const Key('settings_screen_translate_bubble')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('settings_screen_translate_overlay_dialog')),
      findsOneWidget,
    );
    expect(find.text('Display over other apps'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('settings_screen_translate_overlay_continue')),
    );
    await tester.pumpAndSettle();
    verifyInOrder([
      controls.requestOverlayPermission,
      controls.requestNotificationPermission,
      controls.startBubble,
    ]);
    expect(bubbleSwitch(tester).value, isTrue);
  });

  testWidgets('cancelling the explanation changes nothing', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('settings_screen_translate_bubble')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    verifyNever(controls.requestOverlayPermission);
    verifyNever(controls.startBubble);
    expect(bubbleSwitch(tester).value, isFalse);
  });

  testWidgets('with overlays allowed the bubble starts at once', (
    tester,
  ) async {
    support = const ScreenTranslateSupport(canDrawOverlays: true);
    await pump(tester);
    await tester.tap(find.byKey(const Key('settings_screen_translate_bubble')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('settings_screen_translate_overlay_dialog')),
      findsNothing,
    );
    verify(controls.startBubble).called(1);
    expect(bubbleSwitch(tester).value, isTrue);

    await tester.tap(find.byKey(const Key('settings_screen_translate_bubble')));
    await tester.pumpAndSettle();
    verify(controls.stopBubble).called(1);
    expect(bubbleSwitch(tester).value, isFalse);
  });

  testWidgets('says when the permission was not given', (tester) async {
    when(controls.requestOverlayPermission).thenAnswer((_) async => false);
    await pump(tester);
    await tester.tap(find.byKey(const Key('settings_screen_translate_bubble')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('settings_screen_translate_overlay_continue')),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        "Without “Display over other apps”, the bubble can't be shown.",
      ),
      findsOneWidget,
    );
    expect(bubbleSwitch(tester).value, isFalse);
  });

  testWidgets('every notice has its message', (tester) async {
    support = const ScreenTranslateSupport(canDrawOverlays: true);
    when(controls.requestNotificationPermission).thenAnswer((_) async => false);
    await pump(tester);
    await tester.tap(find.byKey(const Key('settings_screen_translate_bubble')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Without notifications'), findsOneWidget);

    when(controls.startBubble).thenAnswer((_) async => false);
    await tester.tap(find.byKey(const Key('settings_screen_translate_bubble')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings_screen_translate_bubble')));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't start the bubble."), findsOneWidget);
  });

  testWidgets('offers the Quick Settings tile on Android 13+', (tester) async {
    support = const ScreenTranslateSupport(canAddTile: true);
    await pump(tester);
    expect(
      find.byKey(const Key('settings_screen_translate_add_tile')),
      findsOneWidget,
    );

    for (final (result, message) in [
      (TileRequestResult.added, 'Translate screen was added to Quick Settings'),
      (
        TileRequestResult.alreadyAdded,
        'Translate screen is already in Quick Settings',
      ),
      (
        TileRequestResult.failed,
        "Couldn't add the tile. Edit Quick Settings to add Translate screen.",
      ),
    ]) {
      when(controls.requestAddTile).thenAnswer((_) async => result);
      await tester.tap(
        find.byKey(const Key('settings_screen_translate_add_tile')),
      );
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget, reason: result.name);
    }
  });

  testWidgets('reads the state again when the app comes back', (tester) async {
    support = const ScreenTranslateSupport(
      bubbleRunning: true,
      canDrawOverlays: true,
    );
    await pump(tester);
    expect(bubbleSwitch(tester).value, isTrue);

    // Removed by dragging it onto × while Mozhi was in the background.
    support = const ScreenTranslateSupport(canDrawOverlays: true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(bubbleSwitch(tester).value, isFalse);
  });

  testWidgets('works in the dark theme', (tester) async {
    await pump(tester, themeMode: ThemeMode.dark);
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const Key('settings_screen_translate_bubble')),
      findsOneWidget,
    );
  });

  test('is supported only where the controls are', () {
    expect(ScreenTranslateSettingsSection.supported(controls), isTrue);
    // Tests run on a desktop host.
    expect(ScreenTranslateSettingsSection.supported(), isFalse);
  });
}
