import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/dictionary/view/dictionary_page.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';
import 'output_stubs.dart';

const _result = TranslationResult(
  engineId: 'ai:claude',
  engineName: 'Claude',
  text: 'bonjour',
  detectedSource: 'en',
);

const _entry = DictionaryEntry(
  word: 'hello',
  senses: [DictionarySense(definition: 'a greeting')],
  relatedWords: ['hi', ' ', 'hello there'],
  didYouMean: 'hallo',
);

TranslateState _state({
  ExtraStatus status = ExtraStatus.idle,
  DictionaryEntry? entry,
  String? query,
  Language source = Language.auto,
  Language target = french,
}) =>
    readyState(
      engine: claude,
      input: 'helo',
      result: _result,
      source: source,
      target: target,
    ).copyWith(
      dictionaryStatus: status,
      dictionary: () => entry,
      dictionaryQuery: () => query,
    );

Finder _verbosity(DictionaryVerbosity verbosity) =>
    find.byKey(ValueKey('translate_dictionary_verbosity:${verbosity.name}'));

void main() {
  setUpAll(registerOutputFallbacks);

  group('DictionaryCard', () {
    group('detail level', () {
      testWidgets('offers concise, standard and detailed', (tester) async {
        final handle = tester.ensureSemantics();
        final harness = TranslateHarness(state: _state());
        stubOutputExtras(harness);
        await harness.pump(tester, child: const DictionaryCard());
        expect(find.text('Concise'), findsOneWidget);
        expect(find.text('Standard'), findsOneWidget);
        expect(find.text('Detailed'), findsOneWidget);
        expect(find.bySemanticsLabel('Detail level'), findsOneWidget);
        final standard = tester.widget<ChoiceChip>(
          _verbosity(DictionaryVerbosity.standard),
        );
        expect(standard.selected, isTrue);
        expect(
          tester
              .widget<ChoiceChip>(_verbosity(DictionaryVerbosity.concise))
              .selected,
          isFalse,
        );
        expect(
          tester.getSemantics(_verbosity(DictionaryVerbosity.standard)),
          isSemantics(isSelected: true, isButton: true, hasTapAction: true),
        );
        handle.dispose();
      });

      testWidgets('choosing a level sets it', (tester) async {
        final harness = TranslateHarness(state: _state());
        stubOutputExtras(harness);
        await harness.pump(tester, child: const DictionaryCard());
        await tester.tap(_verbosity(DictionaryVerbosity.comprehensive));
        verify(
          () => harness.translate.setDictionaryVerbosity(
            DictionaryVerbosity.comprehensive,
          ),
        ).called(1);
        // The selected level again does nothing.
        await tester.tap(_verbosity(DictionaryVerbosity.standard));
        verifyNever(
          () => harness.translate.setDictionaryVerbosity(
            DictionaryVerbosity.standard,
          ),
        );
      });

      testWidgets('shows the level of the state', (tester) async {
        final state = _state().copyWith(
          dictionaryVerbosity: DictionaryVerbosity.concise,
        );
        final harness = TranslateHarness(state: state);
        stubOutputExtras(harness);
        await harness.pump(tester, child: const DictionaryCard());
        expect(
          tester
              .widget<ChoiceChip>(_verbosity(DictionaryVerbosity.concise))
              .selected,
          isTrue,
        );
      });

      testWidgets('can be disabled', (tester) async {
        final harness = TranslateHarness();
        await harness.pump(
          tester,
          child: const DictionaryVerbosityChips(
            value: DictionaryVerbosity.standard,
          ),
        );
        expect(
          tester
              .widget<ChoiceChip>(_verbosity(DictionaryVerbosity.concise))
              .onSelected,
          isNull,
        );
      });

      testWidgets('rebuilds when the level changes', (tester) async {
        final initial = _state();
        final harness = TranslateHarness(state: initial);
        stubOutputExtras(harness);
        final controller = StreamController<TranslateState>();
        addTearDown(controller.close);
        whenListen(harness.translate, controller.stream, initialState: initial);
        await harness.pump(tester, child: const DictionaryCard());
        controller.add(
          initial.copyWith(dictionaryVerbosity: DictionaryVerbosity.concise),
        );
        await tester.pump();
        expect(
          tester
              .widget<ChoiceChip>(_verbosity(DictionaryVerbosity.concise))
              .selected,
          isTrue,
        );
      });
    });

    group('entry', () {
      testWidgets('related words look that word up', (tester) async {
        final harness = TranslateHarness(
          state: _state(status: ExtraStatus.ready, entry: _entry),
        );
        stubOutputExtras(harness);
        await harness.pump(tester, child: const DictionaryCard());
        expect(find.text('Related words'), findsOneWidget);
        // Blank words are skipped.
        expect(
          find.descendant(
            of: find.byKey(const Key('translate_dictionary_related')),
            matching: find.byType(ActionChip),
          ),
          findsNWidgets(2),
        );
        expect(find.byTooltip('Look up “hello there”'), findsOneWidget);
        await tester.ensureVisible(
          find.byKey(const ValueKey('translate_dictionary_related:hi')),
        );
        await tester.tap(
          find.byKey(const ValueKey('translate_dictionary_related:hi')),
        );
        verify(() => harness.translate.lookUpWord('hi')).called(1);
      });

      testWidgets('"Did you mean …?" looks the suggestion up', (tester) async {
        final harness = TranslateHarness(
          state: _state(
            status: ExtraStatus.ready,
            entry: _entry,
            query: 'helo',
          ),
        );
        stubOutputExtras(harness);
        await harness.pump(tester, child: const DictionaryCard());
        expect(find.text('Did you mean “hallo”?'), findsOneWidget);
        await tester.tap(
          find.byKey(const Key('translate_dictionary_did_you_mean')),
        );
        verify(() => harness.translate.lookUpWord('hallo')).called(1);
      });

      testWidgets('"Did you mean …?" is not offered for the shown word', (
        tester,
      ) async {
        final harness = TranslateHarness(
          state: _state(
            status: ExtraStatus.ready,
            entry: _entry,
            query: 'Hallo',
          ),
        );
        stubOutputExtras(harness);
        await harness.pump(tester, child: const DictionaryCard());
        expect(
          find.byKey(const Key('translate_dictionary_did_you_mean')),
          findsNothing,
        );
      });

      testWidgets('without a callback words are plain text', (tester) async {
        final harness = TranslateHarness();
        await harness.pump(
          tester,
          child: const DictionaryEntryView(entry: _entry),
        );
        expect(find.text('hi, hello there'), findsOneWidget);
        expect(find.byType(ActionChip), findsNothing);
        final didYouMean = tester.widget<Text>(
          find.byKey(const Key('translate_dictionary_did_you_mean')),
        );
        expect(didYouMean.textSpan!.toPlainText(), 'Did you mean “hallo”?');
      });

      testWidgets('"Did you mean …?" tags only the word with its language', (
        tester,
      ) async {
        final harness = TranslateHarness();
        await harness.pump(
          tester,
          child: DictionaryEntryView(
            entry: const DictionaryEntry(word: 'ねこ', didYouMean: '猫'),
            sourceLanguage: japanese,
            onWordTap: (_) {},
          ),
        );
        final label = tester.widget<Text>(
          find.descendant(
            of: find.byKey(const Key('translate_dictionary_did_you_mean')),
            matching: find.byType(Text),
          ),
        );
        final span = label.textSpan! as TextSpan;
        expect(span.locale, isNull);
        final parts = span.children!.cast<TextSpan>();
        expect(parts.map((part) => part.text), ['Did you mean “', '猫', '”?']);
        expect(parts.map((part) => part.locale), [
          null,
          const Locale('ja'),
          null,
        ]);
      });

      testWidgets('an entry without extras shows neither', (tester) async {
        final harness = TranslateHarness();
        await harness.pump(
          tester,
          child: const DictionaryEntryView(
            entry: DictionaryEntry(word: 'hello', didYouMean: ' '),
          ),
        );
        expect(find.text('Related words'), findsNothing);
        expect(
          find.byKey(const Key('translate_dictionary_did_you_mean')),
          findsNothing,
        );
      });
    });

    group('Open dictionary', () {
      testWidgets('opens the input in the detected language', (tester) async {
        final harness = TranslateHarness(state: _state());
        stubOutputExtras(harness);
        await harness.pump(tester, child: const DictionaryCard());
        await tester.tap(find.byKey(const Key('translate_dictionary_open')));
        verify(
          () => harness.router.push<Object?>(
            '/dictionary?word=helo&from=en&to=fr',
            extra: DictionaryLaunch.lookUp,
          ),
        ).called(1);
      });

      testWidgets('opens the shown word in the chosen languages', (
        tester,
      ) async {
        final harness = TranslateHarness(
          state: _state(
            status: ExtraStatus.ready,
            entry: _entry,
            query: 'hello there',
            source: english,
            target: german,
          ),
        );
        stubOutputExtras(harness);
        await harness.pump(tester, child: const DictionaryCard());
        await tester.ensureVisible(
          find.byKey(const Key('translate_dictionary_open')),
        );
        await tester.tap(find.byKey(const Key('translate_dictionary_open')));
        verify(
          () => harness.router.push<Object?>(
            '/dictionary?word=hello+there&from=en&to=de',
            extra: DictionaryLaunch.lookUp,
          ),
        ).called(1);
      });

      testWidgets('leaves out custom and undetected languages', (tester) async {
        final state =
            readyState(
              engine: claude,
              input: 'hello',
              target: const Language.custom('Pirate'),
            ).copyWith(
              result: () => const TranslationResult(
                engineId: 'ai:claude',
                engineName: 'Claude',
                text: 'ahoy',
              ),
              status: TranslateStatus.success,
            );
        final harness = TranslateHarness(state: state);
        stubOutputExtras(harness);
        await harness.pump(tester, child: const DictionaryCard());
        await tester.tap(find.byKey(const Key('translate_dictionary_open')));
        verify(
          () => harness.router.push<Object?>(
            '/dictionary?word=hello',
            extra: DictionaryLaunch.lookUp,
          ),
        ).called(1);
      });

      testWidgets('leaves out a custom source', (tester) async {
        final harness = TranslateHarness(
          state: _state(source: const Language.custom('Klingon')),
        );
        stubOutputExtras(harness);
        await harness.pump(tester, child: const DictionaryCard());
        await tester.tap(find.byKey(const Key('translate_dictionary_open')));
        verify(
          () => harness.router.push<Object?>(
            '/dictionary?word=helo&to=fr',
            extra: DictionaryLaunch.lookUp,
          ),
        ).called(1);
      });

      testWidgets('is not offered without a word', (tester) async {
        final harness = TranslateHarness(state: _state().copyWith(input: '  '));
        stubOutputExtras(harness);
        await harness.pump(tester, child: const DictionaryCard());
        expect(
          find.byKey(const Key('translate_dictionary_open')),
          findsNothing,
        );
      });
    });

    testWidgets('works in dark mode, right to left and with large text', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: _state(status: ExtraStatus.ready, entry: _entry, query: 'helo'),
      );
      stubOutputExtras(harness);
      await harness.pump(
        tester,
        child: const DictionaryCard(),
        themeMode: ThemeMode.dark,
        locale: const Locale('ar'),
        size: const Size(320, 1400),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(_verbosity(DictionaryVerbosity.comprehensive), findsOneWidget);
    });
  });
}
