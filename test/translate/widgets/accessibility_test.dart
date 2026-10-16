import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

const _arabic = Language(code: 'ar', name: 'Arabic', nativeName: 'العربية');
const _hebrew = Language(code: 'he', name: 'Hebrew', nativeName: 'עברית');

const _done = TranslationResult(
  engineId: 'ai:claude',
  engineName: 'Claude',
  text: 'Bonjour le monde',
);

TranslateState _streaming(String text) => readyState(
  engine: claude,
  input: 'Hello world',
  status: TranslateStatus.translating,
  result: TranslationResult(
    engineId: 'ai:claude',
    engineName: 'Claude',
    text: text,
    isComplete: false,
  ),
);

TranslateState _finished(
  TranslationResult result, {
  Language target = french,
}) => readyState(
  engine: claude,
  input: 'Hello world',
  result: result,
  target: target,
);

/// Lets the test emit states one by one after the first build.
Future<StreamController<TranslateState>> _listen(
  TranslateHarness harness,
  TranslateState initial,
) async {
  final controller = StreamController<TranslateState>();
  addTearDown(controller.close);
  whenListen(harness.translate, controller.stream, initialState: initial);
  return controller;
}

Future<void> _emit(
  WidgetTester tester,
  StreamController<TranslateState> controller,
  TranslateState state,
) async {
  controller.add(state);
  await tester.pump();
}

void main() {
  setUpAll(registerTranslateFallbacks);

  group('A1 language buttons', () {
    testWidgets('keep the button tap action and a descriptive label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const LanguageBar());
      Finder button(String key) => find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(FilledButton),
      );
      expect(
        tester.getSemantics(button('translate_source_button')),
        isSemantics(
          isButton: true,
          hasTapAction: true,
          isEnabled: true,
          isFocusable: true,
          label: 'Source language: Detected: English',
        ),
      );
      final target = tester.getSemantics(button('translate_target_button'));
      expect(
        target,
        isSemantics(
          isButton: true,
          hasTapAction: true,
          isEnabled: true,
          isFocusable: true,
          label: 'Target language: French',
        ),
      );

      // Activating the node (TalkBack double tap, web click) opens the
      // picker.
      tester.semantics.tap(find.semantics.byLabel('Target language: French'));
      await tester.pumpAndSettle();
      expect(find.text('Translate to'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('update when the detection changes', (tester) async {
      final initial = readyState(input: 'Gift');
      final harness = TranslateHarness(state: initial);
      final controller = await _listen(harness, initial);
      await harness.pump(tester, child: const LanguageBar());
      expect(find.text('Detect language'), findsOneWidget);
      await _emit(
        tester,
        controller,
        initial.copyWith(
          result: () => const TranslationResult(
            engineId: 'mozhi:deepl',
            engineName: 'DeepL',
            text: 'Poison',
            detectedSource: 'de',
          ),
          status: TranslateStatus.success,
        ),
      );
      expect(find.text('German'), findsOneWidget);
      expect(find.byIcon(Icons.help_outline), findsOneWidget);
    });

    testWidgets('flag an uncertain detection of a single word', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(
          input: 'Gift',
          result: const TranslationResult(
            engineId: 'mozhi:deepl',
            engineName: 'DeepL',
            text: 'Poison',
            detectedSource: 'de',
          ),
        ),
      );
      await harness.pump(tester, child: const LanguageBar());
      expect(
        find.bySemanticsLabel('Source language: Detected: German?'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.help_outline), findsOneWidget);
    });
  });

  group('B1 output announcements', () {
    testWidgets('announce the finished translation once, never per token', (
      tester,
    ) async {
      final initial = _streaming('Bon');
      final harness = TranslateHarness(state: initial);
      final controller = await _listen(harness, initial);
      await harness.pump(
        tester,
        child: const OutputCard(),
        supportsAnnounce: true,
      );
      await _emit(tester, controller, _streaming('Bonjour'));
      await _emit(tester, controller, _streaming('Bonjour le'));
      expect(tester.takeAnnouncements(), isEmpty);

      final done = _finished(_done);
      await _emit(tester, controller, done);
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement(
          'Bonjour le monde',
          textDirection: TextDirection.ltr,
        ),
      ]);

      // Unrelated rebuilds (extras loading) stay silent.
      await _emit(
        tester,
        controller,
        done.copyWith(insightsStatus: ExtraStatus.loading),
      );
      expect(tester.takeAnnouncements(), isEmpty);
    });

    testWidgets('long translations announce "Translation ready"', (
      tester,
    ) async {
      final initial = _streaming('a');
      final harness = TranslateHarness(state: initial);
      final controller = await _listen(harness, initial);
      await harness.pump(
        tester,
        child: const OutputCard(),
        supportsAnnounce: true,
      );
      await _emit(
        tester,
        controller,
        _finished(
          TranslationResult(
            engineId: 'ai:claude',
            engineName: 'Claude',
            text: 'a' * (maxAnnouncedOutputLength + 1),
          ),
        ),
      );
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('Translation ready'),
      ]);
    });

    testWidgets('right-to-left output is announced right to left', (
      tester,
    ) async {
      final initial = _streaming('مر');
      final harness = TranslateHarness(state: initial);
      final controller = await _listen(harness, initial);
      await harness.pump(
        tester,
        child: const OutputCard(),
        supportsAnnounce: true,
      );
      await _emit(
        tester,
        controller,
        _finished(
          const TranslationResult(
            engineId: 'ai:claude',
            engineName: 'Claude',
            text: 'مرحبا بالعالم',
          ),
          target: _arabic,
        ),
      );
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement(
          'مرحبا بالعالم',
          textDirection: TextDirection.rtl,
        ),
      ]);
    });

    testWidgets('use a live region where announcements are unsupported', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final initial = _streaming('Bon');
      final harness = TranslateHarness(state: initial);
      final controller = await _listen(harness, initial);
      await harness.pump(
        tester,
        child: const OutputCard(),
        supportsAnnounce: false,
      );
      expect(
        find.byKey(const Key('status_announcer_live_region')),
        findsNothing,
      );
      await _emit(tester, controller, _finished(_done));
      expect(tester.takeAnnouncements(), isEmpty);
      expect(
        tester.getSemantics(
          find.byKey(const Key('status_announcer_live_region')),
        ),
        isSemantics(isLiveRegion: true, label: 'Bonjour le monde'),
      );
      handle.dispose();
    });

    testWidgets('an existing translation is not announced on open', (
      tester,
    ) async {
      final harness = TranslateHarness(state: _finished(_done));
      await harness.pump(
        tester,
        child: const OutputCard(),
        supportsAnnounce: true,
      );
      expect(tester.takeAnnouncements(), isEmpty);
    });

    testWidgets('the progress bar and output container are named', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final harness = TranslateHarness(state: _streaming('Bon'));
      await harness.pump(tester, child: const OutputCard());
      final progress = tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('translate_output_progress')),
      );
      expect(progress.semanticsLabel, 'Translating…');
      expect(find.bySemanticsLabel('Translation'), findsOneWidget);
      handle.dispose();
    });
  });

  group('B2 status announcements', () {
    testWidgets('compare announces how many engines succeeded', (tester) async {
      final initial = readyState(input: 'Hello world')
          .copyWith(compareMode: true, comparing: true);
      final harness = TranslateHarness(state: initial);
      final controller = await _listen(harness, initial);
      await harness.pump(
        tester,
        child: const ComparePanel(),
        supportsAnnounce: true,
      );
      const entries = [
        CompareEntry.success(helloResult),
        CompareEntry.failure(
          engineId: 'ai:claude',
          engineName: 'Claude',
          error: LlmApiException('rate', statusCode: 429),
        ),
      ];
      await _emit(
        tester,
        controller,
        initial.copyWith(compareEntries: [entries.first]),
      );
      expect(tester.takeAnnouncements(), isEmpty);
      await _emit(
        tester,
        controller,
        initial.copyWith(compareEntries: entries, comparing: false),
      );
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('1 of 2 engines translated'),
      ]);
    });

    testWidgets('alternatives announce their count', (tester) async {
      final initial = _finished(_done)
          .copyWith(alternativesStatus: ExtraStatus.loading);
      final harness = TranslateHarness(state: initial);
      final controller = await _listen(harness, initial);
      await harness.pump(
        tester,
        child: const ExtrasSection(),
        supportsAnnounce: true,
      );
      await tester.tap(find.text('Alternatives'));
      // The progress bar never settles.
      await tester.pump(const Duration(milliseconds: 500));
      final progress = tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('translate_alternatives_progress')),
      );
      expect(progress.semanticsLabel, 'Loading…');
      await _emit(
        tester,
        controller,
        initial.copyWith(
          alternativesStatus: ExtraStatus.ready,
          alternatives: () => const AlternativeTranslations(
            description: '',
            alternatives: [
              Alternative(text: 'Salut le monde'),
              Alternative(text: 'Coucou le monde'),
            ],
          ),
        ),
      );
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('2 alternatives'),
      ]);
    });

    testWidgets('empty alternatives are announced too', (tester) async {
      final initial = _finished(_done)
          .copyWith(alternativesStatus: ExtraStatus.loading);
      final harness = TranslateHarness(state: initial);
      final controller = await _listen(harness, initial);
      await harness.pump(
        tester,
        child: const ExtrasSection(),
        supportsAnnounce: true,
      );
      await tester.tap(find.text('Alternatives'));
      await tester.pump(const Duration(milliseconds: 500));
      await _emit(
        tester,
        controller,
        initial.copyWith(alternativesStatus: ExtraStatus.ready),
      );
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('No alternatives found.'),
      ]);
    });

    testWidgets('the dictionary announces a loaded entry', (tester) async {
      final initial = readyState(
        engine: claude,
        input: 'hello',
        result: _done,
      ).copyWith(dictionaryStatus: ExtraStatus.loading);
      final harness = TranslateHarness(state: initial);
      final controller = await _listen(harness, initial);
      await harness.pump(
        tester,
        child: const DictionaryCard(),
        supportsAnnounce: true,
      );
      await _emit(
        tester,
        controller,
        initial.copyWith(
          dictionaryStatus: ExtraStatus.ready,
          dictionary: () => const DictionaryEntry(word: 'hello'),
        ),
      );
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('Dictionary entry ready'),
      ]);
    });

    testWidgets('explanations announce when streaming finishes', (
      tester,
    ) async {
      final initial = _finished(_done)
          .copyWith(explainStatus: ExtraStatus.loading, explanation: 'Bonjour');
      final harness = TranslateHarness(state: initial);
      final controller = await _listen(harness, initial);
      await harness.pump(
        tester,
        child: const SizedBox(height: 900, child: ExplainSheet()),
        supportsAnnounce: true,
        size: const Size(800, 1200),
      );
      await _emit(
        tester,
        controller,
        initial.copyWith(explanation: 'Bonjour is a greeting'),
      );
      expect(tester.takeAnnouncements(), isEmpty);
      await _emit(
        tester,
        controller,
        initial.copyWith(
          explainStatus: ExtraStatus.ready,
          explanation: 'Bonjour is a greeting.',
        ),
      );
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('Explanation ready'),
      ]);
    });

    testWidgets('"no results" in the picker is a live region', (tester) async {
      final handle = tester.ensureSemantics();
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      await tester.tap(find.byKey(const Key('translate_target_button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'zzz',
      );
      await tester.pump();
      expect(
        tester.getSemantics(
          find.byKey(const Key('translate_language_no_results')),
        ),
        isSemantics(isLiveRegion: true),
      );
      handle.dispose();
    });
  });

  group('B3 insights', () {
    const insight = WordInsight(
      sourceText: 'world',
      targetText: 'le monde',
      explanation: 'Also "people".',
    );

    testWidgets('are reachable as focusable chips', (tester) async {
      final handle = tester.ensureSemantics();
      final harness = TranslateHarness(
        state: translatedState(assistEngine: claude).copyWith(
          insightsStatus: ExtraStatus.ready,
          insights: const [
            insight,
            WordInsight(sourceText: '', targetText: ' '),
          ],
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      expect(find.byType(InsightChips), findsNothing);
      await tester.tap(find.byKey(const Key('translate_insights_button')));
      await tester.pump();
      expect(find.bySemanticsLabel('Word insights'), findsOneWidget);
      final chip = find.byKey(const ValueKey('translate_insight_chip:0'));
      expect(chip, findsOneWidget);
      // Blank phrases get no chip.
      expect(
        find.byKey(const ValueKey('translate_insight_chip:1')),
        findsNothing,
      );
      expect(
        tester.getSemantics(chip),
        isSemantics(isButton: true, hasTapAction: true, isFocusable: true),
      );
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(find.text('Also "people".'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('underlined spans describe themselves', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: InsightText(
          text: 'Bonjour le monde',
          insights: const [insight],
          onTap: (_) {},
        ),
      );
      final text = tester.widget<Text>(
        find.byKey(const Key('translate_insight_text')),
      );
      final spans = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
      expect(spans.last.semanticsLabel, '“le monde”, word insight');
    });
  });

  group('B8 selected state', () {
    testWidgets('options show check marks, not just a fill', (tester) async {
      final harness = TranslateHarness(state: translatedState(engine: claude));
      await harness.pump(
        tester,
        child: const SizedBox(height: 900, child: TranslationOptionsSheet()),
        size: const Size(800, 1400),
      );
      final style = tester.widget<SegmentedButton<TranslationStyle>>(
        find.byKey(const Key('translate_options_style')),
      );
      expect(style.showSelectedIcon, isTrue);
      final chips = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip));
      expect(chips, isNotEmpty);
      expect(chips.every((chip) => chip.showCheckmark ?? false), isTrue);
    });

    testWidgets('style chips in the picker show a check mark', (tester) async {
      final harness = TranslateHarness(state: readyState(engine: claude));
      await harness.pump(tester, child: const LanguageBar());
      await tester.tap(find.byKey(const Key('translate_target_button')));
      await tester.pumpAndSettle();
      final chips = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip));
      expect(chips, isNotEmpty);
      expect(chips.every((chip) => chip.showCheckmark ?? false), isTrue);
    });
  });

  group('B9 large text', () {
    testWidgets('the engine selector drops its subtitle at 200 %', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const EngineSelectorButton());
      expect(find.text('mozhi.example.org'), findsOneWidget);
      await harness.pump(
        tester,
        child: const EngineSelectorButton(),
        textScale: 2,
      );
      expect(find.text('mozhi.example.org'), findsNothing);
      expect(find.text('DeepL'), findsOneWidget);
    });

    testWidgets('sense numbers and list markers do not clip', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        size: const Size(320, 2400),
        textScale: 2,
        child: Column(
          children: [
            DictionaryEntryView(
              entry: DictionaryEntry(
                word: 'set',
                senses: [
                  for (var i = 0; i < 10; i++)
                    DictionarySense(definition: 'sense $i'),
                ],
              ),
            ),
            const MarkdownLite('10. tenth\n11. eleventh'),
          ],
        ),
      );
      expect(tester.takeException(), isNull);
      final number = tester.getSize(find.text('10.').first);
      expect(number.width, greaterThan(24));
    });
  });

  group('B10 text direction', () {
    testWidgets('output follows the target language', (tester) async {
      final harness = TranslateHarness(
        state: _finished(
          const TranslationResult(
            engineId: 'ai:claude',
            engineName: 'Claude',
            text: 'שלום עולם',
          ),
          target: _hebrew,
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      final text = tester.widget<SelectableText>(
        find.byKey(const Key('translate_output_text')),
      );
      expect(text.textDirection, TextDirection.rtl);
      expect(text.textSpan!.locale, const Locale('he'));
      // Right aligned: the text ends at the card's end edge.
      final rect = tester.getRect(
        find.byKey(const Key('translate_output_text')),
      );
      final card = tester.getRect(
        find.byKey(const Key('translate_output_card')),
      );
      expect(card.right - rect.right, lessThan(40));
    });

    testWidgets('output of a custom target follows its characters', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: _finished(
          const TranslationResult(
            engineId: 'ai:claude',
            engineName: 'Claude',
            text: 'إزيك يا عالم',
          ),
          target: const Language.custom('Egyptian slang'),
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      final text = tester.widget<SelectableText>(
        find.byKey(const Key('translate_output_text')),
      );
      expect(text.textDirection, TextDirection.rtl);
      expect(text.textSpan!.locale, isNull);
    });

    testWidgets('left-to-right output stays left to right', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard());
      final text = tester.widget<SelectableText>(
        find.byKey(const Key('translate_output_text')),
      );
      expect(text.textDirection, TextDirection.ltr);
      expect(text.textSpan!.locale, const Locale('fr'));
    });

    testWidgets('input follows the source or the typed text', (tester) async {
      TextDirection? direction() => tester
          .widget<TextField>(find.byKey(const Key('translate_input_field')))
          .textDirection;

      final harness = TranslateHarness(
        state: readyState(source: _arabic, input: 'مرحبا'),
      );
      await harness.pump(tester, child: const InputCard());
      expect(direction(), TextDirection.rtl);

      harness.setState(readyState(input: 'שלום'));
      await harness.pump(tester, child: const InputCard(key: Key('b')));
      expect(direction(), TextDirection.rtl);

      harness.setState(readyState(input: 'Hello'));
      await harness.pump(tester, child: const InputCard(key: Key('c')));
      expect(direction(), TextDirection.ltr);

      harness.setState(readyState());
      await harness.pump(tester, child: const InputCard(key: Key('d')));
      expect(direction(), isNull);

      harness.setState(readyState(source: german, input: 'Hallo'));
      await harness.pump(tester, child: const InputCard(key: Key('e')));
      expect(direction(), TextDirection.ltr);
    });

    test('inputTextDirection falls back to the detected language', () {
      expect(
        inputTextDirection(
          readyState(
            input: ' ',
            result: const TranslationResult(
              engineId: 'x',
              engineName: 'x',
              text: '',
              detectedSource: 'fa',
            ),
          ),
        ),
        TextDirection.rtl,
      );
    });

    testWidgets('compare results follow the target language', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: CompareEntryCard(
          entry: const CompareEntry.success(
            TranslationResult(
              engineId: 'mozhi:google',
              engineName: 'Google',
              text: 'مرحبا',
              elapsed: Duration(milliseconds: 1240),
            ),
          ),
          target: _arabic,
          onUse: () {},
        ),
      );
      final text = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(text.textDirection, TextDirection.rtl);
      expect(text.textSpan!.locale, const Locale('ar'));
      expect(
        tester.widget<Text>(find.text('1.2 s')).semanticsLabel,
        '1.2 seconds',
      );
    });

    testWidgets('alternatives point to the start edge in RTL layouts', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: _finished(_done).copyWith(
          alternativesStatus: ExtraStatus.ready,
          alternatives: () => const AlternativeTranslations(
            description: '',
            alternatives: [Alternative(text: 'Salut')],
          ),
        ),
      );
      await harness.pump(
        tester,
        child: const ExtrasSection(),
        locale: const Locale('ar'),
      );
      await tester.tap(find.byIcon(Icons.alt_route));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.north_east), findsOneWidget);
      expect(find.byIcon(Icons.north_west), findsNothing);
    });
  });

  group('B11 language of parts', () {
    testWidgets('insight sheets read phrases in their languages', (
      tester,
    ) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: InsightSheet(
          insight: const WordInsight(
            sourceText: 'world',
            targetText: 'العالم',
            variations: [Alternative(text: 'الدنيا')],
          ),
          targetLanguage: _arabic,
          sourceLanguage: english,
          onVariation: (_) {},
        ),
      );
      final phrase = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(phrase.textDirection, TextDirection.rtl);
      expect(phrase.textSpan!.locale, const Locale('ar'));
      final source = tester.widget<Text>(find.text('world'));
      expect(source.textDirection, TextDirection.ltr);
      expect((source.textSpan! as TextSpan).locale, const Locale('en'));
      final variation = tester.widget<Text>(find.text('الدنيا'));
      expect(variation.textDirection, TextDirection.rtl);
    });

    testWidgets('insight sheets without languages follow the text', (
      tester,
    ) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: InsightSheet(
          insight: const WordInsight(sourceText: 'שלום', targetText: 'hello'),
          onVariation: (_) {},
        ),
      );
      final phrase = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(phrase.textDirection, TextDirection.ltr);
      expect(phrase.textSpan!.locale, isNull);
      expect(
        tester.widget<Text>(find.text('שלום')).textDirection,
        TextDirection.rtl,
      );
    });

    testWidgets('dictionary examples carry source and target locales', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state:
            readyState(
              engine: claude,
              source: german,
              input: 'Hallo',
              result: _done,
            ).copyWith(
              dictionaryStatus: ExtraStatus.ready,
              dictionary: () => const DictionaryEntry(
                word: 'Hallo',
                senses: [
                  DictionarySense(
                    definition: 'greeting',
                    translations: ['salut'],
                  ),
                ],
                examples: [
                  DictionaryExample(
                    source: 'Hallo du!',
                    translation: 'Salut !',
                  ),
                ],
              ),
            ),
      );
      await harness.pump(tester, child: const DictionaryCard());
      Locale? locale(String text) =>
          (tester.widget<Text>(find.text(text)).textSpan! as TextSpan).locale;
      expect(locale('Hallo'), const Locale('de'));
      expect(locale('Hallo du!'), const Locale('de'));
      expect(locale('Salut !'), const Locale('fr'));
      expect(locale('salut'), const Locale('fr'));
      expect(find.bySemanticsLabel('Examples'), findsOneWidget);
    });

    testWidgets('a detected source is used for dictionary words', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: translatedState(engine: claude, input: 'hello').copyWith(
          dictionaryStatus: ExtraStatus.ready,
          dictionary: () => const DictionaryEntry(word: 'hello'),
        ),
      );
      await harness.pump(tester, child: const DictionaryCard());
      expect(
        (tester.widget<Text>(find.text('hello')).textSpan! as TextSpan).locale,
        const Locale('en'),
      );
    });

    testWidgets('native names in the picker carry their locale', (
      tester,
    ) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      await tester.tap(find.byKey(const Key('translate_target_button')));
      await tester.pumpAndSettle();
      final native = tester.widget<Text>(find.text('日本語'));
      expect((native.textSpan! as TextSpan).locale, const Locale('ja'));
    });
  });

  group('B12 labels', () {
    testWidgets('the input keeps its name after typing', (tester) async {
      final handle = tester.ensureSemantics();
      final harness = TranslateHarness(state: readyState(input: 'Hello'));
      await harness.pump(tester, child: const InputCard());
      expect(
        tester.getSemantics(find.byKey(const Key('translate_input_field'))),
        isSemantics(isTextField: true, label: 'Text to translate'),
      );
      handle.dispose();
    });

    testWidgets('options fields and groups are named', (tester) async {
      final handle = tester.ensureSemantics();
      final harness = TranslateHarness(state: translatedState(engine: claude));
      await harness.pump(
        tester,
        child: const SizedBox(height: 1600, child: TranslationOptionsSheet()),
        size: const Size(800, 2000),
      );
      expect(find.bySemanticsLabel('Formality'), findsWidgets);
      expect(
        find.bySemanticsLabel(RegExp('^Reading level\nStandard')),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(find.byKey(const Key('translate_options_context'))),
        isSemantics(
          isTextField: true,
          label: 'Context\ne.g. a text message to my landlord',
        ),
      );
      handle.dispose();
    });

    testWidgets('glossary entries read naturally', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(engine: claude).copyWith(
          options: const TranslationOptions(glossary: {'cat': 'chat'}),
        ),
      );
      await harness.pump(
        tester,
        child: const SizedBox(height: 1600, child: TranslationOptionsSheet()),
        size: const Size(800, 2000),
      );
      final entry = tester.widget<Text>(find.text('cat → chat'));
      expect(entry.semanticsLabel, 'cat translates to chat');
    });
  });

  group('B13 picker focus', () {
    testWidgets('the search header is outside the scrolling list', (
      tester,
    ) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      await tester.tap(find.byKey(const Key('translate_target_button')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('translate_language_search')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('translate_language_list')),
          matching: find.byKey(const Key('translate_language_search')),
        ),
        findsNothing,
      );
      final search = tester.getRect(
        find.byKey(const Key('translate_language_search')),
      );
      final list = tester.getRect(
        find.byKey(const Key('translate_language_list')),
      );
      expect(list.top, greaterThanOrEqualTo(search.bottom));
    });
  });

  group('reduced motion', () {
    testWidgets('skeletons stop pulsing', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: const SkeletonCard(),
        disableAnimations: true,
      );
      expect(tester.hasRunningAnimations, isFalse);
      final fades = tester.widgetList<FadeTransition>(
        find.descendant(
          of: find.byType(SkeletonBox),
          matching: find.byType(FadeTransition),
        ),
      );
      expect(fades.every((fade) => fade.opacity.value == 1), isTrue);
    });

    testWidgets('skeletons pulse otherwise', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const SkeletonCard());
      expect(tester.hasRunningAnimations, isTrue);
    });
  });

  group('headings', () {
    testWidgets('section titles are headers', (tester) async {
      final handle = tester.ensureSemantics();
      final harness = TranslateHarness(
        state: readyState(input: 'Hi').copyWith(compareMode: true),
      );
      await harness.pump(tester, child: const ComparePanel());
      expect(
        tester.getSemantics(find.text('Compare engines')),
        isSemantics(isHeader: true),
      );
      handle.dispose();
    });
  });
}
