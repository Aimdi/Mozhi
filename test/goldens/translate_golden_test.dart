@Tags(['golden', 'skip_very_good_optimization'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../translate/helpers/helpers.dart';
import 'helpers/golden_helpers.dart';

void main() {
  setUpAll(registerTranslateFallbacks);

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
