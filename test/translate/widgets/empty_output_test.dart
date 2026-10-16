import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

const _enFr = LanguagePair(source: english, target: french);
const _enDe = LanguagePair(source: english, target: german);
const _deEn = LanguagePair(source: german, target: english);
const _frDe = LanguagePair(source: french, target: german);
const _pirate = LanguagePair(
  source: english,
  target: Language.custom('Pirate speak'),
);

Finder _pair(int index) => find.byKey(ValueKey('translate_empty_pair:$index'));

void main() {
  setUpAll(registerTranslateFallbacks);

  group('EmptyOutput', () {
    testWidgets('says where the translation goes and how to start', (
      tester,
    ) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const OutputCard());
      expect(find.byKey(const Key('translate_empty_output')), findsOneWidget);
      expect(find.text('Your translation appears here'), findsOneWidget);
      expect(
        find.text('Type or paste text, speak, or translate a photo.'),
        findsOneWidget,
      );
      expect(find.text('Recent pairs'), findsNothing);
      expect(find.text('Press ? for keyboard shortcuts'), findsNothing);
    });

    testWidgets('offers recent pairs other than the current one', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: readyState(source: english),
        settings: const AppSettings(
          recentPairs: [_enFr, _enDe, _deEn, _frDe, _pirate],
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      expect(find.text('Recent pairs'), findsOneWidget);
      // English → French is in use; at most three others.
      expect(_pair(0), findsOneWidget);
      expect(_pair(2), findsOneWidget);
      expect(_pair(3), findsNothing);
      expect(
        find.descendant(of: _pair(0), matching: find.textContaining('German')),
        findsOneWidget,
      );

      await tester.tap(_pair(1));
      verify(() => harness.translate.applyLanguagePair(_deEn)).called(1);
    });

    testWidgets('disables pairs with a custom language the engine cannot '
        'take', (tester) async {
      final harness = TranslateHarness(
        settings: const AppSettings(recentPairs: [_pirate]),
      );
      await harness.pump(tester, child: const OutputCard());
      final chip = tester.widget<ActionChip>(_pair(0));
      expect(chip.onPressed, isNull);
    });

    testWidgets('points to the keyboard shortcuts on large screens', (
      tester,
    ) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: const OutputCard(),
        size: const Size(1280, 800),
      );
      expect(find.text('Press ? for keyboard shortcuts'), findsOneWidget);
    });
  });
}
