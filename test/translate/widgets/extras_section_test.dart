import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

const _aiResult = TranslationResult(
  engineId: 'ai:claude',
  engineName: 'Claude',
  text: 'Bonjour le monde',
);

TranslateState _aiState({String input = 'Hello world'}) =>
    translatedState(engine: claude, input: input, result: _aiResult);

void main() {
  setUpAll(registerTranslateFallbacks);

  group('ExtrasSection', () {
    testWidgets('is hidden without an AI engine', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const ExtrasSection());
      expect(find.text('Alternatives'), findsNothing);
      expect(find.text('Explain'), findsNothing);
    });

    testWidgets('is hidden while translating', (tester) async {
      final harness = TranslateHarness(
        state: _aiState().copyWith(status: TranslateStatus.translating),
      );
      await harness.pump(tester, child: const ExtrasSection());
      expect(find.text('Alternatives'), findsNothing);
    });

    testWidgets('refinement chips apply suggestions', (tester) async {
      final harness = TranslateHarness(state: _aiState());
      await harness.pump(tester, child: const ExtrasSection());
      expect(
        find.byKey(const Key('translate_refinement_chips')),
        findsOneWidget,
      );
      await tester.tap(find.text('More formal'));
      verify(
        () => harness.translate.applySuggestion(
          RefinementSuggestion.defaults.first,
        ),
      ).called(1);
    });

    testWidgets('"More suggestions" loads suggestions', (tester) async {
      final harness = TranslateHarness(state: _aiState());
      await harness.pump(tester, child: const ExtrasSection());
      await tester.ensureVisible(
        find.byKey(const Key('translate_more_suggestions')),
      );
      await tester.tap(find.byKey(const Key('translate_more_suggestions')));
      verify(() => harness.translate.loadSuggestions()).called(1);
    });

    testWidgets('"More suggestions" disappears once loaded', (tester) async {
      final harness = TranslateHarness(
        state: _aiState().copyWith(
          suggestionsStatus: ExtraStatus.ready,
          suggestions: const [
            RefinementSuggestion(
              label: 'Warmer',
              instruction: 'Make it warmer.',
              description: 'Friendlier tone',
            ),
          ],
        ),
      );
      await harness.pump(tester, child: const ExtrasSection());
      expect(find.text('Warmer'), findsOneWidget);
      expect(find.byKey(const Key('translate_more_suggestions')), findsNothing);
    });

    testWidgets('chips are only shown for AI engines', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(assistEngine: claude),
      );
      await harness.pump(tester, child: const ExtrasSection());
      expect(find.byKey(const Key('translate_refinement_chips')), findsNothing);
      expect(find.text('Alternatives'), findsOneWidget);
    });

    testWidgets('expanding alternatives loads them', (tester) async {
      final harness = TranslateHarness(state: _aiState());
      await harness.pump(tester, child: const ExtrasSection());
      await tester.tap(find.text('Alternatives'));
      await tester.pumpAndSettle();
      verify(() => harness.translate.loadAlternatives()).called(1);
    });

    testWidgets('alternatives can be used', (tester) async {
      final harness = TranslateHarness(
        state: _aiState().copyWith(
          alternativesStatus: ExtraStatus.ready,
          alternatives: () => const AlternativeTranslations(
            description: 'A neutral, everyday greeting.',
            alternatives: [
              Alternative(text: 'Salut le monde', explanation: 'casual'),
            ],
          ),
        ),
      );
      await harness.pump(tester, child: const ExtrasSection());
      await tester.tap(find.text('Alternatives'));
      await tester.pumpAndSettle();
      verifyNever(() => harness.translate.loadAlternatives());
      expect(find.text('A neutral, everyday greeting.'), findsOneWidget);
      expect(find.text('casual'), findsOneWidget);
      await tester.tap(find.text('Salut le monde'));
      verify(() => harness.translate.useAlternative('Salut le monde'))
          .called(1);
    });

    testWidgets('alternatives show loading and errors', (tester) async {
      final harness = TranslateHarness(
        state: _aiState().copyWith(
          alternativesStatus: ExtraStatus.failure,
          extraError: () => const LlmApiException('x', statusCode: 429),
        ),
      );
      await harness.pump(tester, child: const ExtrasSection());
      await tester.tap(find.text('Alternatives'));
      await tester.pumpAndSettle();
      verify(() => harness.translate.loadAlternatives()).called(1);
      expect(find.textContaining('Too many requests'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      verify(() => harness.translate.loadAlternatives()).called(1);
    });

    testWidgets('explain opens a streaming sheet', (tester) async {
      final harness = TranslateHarness(
        state: _aiState().copyWith(
          explainStatus: ExtraStatus.ready,
          explanation:
              '**Bonjour** is the standard greeting.\n\n'
              '- *le monde* means "the world"\n'
              '- formal and informal',
        ),
      );
      await harness.pump(tester, child: const ExtrasSection());
      await tester.tap(find.byKey(const Key('translate_explain_button')));
      await tester.pumpAndSettle();
      verifyNever(() => harness.translate.explain());
      expect(find.text('Explanation'), findsOneWidget);
      expect(
        find.textContaining('is the standard greeting', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('•'), findsNWidgets(2));
    });

    testWidgets('explain does not restart a running explanation', (tester) async {
      final harness = TranslateHarness(
        state: _aiState().copyWith(explainStatus: ExtraStatus.loading),
      );
      await harness.pump(tester, child: const ExtrasSection());
      await tester.tap(find.byKey(const Key('translate_explain_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      verifyNever(() => harness.translate.explain());
      expect(
        find.byKey(const Key('translate_explain_progress')),
        findsOneWidget,
      );
    });

    testWidgets('explain requests an explanation and follow-ups', (
      tester,
    ) async {
      final harness = TranslateHarness(state: _aiState());
      await harness.pump(tester, child: const ExtrasSection());
      await tester.tap(find.byKey(const Key('translate_explain_button')));
      await tester.pumpAndSettle();
      verify(() => harness.translate.explain()).called(1);

      await tester.enterText(
        find.byKey(const Key('translate_explain_question')),
        'Why not "salut"?',
      );
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      verify(() => harness.translate.explain(question: 'Why not "salut"?'))
          .called(1);
      expect(find.text('You asked: Why not "salut"?'), findsOneWidget);
    });

    group('dictionary', () {
      testWidgets('is offered for short inputs', (tester) async {
        final harness = TranslateHarness(state: _aiState(input: 'hello'));
        await harness.pump(tester, child: const ExtrasSection());
        expect(find.text('Dictionary'), findsOneWidget);
        expect(find.text('AI-generated'), findsOneWidget);
        await tester.tap(find.text('Look up “hello”'));
        verify(() => harness.translate.lookUp()).called(1);
      });

      testWidgets('is not offered for long inputs', (tester) async {
        final harness = TranslateHarness(
          state: _aiState(input: 'this is a longer sentence'),
        );
        await harness.pump(tester, child: const ExtrasSection());
        expect(find.text('Dictionary'), findsNothing);
      });

      testWidgets('renders an entry', (tester) async {
        final harness = TranslateHarness(
          state: _aiState(input: 'hello').copyWith(
            dictionaryStatus: ExtraStatus.ready,
            dictionary: () => const DictionaryEntry(
              word: 'hello',
              pronunciation: 'həˈloʊ',
              partsOfSpeech: ['interjection', 'noun'],
              senses: [
                DictionarySense(
                  definition: 'used as a greeting',
                  partOfSpeech: 'interjection',
                  translations: ['bonjour', 'salut'],
                  usage: 'informal',
                ),
              ],
              examples: [
                DictionaryExample(
                  source: 'Hello, how are you?',
                  translation: 'Bonjour, comment ça va ?',
                ),
              ],
              synonyms: ['hi', 'hey'],
              etymology: 'From "hallo".',
              notes: 'Very common.',
            ),
          ),
        );
        await harness.pump(tester, child: const ExtrasSection());
        expect(find.text('/həˈloʊ/'), findsOneWidget);
        expect(find.text('interjection · noun'), findsOneWidget);
        expect(find.text('bonjour, salut'), findsOneWidget);
        expect(find.text('Hello, how are you?'), findsOneWidget);
        expect(find.text('hi, hey'), findsOneWidget);
        expect(find.text('From "hallo".'), findsOneWidget);
      });

      testWidgets('shows errors with retry', (tester) async {
        final harness = TranslateHarness(
          state: _aiState(input: 'hello').copyWith(
            dictionaryStatus: ExtraStatus.failure,
            extraError: () => const LlmRefusalException('no'),
          ),
        );
        await harness.pump(tester, child: const ExtrasSection());
        expect(
          find.text('The model declined to translate this text.'),
          findsOneWidget,
        );
        await tester.tap(find.text('Retry'));
        verify(() => harness.translate.lookUp()).called(1);
      });
    });
  });

  group('WordChoicesPanel', () {
    testWidgets('lists Mozhi definitions and synonyms', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(
          input: 'bank',
          result: const TranslationResult(
            engineId: 'mozhi:google',
            engineName: 'Google',
            text: 'banque',
            wordChoices: [
              WordChoice(
                word: 'banque',
                definition: 'a financial institution',
                examplesSource: ['the bank is closed'],
                examplesTarget: ['la banque est fermée'],
              ),
            ],
            targetSynonyms: ['établissement'],
          ),
        ),
      );
      await harness.pump(tester, child: const WordChoicesPanel());
      expect(find.text('Definitions'), findsOneWidget);
      await tester.tap(find.text('Definitions'));
      await tester.pumpAndSettle();
      expect(find.text('a financial institution'), findsOneWidget);
      expect(
        find.textContaining('la banque est fermée', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('établissement'), findsOneWidget);
    });

    testWidgets('is hidden without word choices', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const WordChoicesPanel());
      expect(find.text('Definitions'), findsNothing);
    });
  });

  group('MarkdownLite', () {
    testWidgets('renders headings, lists and inline styles', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: const MarkdownLite(
          '# Title\nFirst line\ncontinues here.\n\n1. one\n2. `code`\n'
          '* **bold** item',
        ),
      );
      expect(find.text('Title', findRichText: true), findsOneWidget);
      expect(
        find.text('First line continues here.', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('1.'), findsOneWidget);
      expect(find.text('2.'), findsOneWidget);
      expect(find.text('•'), findsOneWidget);
      final spans = MarkdownLite.inlineSpans('a **b** *c* `d` **e', null);
      expect(spans.map((s) => (s as TextSpan).text), [
        'a ',
        'b',
        ' ',
        'c',
        ' ',
        'd',
        ' **e',
      ]);
    });
  });
}
