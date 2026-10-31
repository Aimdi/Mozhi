@Tags(['golden', 'skip_very_good_optimization'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/settings_page.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:translation_repository/translation_repository.dart';

import '../settings/view/helpers.dart';
import '../translate/helpers/helpers.dart';
import 'helpers/golden_helpers.dart';

/// The screenshots of the terminal style (the default): the dark look
/// and, for the empty translate screen, the light "paper" variant.
const _settings = AppSettings(
  instances: [MozhiInstance(url: 'https://mozhi.example.org')],
  providers: [
    AiProviderConfig(
      id: 'p1',
      name: 'Claude',
      provider: LlmProvider.anthropic,
      baseUrl: 'https://api.anthropic.com/v1',
      model: 'claude-opus-5-5',
    ),
  ],
);

void main() {
  setUpAll(() {
    registerTranslateFallbacks();
    registerFallbacks();
  });

  setUp(() {
    // A morning greeting in every screenshot.
    TranslateHero.clock = () => DateTime(2026, 10, 20, 9);
    PackageInfo.setMockInitialValues(
      appName: 'Mozhi',
      packageName: 'app.mozhi',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });
  tearDown(() => TranslateHero.clock = DateTime.now);

  goldenGroup('Translate screen (terminal)', () {
    for (final brightness in [Brightness.dark, Brightness.light]) {
      final look = brightness.name;

      testWidgets('empty on a phone ($look)', (tester) async {
        await pumpTranslateGolden(
          tester,
          TranslateHarness(),
          device: GoldenDevice.phone,
          brightness: brightness,
          theme: goldenTerminalTheme(brightness),
        );
        await expectScreenGolden('translate_empty_terminal_phone_$look');
      });
    }

    testWidgets('with a result on a phone (dark)', (tester) async {
      await pumpTranslateGolden(
        tester,
        TranslateHarness(state: translatedState()),
        device: GoldenDevice.phone,
        brightness: Brightness.dark,
        theme: goldenTerminalTheme(Brightness.dark),
      );
      await expectScreenGolden('translate_result_terminal_phone_dark');
    });
  });

  goldenGroup('Settings screen (terminal)', () {
    Future<void> pumpSettings(WidgetTester tester, Widget page) async {
      useGoldenDevice(tester, GoldenDevice.phone);
      await tester.pumpView(
        page,
        settings: createSettingsCubit(_settings),
        history: createHistoryCubit(),
        router: createRouter(),
        theme: goldenTerminalTheme(Brightness.dark),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('top of the page on a phone (dark)', (tester) async {
      await pumpSettings(tester, const SettingsPage());
      await expectScreenGolden('settings_terminal_phone_dark');
    });

    testWidgets('appearance on a phone (dark)', (tester) async {
      await pumpSettings(
        tester,
        const SettingsCategoryPage(category: SettingsCategory.appearance),
      );
      await expectScreenGolden('settings_appearance_terminal_phone_dark');
    });
  });
}
