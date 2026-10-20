@Tags(['golden', 'skip_very_good_optimization'])
library;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../image_translate/helpers/helpers.dart';
import 'helpers/golden_helpers.dart';

/// Pumps [ImageTranslatePage] before a photo is picked, on a phone with
/// the image translation methods of [ImageTranslateHarness] (an AI vision
/// model and Mozhi) and the app's theme.
Future<void> _pumpImageTranslate(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
}) async {
  useGoldenDevice(tester, GoldenDevice.phone);
  final harness = ImageTranslateHarness();
  await tester.pumpWidget(
    InheritedGoRouter(
      goRouter: harness.router,
      child: RepositoryProvider<TranslationRepository>.value(
        value: harness.repository,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<TranslateCubit>.value(value: harness.translate),
            BlocProvider<SettingsCubit>.value(value: harness.settings),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: goldenTheme(brightness),
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ImageTranslatePage(
              picker: harness.picker,
              encoder: harness.encoder,
              recognizer: harness.recognizer,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(registerImageTranslateFallbacks);

  goldenGroup('Image translation screen', () {
    testWidgets('empty on a phone (dark)', (tester) async {
      await _pumpImageTranslate(tester, brightness: Brightness.dark);
      await expectScreenGolden('image_translate_empty_phone_dark');
    });
  });
}
