@Tags(['golden', 'skip_very_good_optimization'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/settings_page.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:translation_repository/translation_repository.dart';

import '../settings/view/helpers.dart';
import 'helpers/golden_helpers.dart';

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
  setUpAll(registerFallbacks);

  setUp(
    () => PackageInfo.setMockInitialValues(
      appName: 'Mozhi',
      packageName: 'app.mozhi',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    ),
  );

  Future<void> pumpSettings(
    WidgetTester tester, {
    required GoldenDevice device,
    Brightness brightness = Brightness.light,
  }) async {
    useGoldenDevice(tester, device);
    await tester.pumpView(
      const SettingsPage(),
      settings: createSettingsCubit(_settings),
      history: createHistoryCubit(),
      router: createRouter(),
      theme: goldenTheme(brightness),
    );
    await tester.pumpAndSettle();
  }

  goldenGroup('Settings screen', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets('top of the page on a phone (${brightness.name})', (
        tester,
      ) async {
        await pumpSettings(
          tester,
          device: GoldenDevice.phone,
          brightness: brightness,
        );
        await expectScreenGolden('settings_phone_${brightness.name}');
      });
    }

    testWidgets('two columns on a tablet (light)', (tester) async {
      await pumpSettings(tester, device: GoldenDevice.tablet);
      await expectScreenGolden('settings_tablet_light');
    });
  });
}
