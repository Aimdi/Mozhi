import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/dictionary/view/dictionary_page.dart'
    show DictionaryLaunch;
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';
import 'output_stubs.dart';

/// What Google (through Mozhi) returns for "hello" into French.
const _hello = TranslationResult(
  engineId: 'mozhi:google',
  engineName: 'Google',
  text: 'bonjour',
  detectedSource: 'en',
  wordChoices: [
    WordChoice(
      word: 'hello',
      definition: 'used as a greeting',
      examplesSource: ['hello there, Katie!'],
      examplesTarget: ['bonjour, Katie !'],
    ),
    WordChoice(word: 'hello', definition: ' '),
    WordChoice(word: 'hallo', definition: 'an older spelling'),
    WordChoice(word: 'hullo', definition: 'a British spelling'),
  ],
  sourceSynonyms: ['hi', 'Hello', 'hey', ' '],
  targetSynonyms: [
    'salut',
    'Bonjour',
    'coucou',
    'salut',
    'allô',
    'bonsoir',
    '',
  ],
);

TranslateState _state({
  String input = 'hello',
  TranslationResult result = _hello,
  TranslationEngine engine = google,
  TranslationEngine? assistEngine,
}) => translatedState(
  engine: engine,
  assistEngine: assistEngine,
  input: input,
  result: result,
);

Future<TranslateHarness> _pump(
  WidgetTester tester,
  TranslateState state,
) async {
  final harness = TranslateHarness(state: state);
  stubOutputExtras(harness);
  await harness.pump(tester, child: ShortQueryPanel(state: state));
  return harness;
}

void main() {
  setUpAll(registerOutputFallbacks);

  group('ShortQueryPanel', () {
    test('shows for a finished translation of one to three words', () {
      expect(ShortQueryPanel.shows(_state()), isTrue);
      expect(ShortQueryPanel.shows(_state(input: 'good morning all')), isTrue);
      expect(
        ShortQueryPanel.shows(_state(input: 'good morning to all')),
        isFalse,
      );
      expect(
        ShortQueryPanel.shows(
          _state().copyWith(status: TranslateStatus.translating),
        ),
        isFalse,
      );
      expect(
        ShortQueryPanel.shows(
          _state().copyWith(input: 'hullo', resultInput: () => 'hello'),
        ),
        isFalse,
        reason: 'out of date',
      );
      expect(
        ShortQueryPanel.shows(_state().copyWith(compareMode: true)),
        isFalse,
      );
      expect(
        ShortQueryPanel.shows(
          _state(result: _hello.copyWith(isComplete: false)),
        ),
        isFalse,
      );
    });

    test('takes at most four other translations, without repeats', () {
      expect(ShortQueryPanel.otherTranslations(_state()), [
        'salut',
        'coucou',
        'allô',
        'bonsoir',
      ]);
      expect(ShortQueryPanel.definitions(_state()).map((c) => c.word), [
        'hello',
        'hallo',
      ]);
      expect(ShortQueryPanel.synonyms(_state()), ['hi', 'hey']);
    });

    testWidgets('shows what the engine returned, without a request', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final harness = await _pump(tester, _state());
      expect(find.text('Other translations'), findsOneWidget);
      expect(
        tester.getSemantics(find.text('Other translations')),
        matchesSemantics(label: 'Other translations', isHeader: true),
      );
      for (final other in ['salut', 'coucou', 'allô', 'bonsoir']) {
        expect(find.text(other, findRichText: true), findsOneWidget);
      }
      expect(find.text('Definitions'), findsOneWidget);
      expect(find.text('used as a greeting'), findsOneWidget);
      expect(
        find.text('hello there, Katie!', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('bonjour, Katie !', findRichText: true), findsOneWidget);
      // The word is shown when it is not the input itself.
      expect(find.text('hallo', findRichText: true), findsOneWidget);
      expect(find.text('a British spelling'), findsNothing);
      expect(find.text('Synonyms'), findsOneWidget);
      expect(find.text('hi, hey', findRichText: true), findsOneWidget);
      verifyNever(harness.translate.lookUp);
      handle.dispose();
    });

    testWidgets('tapping another translation uses it', (tester) async {
      final harness = await _pump(tester, _state());
      expect(find.byTooltip('Use this translation'), findsNWidgets(4));
      await tester.tap(find.text('coucou', findRichText: true));
      verify(() => harness.translate.useOtherTranslation('coucou')).called(1);
    });

    testWidgets('"Open in Dictionary" opens the word in the Dictionary tab', (
      tester,
    ) async {
      final harness = await _pump(tester, _state());
      await tester.tap(find.text('Open in Dictionary'));
      verify(
        () => harness.router.go(
          '/dictionary?word=hello&from=en&to=fr',
          extra: DictionaryLaunch.lookUp,
        ),
      ).called(1);
      // Looking it up with AI needs an AI engine.
      expect(find.text('More detail'), findsNothing);
    });

    testWidgets('"More detail" asks the AI dictionary', (tester) async {
      final harness = await _pump(tester, _state(assistEngine: claude));
      expect(find.byType(DictionaryCard), findsNothing);
      await tester.tap(find.text('More detail'));
      verify(harness.translate.lookUp).called(1);
    });

    testWidgets('shows the AI entry once asked for, without a second link', (
      tester,
    ) async {
      await _pump(
        tester,
        _state(assistEngine: claude).copyWith(
          dictionaryStatus: ExtraStatus.loading,
          dictionaryQuery: () => 'hello',
        ),
      );
      expect(find.byType(DictionaryCard), findsOneWidget);
      expect(find.text('More detail'), findsNothing);
      expect(find.text('Open in Dictionary'), findsOneWidget);
      expect(find.byKey(const Key('translate_dictionary_open')), findsNothing);
    });

    testWidgets('offers the links when the engine returned nothing more', (
      tester,
    ) async {
      await _pump(
        tester,
        _state(
          engine: claude,
          result: const TranslationResult(
            engineId: 'ai:claude',
            engineName: 'Claude',
            text: 'bonjour',
          ),
        ),
      );
      expect(find.text('Other translations'), findsNothing);
      expect(find.text('Definitions'), findsNothing);
      expect(find.text('Synonyms'), findsNothing);
      expect(find.text('Open in Dictionary'), findsOneWidget);
      expect(find.text('More detail'), findsOneWidget);
    });

    testWidgets('shows nothing for longer inputs', (tester) async {
      await _pump(tester, _state(input: 'hello to you all'));
      expect(find.byKey(const Key('translate_short_query')), findsNothing);
    });

    testWidgets('right to left targets keep their direction', (tester) async {
      const arabic = Language(code: 'ar', name: 'Arabic');
      await _pump(
        tester,
        _state(
          result: const TranslationResult(
            engineId: 'mozhi:google',
            engineName: 'Google',
            text: 'مرحبا',
            targetSynonyms: ['أهلا'],
          ),
        ).copyWith(target: arabic),
      );
      final text = tester.widget<Text>(
        find
            .ancestor(
              of: find.text('أهلا', findRichText: true),
              matching: find.byType(Text),
            )
            .first,
      );
      expect(text.textDirection, TextDirection.rtl);
    });
  });
}
