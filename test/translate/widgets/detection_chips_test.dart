import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';
import 'output_stubs.dart';

const _afrikaans = Language(code: 'af', name: 'Afrikaans');
const _dutch = Language(code: 'nl', name: 'Dutch');

/// "Gift" detected as Dutch, maybe German or Afrikaans (Swahili is not
/// offered by the engine).
TranslateState _uncertain({List<String> alternatives = const ['de', 'af']}) =>
    readyState(
      input: 'Gift is here',
      result: TranslationResult(
        engineId: 'mozhi:deepl',
        engineName: 'DeepL',
        text: 'Le cadeau est là',
        detectedSource: 'nl',
        detectionUncertain: true,
        detectedAlternatives: alternatives,
      ),
    ).copyWith(
      sourceLanguages: const [Language.auto, ...languages, _afrikaans, _dutch],
    );

Finder _alternative(String code) =>
    find.byKey(ValueKey('translate_detected_alternative:$code'));

void main() {
  setUpAll(registerOutputFallbacks);

  group('detectionLooksUncertain', () {
    test('follows the engine and the short-word heuristic', () {
      expect(detectionLooksUncertain(_uncertain()), isTrue);
      expect(detectionLooksUncertain(translatedState()), isFalse);
      expect(
        detectionLooksUncertain(
          readyState(
            input: 'Gift',
            result: const TranslationResult(
              engineId: 'mozhi:deepl',
              engineName: 'DeepL',
              text: 'Poison',
              detectedSource: 'de',
            ),
          ),
        ),
        isTrue,
      );
    });
  });

  group('DetectedLanguageChips', () {
    testWidgets('a certain detection is a plain chip', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(
        tester,
        child: DetectedLanguageChips(state: translatedState()),
      );
      expect(find.text('Detected: English'), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome_outlined), findsOneWidget);
      expect(
        find.byKey(const Key('translate_detected_alternatives')),
        findsNothing,
      );
      expect(find.byTooltip('Change source language'), findsOneWidget);
    });

    testWidgets('an uncertain detection offers the other languages', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final state = _uncertain();
      final harness = TranslateHarness(state: state);
      await harness.pump(tester, child: DetectedLanguageChips(state: state));
      expect(find.text('Detected: Dutch?'), findsOneWidget);
      expect(find.byIcon(Icons.help_outline), findsOneWidget);
      expect(find.text('German'), findsOneWidget);
      expect(find.text('Afrikaans'), findsOneWidget);
      expect(find.bySemanticsLabel('Other possible languages'), findsOneWidget);
      expect(find.byTooltip('Translate from German instead'), findsOneWidget);
      final german = tester.widget<Text>(
        find.descendant(of: _alternative('de'), matching: find.byType(Text)),
      );
      expect((german.textSpan! as TextSpan).locale, const Locale('de'));

      await tester.tap(_alternative('af'));
      verify(() => harness.translate.useDetectedAlternative('af')).called(1);
      handle.dispose();
    });

    testWidgets('languages the engine does not list are left out', (
      tester,
    ) async {
      final state = _uncertain(alternatives: const ['sw', 'de']);
      final harness = TranslateHarness(state: state);
      await harness.pump(tester, child: DetectedLanguageChips(state: state));
      expect(_alternative('sw'), findsNothing);
      expect(_alternative('de'), findsOneWidget);
    });

    testWidgets('without alternatives only the question mark is shown', (
      tester,
    ) async {
      final state = readyState(
        input: 'Gift',
        result: const TranslationResult(
          engineId: 'mozhi:deepl',
          engineName: 'DeepL',
          text: 'Poison',
          detectedSource: 'de',
        ),
      );
      final harness = TranslateHarness(state: state);
      await harness.pump(tester, child: DetectedLanguageChips(state: state));
      expect(find.text('Detected: German?'), findsOneWidget);
      expect(
        find.byTooltip(
          'Short texts are hard to detect. Choose the source language if '
          'this is wrong.',
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('translate_detected_alternatives')),
        findsNothing,
      );
    });

    testWidgets('shows nothing for an explicit source', (tester) async {
      final state = _uncertain().copyWith(source: english);
      final harness = TranslateHarness(state: state);
      await harness.pump(tester, child: DetectedLanguageChips(state: state));
      expect(find.byKey(const Key('translate_detected_chip')), findsNothing);
      expect(_alternative('de'), findsNothing);
    });

    testWidgets('shows nothing without a detection', (tester) async {
      final state = readyState(input: 'Hello');
      final harness = TranslateHarness(state: state);
      await harness.pump(tester, child: DetectedLanguageChips(state: state));
      expect(find.byKey(const Key('translate_detected_chip')), findsNothing);
    });

    testWidgets('the detected chip opens the source language picker', (
      tester,
    ) async {
      final state = translatedState();
      final harness = TranslateHarness(state: state);
      await harness.pump(tester, child: DetectedLanguageChips(state: state));
      await tester.tap(find.byKey(const Key('translate_detected_chip')));
      await tester.pumpAndSettle();
      expect(find.byType(LanguagePickerSheet), findsOneWidget);
    });

    testWidgets('are part of the output footer', (tester) async {
      final harness = TranslateHarness(state: _uncertain());
      await harness.pump(tester, child: const OutputCard());
      expect(find.text('Detected: Dutch?'), findsOneWidget);
      expect(_alternative('de'), findsOneWidget);
      expect(find.text('DeepL'), findsOneWidget);
    });

    testWidgets('fit narrow screens with large text', (tester) async {
      final harness = TranslateHarness(state: _uncertain());
      await harness.pump(
        tester,
        child: const OutputCard(),
        size: const Size(320, 900),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(_alternative('af'), findsOneWidget);
    });
  });
}
