import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
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
    testWidgets('groups the extras as rows under a small "Learn" heading', (
      tester,
    ) async {
      final harness = TranslateHarness(state: _aiState());
      final semantics = tester.ensureSemantics();
      await harness.pump(tester, child: const ExtrasSection());
      expect(
        find.byKey(const Key('translate_refine_and_learn')),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(find.text('Learn')),
        matchesSemantics(label: 'Learn', isHeader: true),
      );
      final context = tester.element(find.text('Learn'));
      expect(
        tester.widget<Text>(find.text('Learn')).style?.fontSize,
        Theme.of(context).textTheme.titleSmall?.fontSize,
      );
      expect(
        tester.getTopLeft(find.text('Learn')).dy,
        lessThan(tester.getTopLeft(find.text('Alternatives')).dy),
      );
      expect(find.byType(TranslateToolRow), findsNWidgets(2));
      // The refinement chips are with the translation's actions, the AI
      // dictionary with the short-input panel.
      expect(find.byKey(const Key('translate_refinement_chips')), findsNothing);
      expect(find.byType(DictionaryCard), findsNothing);
      semantics.dispose();
    });

    testWidgets('is hidden while the More area is closed', (tester) async {
      final harness = TranslateHarness(state: _aiState());
      await harness.pump(tester, child: const ExtrasSection(expanded: false));
      expect(find.byKey(const Key('translate_refine_and_learn')), findsNothing);
    });

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

    testWidgets('is hidden for a translation of edited text', (tester) async {
      final harness = TranslateHarness(
        state: _aiState().copyWith(
          input: 'Hello there',
          resultInput: () => 'Hello world',
        ),
      );
      await harness.pump(tester, child: const ExtrasSection());
      expect(find.text('Alternatives'), findsNothing);
      expect(find.text('Explain'), findsNothing);
    });

    testWidgets('alternatives for a selected part are replaced on expand', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: _aiState().copyWith(
          alternativesStatus: ExtraStatus.ready,
          alternatives: () => const AlternativeTranslations(
            description: '',
            alternatives: [Alternative(text: "l'univers")],
          ),
          alternativesSpan: () => 'monde',
          alternativesSpanStart: () => 11,
        ),
      );
      await harness.pump(tester, child: const ExtrasSection());
      await tester.tap(find.text('Alternatives'));
      await tester.pumpAndSettle();
      verify(harness.translate.loadAlternatives).called(1);
    });

    testWidgets('retrying alternatives for a selected part keeps the part', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: _aiState().copyWith(
          alternativesStatus: ExtraStatus.failure,
          extraError: () => const LlmApiException('x', statusCode: 429),
          alternativesSpan: () => 'monde',
          alternativesSpanStart: () => 11,
        ),
      );
      await harness.pump(
        tester,
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSpanAlternativesSheet(context),
            child: const Text('Open'),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Alternatives for “monde”'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      verify(
        () => harness.translate.loadAlternatives(span: 'monde', spanStart: 11),
      ).called(1);
    });

    testWidgets('the selection sheet falls back to a plain title', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: _aiState().copyWith(alternativesStatus: ExtraStatus.loading),
      );
      await harness.pump(tester, child: const SpanAlternativesSheet());
      expect(find.text('Alternatives'), findsOneWidget);
      expect(
        find.byKey(const Key('translate_alternatives_progress')),
        findsOneWidget,
      );
    });

    testWidgets('is offered with an AI assist engine', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(assistEngine: claude),
      );
      await harness.pump(tester, child: const ExtrasSection());
      expect(find.text('Alternatives'), findsOneWidget);
    });

    testWidgets('alternatives fold up when the translation changes', (
      tester,
    ) async {
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      final initial = _aiState().copyWith(
        alternativesStatus: ExtraStatus.loading,
      );
      final harness = TranslateHarness(state: initial);
      whenListen(harness.translate, states.stream, initialState: initial);
      await harness.pump(tester, child: const ExtrasSection());
      await tester.tap(find.text('Alternatives'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const Key('translate_alternatives_progress')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TranslateToolRow>(
              find.byKey(const Key('translate_alternatives_button')),
            )
            .expanded,
        isTrue,
      );
      states.add(
        translatedState(
          engine: claude,
          result: const TranslationResult(
            engineId: 'ai:claude',
            engineName: 'Claude',
            text: 'Salut le monde',
          ),
        ).copyWith(alternativesStatus: ExtraStatus.loading),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const Key('translate_alternatives_progress')),
        findsNothing,
      );
    });

    testWidgets('expanding alternatives loads them', (tester) async {
      final harness = TranslateHarness(state: _aiState());
      await harness.pump(tester, child: const ExtrasSection());
      await tester.tap(find.text('Alternatives'));
      await tester.pumpAndSettle();
      verify(harness.translate.loadAlternatives).called(1);
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
      verifyNever(harness.translate.loadAlternatives);
      expect(find.text('A neutral, everyday greeting.'), findsOneWidget);
      expect(find.text('casual'), findsOneWidget);
      await tester.tap(find.text('Salut le monde'));
      verify(() => harness.translate.useAlternative('Salut le monde'))
          .called(1);
    });

    testWidgets('alternatives of a custom target follow their text', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: _aiState().copyWith(
          target: const Language.custom('Pirate'),
          alternativesStatus: ExtraStatus.ready,
          alternatives: () => const AlternativeTranslations(
            description: '',
            alternatives: [Alternative(text: 'مرحبا يا عالم')],
          ),
        ),
      );
      await harness.pump(tester, child: const ExtrasSection());
      await tester.tap(find.text('Alternatives'));
      await tester.pumpAndSettle();
      final text = tester.widget<Text>(
        find
            .ancestor(
              of: find.text('مرحبا يا عالم', findRichText: true),
              matching: find.byType(Text),
            )
            .first,
      );
      expect(text.textDirection, TextDirection.rtl);
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
      verify(harness.translate.loadAlternatives).called(1);
      expect(find.textContaining('Too many requests'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      verify(harness.translate.loadAlternatives).called(1);
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
      verifyNever(harness.translate.explain);
      expect(find.text('Explanation'), findsOneWidget);
      expect(
        find.textContaining('is the standard greeting', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('•'), findsNWidgets(2));
    });

    testWidgets('explain does not restart a running explanation', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: _aiState().copyWith(explainStatus: ExtraStatus.loading),
      );
      await harness.pump(tester, child: const ExtrasSection());
      await tester.tap(find.byKey(const Key('translate_explain_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      verifyNever(harness.translate.explain);
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
      verify(harness.translate.explain).called(1);

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
  });

  group('WordChoicesPanel', () {
    testWidgets('lists Mozhi definitions and synonyms', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(
          input: 'take it to the bank',
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

    testWidgets('is left to the short-input panel for short inputs', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: translatedState(
          input: 'bank',
          result: const TranslationResult(
            engineId: 'mozhi:google',
            engineName: 'Google',
            text: 'banque',
            wordChoices: [
              WordChoice(word: 'banque', definition: 'a financial place'),
            ],
          ),
        ),
      );
      await harness.pump(tester, child: const WordChoicesPanel());
      expect(find.text('Definitions'), findsNothing);
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
