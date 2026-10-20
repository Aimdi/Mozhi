@Tags(['golden', 'skip_very_good_optimization'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';

import '../translate/helpers/helpers.dart';
import 'helpers/golden_helpers.dart';

void main() {
  setUpAll(registerTranslateFallbacks);
  // A morning greeting in every screenshot.
  setUp(() => TranslateHero.clock = () => DateTime(2026, 10, 20, 9));
  tearDown(() => TranslateHero.clock = DateTime.now);

  goldenGroup('Translate screen', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final look = brightness.name;

      testWidgets('empty on a phone ($look)', (tester) async {
        await pumpTranslateGolden(
          tester,
          TranslateHarness(),
          device: GoldenDevice.phone,
          brightness: brightness,
        );
        await expectScreenGolden('translate_empty_phone_$look');
      });

      testWidgets('with a result on a phone ($look)', (tester) async {
        await pumpTranslateGolden(
          tester,
          TranslateHarness(state: translatedState()),
          device: GoldenDevice.phone,
          brightness: brightness,
        );
        await expectScreenGolden('translate_result_phone_$look');
      });
    }

    testWidgets('empty with quality modes on a phone (dark)', (tester) async {
      await pumpTranslateGolden(
        tester,
        TranslateHarness(
          state: readyState(engine: google).copyWith(
            qualityMode: QualityMode.fast,
            fastEngine: () => google,
            bestEngine: () => claude,
          ),
        ),
        device: GoldenDevice.phone,
        brightness: Brightness.dark,
      );
      await expectScreenGolden('translate_empty_quality_phone_dark');
    });

    testWidgets('typing on a phone (light)', (tester) async {
      await pumpTranslateGolden(
        tester,
        TranslateHarness(),
        device: GoldenDevice.phone,
      );
      await tester.tap(find.byKey(const Key('translate_input_field')));
      await tester.pumpAndSettle();
      await expectScreenGolden('translate_typing_phone_light');
    });

    testWidgets('empty on a tablet (light)', (tester) async {
      await pumpTranslateGolden(
        tester,
        TranslateHarness(),
        device: GoldenDevice.tablet,
      );
      await expectScreenGolden('translate_empty_tablet_light');
    });

    testWidgets('options for a Mozhi engine on a phone (light)', (
      tester,
    ) async {
      await pumpTranslateGolden(
        tester,
        TranslateHarness(state: translatedState()),
        device: GoldenDevice.phone,
      );
      await tester.tap(find.byKey(const Key('translate_options_button')));
      await tester.pumpAndSettle();
      await expectScreenGolden('translate_options_phone_light');
    });

    testWidgets('with a result on a tablet (light)', (tester) async {
      await pumpTranslateGolden(
        tester,
        TranslateHarness(state: translatedState()),
        device: GoldenDevice.tablet,
      );
      await expectScreenGolden('translate_result_tablet_light');
    });

    testWidgets('split at the hinge of a two-screen device (light)', (
      tester,
    ) async {
      await pumpTranslateGolden(
        tester,
        TranslateHarness(state: translatedState()),
        device: GoldenDevice.duo,
        displayFeatures: [duoHinge],
      );
      await expectScreenGolden('translate_result_hinge_light');
    });
  });
}
