import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../translate/helpers/helpers.dart';

/// Why the golden tests are skipped, or null when they run.
///
/// `test/goldens/flutter_test_config.dart` clears it once the real fonts
/// (Roboto and Material Icons from the Flutter SDK) are loaded. Without
/// that config (e.g. bundled by `very_good test`'s optimisation) or
/// without the fonts the screenshots would not match, so they are skipped.
String? goldenSkipReason =
    'Golden tests need the fonts loaded by '
    'test/goldens/flutter_test_config.dart: run them with '
    '`flutter test test/goldens` (or `very_good test --no-optimization`).';

/// A [group] of golden tests, skipped with [goldenSkipReason].
void goldenGroup(String description, void Function() body) =>
    group(description, body, skip: goldenSkipReason);

/// Window sizes of the screenshots (logical pixels at a device pixel ratio
/// of 1, so the files stay small).
enum GoldenDevice {
  /// A phone in portrait.
  phone(Size(411, 891)),

  /// A tablet in landscape (navigation rail, side-by-side panes).
  tablet(Size(1280, 800)),

  /// A two-screen foldable spanned in book posture (Surface Duo), with a
  /// 34 dp hinge in the middle ([duoHinge]).
  duo(Size(1114, 720));

  new(this.size);

  final Size size;
}

/// The hinge of [GoldenDevice.duo].
const DisplayFeature duoHinge = DisplayFeature(
  bounds: Rect.fromLTWH(540, 0, 34, 720),
  type: DisplayFeatureType.hinge,
  state: DisplayFeatureState.unknown,
);

/// The app's themes with the default settings (accent, "Dim" dark look).
final AppThemes goldenThemes = AppThemes.fromSettings(const AppSettings());

/// The app theme of [brightness].
ThemeData goldenTheme(Brightness brightness) =>
    brightness == Brightness.dark ? goldenThemes.dark : goldenThemes.light;

/// Sizes the test window like [device] (device pixel ratio 1).
void useGoldenDevice(
  WidgetTester tester,
  GoldenDevice device, {
  List<DisplayFeature> displayFeatures = const [],
}) {
  tester.view
    ..physicalSize = device.size
    ..devicePixelRatio = 1
    ..displayFeatures = displayFeatures;
  addTearDown(tester.view.reset);
}

/// The file of the golden named [name] (`images/<name>.png`).
String goldenFile(String name) => 'images/$name.png';

/// Compares the whole window with the golden [name].
Future<void> expectScreenGolden(String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile(goldenFile(name)));

/// Pumps [TranslateView] the way the translate widget tests do
/// ([TranslateHarness]'s mocks and providers), with the app's real theme.
Future<void> pumpTranslateGolden(
  WidgetTester tester,
  TranslateHarness harness, {
  required GoldenDevice device,
  Brightness brightness = Brightness.light,
  List<DisplayFeature> displayFeatures = const [],
}) async {
  useGoldenDevice(tester, device, displayFeatures: displayFeatures);
  await tester.pumpWidget(
    InheritedGoRouter(
      goRouter: harness.router,
      child: MultiRepositoryProvider(
        providers: [
          RepositoryProvider<SpeechService>.value(value: harness.speech),
          RepositoryProvider<TranslationRepository>.value(
            value: harness.repository,
          ),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<TranslateCubit>.value(value: harness.translate),
            BlocProvider<SettingsCubit>.value(value: harness.settings),
            BlocProvider<HistoryCubit>.value(value: harness.history),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: goldenTheme(brightness),
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const TranslateView(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
