import 'dart:async';

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/speech/widgets/spoken_range_builder.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';
import 'output_stubs.dart';

final Finder _text = find.byKey(const Key('translate_output_text'));
final Finder _card = find.byKey(const Key('word_lookup_sheet'));

/// Where to tap to put the caret before [offset] of the translation.
Offset _at(WidgetTester tester, int offset) {
  final editable = tester.state<EditableTextState>(
    find.descendant(of: _text, matching: find.byType(EditableText)),
  );
  final render = editable.renderEditable;
  final caret = render.getLocalRectForCaret(TextPosition(offset: offset));
  return render.localToGlobal(caret.center + const Offset(2, 0));
}

/// Taps the translation before [offset] and waits for the word card.
Future<void> _tapWord(WidgetTester tester, int offset) async {
  await tester.tapAt(_at(tester, offset));
  await tester.pump(kDoubleTapTimeout);
  await tester.pumpAndSettle();
}

/// The spans of the translation that have text.
List<TextSpan> _spans(WidgetTester tester) {
  final text = tester.widget<SelectableText>(_text);
  final spans = <TextSpan>[];
  text.textSpan!.visitChildren((span) {
    if (span is TextSpan && span.text != null) spans.add(span);
    return true;
  });
  return spans;
}

/// The text of the spans drawn as the word being read.
List<String?> _spoken(WidgetTester tester) {
  final scheme = Theme.of(tester.element(_text)).colorScheme;
  final style = spokenWordStyle(scheme);
  return [
    for (final span in _spans(tester))
      if (span.style?.backgroundColor == style.backgroundColor) span.text,
  ];
}

void main() {
  setUpAll(registerOutputFallbacks);

  group('tap a word', () {
    testWidgets('opens its word card', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard());
      // "Bonjour le monde": the caret before the "o" of "monde".
      await _tapWord(tester, 12);
      expect(_card, findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('word_lookup_headword')))
            .textSpan
            ?.toPlainText(),
        'monde',
      );
      expect(
        find.text('No offline dictionary for French is downloaded.'),
        findsOneWidget,
      );
      // The Dictionary tab's AI model, only on request.
      expect(find.text('Look up with Claude'), findsOneWidget);
      verifyNever(
        () => harness.repository.lookUp(
          any(),
          any(),
          source: any(named: 'source'),
          target: any(named: 'target'),
          context: any(named: 'context'),
          uiLanguage: any(named: 'uiLanguage'),
          verbosity: any(named: 'verbosity'),
        ),
      );
    });

    testWidgets('looks it up with the sentence, into the source language', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      when(
        () => harness.repository.lookUp(
          any(),
          any(),
          source: any(named: 'source'),
          target: any(named: 'target'),
          context: any(named: 'context'),
          uiLanguage: any(named: 'uiLanguage'),
          verbosity: any(named: 'verbosity'),
        ),
      ).thenAnswer((_) async => const DictionaryEntry(word: 'monde'));
      await harness.pump(tester, child: const OutputCard());
      await _tapWord(tester, 12);
      await tester.tap(find.text('Look up with Claude'));
      await tester.pumpAndSettle();
      final captured = verify(
        () => harness.repository.lookUp(
          claude,
          'monde',
          source: french,
          target: captureAny(named: 'target'),
          context: 'Bonjour le monde',
          verbosity: DictionaryVerbosity.concise,
        ),
      ).captured;
      expect((captured.single as Language).code, 'en');
    });

    testWidgets('a chosen source language is the other side', (tester) async {
      final harness = TranslateHarness(
        state: readyState(
          source: german,
          input: 'Hallo Welt',
          result: helloResult,
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      expect(wordLookupInto(harness.translate.state), german);
      expect(
        wordLookupInto(readyState(source: const Language.custom('Pirate'))),
        isNull,
      );
      expect(
        wordLookupInto(
          readyState(
            result: const TranslationResult(
              engineId: 'mozhi:deepl',
              engineName: 'DeepL',
              text: 'Bonjour',
            ),
          ),
        ),
        isNull,
      );
    });

    testWidgets('nothing on the space between two words', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(
          result: const TranslationResult(
            engineId: 'mozhi:deepl',
            engineName: 'DeepL',
            text: 'Bonjour   monde',
            detectedSource: 'en',
          ),
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      await _tapWord(tester, 8);
      expect(_card, findsNothing);
    });

    testWidgets('does nothing with the setting off', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(),
        settings: const AppSettings(tapToLookUp: false),
      );
      await harness.pump(tester, child: const OutputCard());
      await _tapWord(tester, 12);
      expect(_card, findsNothing);
      expect(tester.widget<SelectableText>(_text).onTap, isNull);
    });

    testWidgets('does nothing while matching phrases are on', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(assistEngine: claude),
      );
      stubOutputExtras(harness);
      await harness.pump(tester, child: const OutputCard(), more: true);
      await tester.tap(find.byKey(const Key('translate_alignment_button')));
      await tester.pump();
      await _tapWord(tester, 12);
      expect(_card, findsNothing);
    });

    testWidgets('does nothing while insights are on', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(assistEngine: claude),
      );
      stubOutputExtras(harness);
      await harness.pump(tester, child: const OutputCard(), more: true);
      await tester.tap(find.byKey(const Key('translate_insights_button')));
      await tester.pump();
      await _tapWord(tester, 12);
      expect(_card, findsNothing);
    });

    testWidgets('does nothing while the translation streams in', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: readyState(
          status: TranslateStatus.translating,
          result: const TranslationResult(
            engineId: 'mozhi:deepl',
            engineName: 'DeepL',
            text: 'Bonjour le monde',
            isComplete: false,
          ),
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      await _tapWord(tester, 12);
      expect(_card, findsNothing);
    });

    testWidgets('a long press still selects the word for copying', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard());
      await tester.longPressAt(_at(tester, 12));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(_card, findsNothing);
      expect(find.text('Copy'), findsOneWidget);
      final editable = tester.state<EditableTextState>(
        find.descendant(of: _text, matching: find.byType(EditableText)),
      );
      expect(
        editable.textEditingValue.selection,
        const TextSelection(baseOffset: 11, extentOffset: 16),
      );
    });

    testWidgets('a double tap still selects a word', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard());
      await tester.tapAt(_at(tester, 12));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(_at(tester, 12));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(_card, findsNothing);
      final editable = tester.state<EditableTextState>(
        find.descendant(of: _text, matching: find.byType(EditableText)),
      );
      expect(editable.textEditingValue.selection.isCollapsed, isFalse);
    });

    testWidgets('a tap that clears a selection opens nothing', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard());
      await tester.longPressAt(_at(tester, 12));
      await tester.pumpAndSettle();
      await tester.tapAt(_at(tester, 2));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(_card, findsNothing);
      await _tapWord(tester, 2);
      expect(_card, findsOneWidget);
    });
  });

  group('"Look up" in the selection toolbar', () {
    Future<void> select(WidgetTester tester, int start, int end) async {
      final editable = tester.state<EditableTextState>(
        find.descendant(of: _text, matching: find.byType(EditableText)),
      );
      editable.userUpdateTextEditingValue(
        editable.textEditingValue.copyWith(
          selection: TextSelection(baseOffset: start, extentOffset: end),
        ),
        SelectionChangedCause.keyboard,
      );
      await tester.pump();
      editable.showToolbar();
      await tester.pumpAndSettle();
    }

    testWidgets('opens the card of the selected words', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard());
      await select(tester, 7, 16);
      await tester.tap(find.text('Look up'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('word_lookup_headword')))
            .textSpan
            ?.toPlainText(),
        'le monde',
      );
    });

    testWidgets('also with the tap turned off', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(),
        settings: const AppSettings(tapToLookUp: false),
      );
      await harness.pump(tester, child: const OutputCard());
      await select(tester, 11, 16);
      expect(find.text('Look up'), findsOneWidget);
    });

    testWidgets('not for more than three words', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(
          result: const TranslationResult(
            engineId: 'mozhi:deepl',
            engineName: 'DeepL',
            text: 'un deux trois quatre',
          ),
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      await select(tester, 0, 20);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Look up'), findsNothing);
      await select(tester, 0, 13);
      expect(find.text('Look up'), findsOneWidget);
    });
  });

  group('the word being read', () {
    late StreamController<String?> speaking;
    late StreamController<SpokenRange?> ranges;

    TranslateHarness reading({AppSettings settings = const AppSettings()}) {
      final harness = TranslateHarness(
        state: translatedState(),
        settings: settings,
      );
      speaking = StreamController<String?>.broadcast();
      ranges = StreamController<SpokenRange?>.broadcast();
      addTearDown(speaking.close);
      addTearDown(ranges.close);
      when(() => harness.speech.speaking).thenAnswer((_) => speaking.stream);
      when(() => harness.speech.spokenRanges).thenAnswer((_) => ranges.stream);
      return harness;
    }

    testWidgets('is highlighted while Listen reads the translation', (
      tester,
    ) async {
      final harness = reading();
      await harness.pump(tester, child: const OutputCard());
      expect(_spoken(tester), isEmpty);
      when(() => harness.speech.current).thenReturn(translateOutputSpeechId);
      speaking.add(translateOutputSpeechId);
      await tester.pump();
      ranges.add(const SpokenRange(8, 10));
      await tester.pump();
      expect(_spoken(tester), ['le']);
      ranges.add(const SpokenRange(11, 16));
      await tester.pump();
      expect(_spoken(tester), ['monde']);
      // Done.
      when(() => harness.speech.current).thenReturn(null);
      ranges.add(null);
      speaking.add(null);
      await tester.pump();
      expect(_spoken(tester), isEmpty);
    });

    testWidgets('a clip already playing is followed from the start', (
      tester,
    ) async {
      final harness = reading();
      when(() => harness.speech.current).thenReturn(translateOutputSpeechId);
      await harness.pump(tester, child: const OutputCard());
      ranges.add(const SpokenRange(0, 7));
      await tester.pump();
      expect(_spoken(tester), ['Bonjour']);
    });

    testWidgets('another clip is not highlighted here', (tester) async {
      final harness = reading();
      await harness.pump(tester, child: const OutputCard());
      when(() => harness.speech.current).thenReturn('source');
      speaking.add('source');
      await tester.pump();
      ranges.add(const SpokenRange(8, 10));
      await tester.pump();
      expect(_spoken(tester), isEmpty);
    });

    testWidgets('a range that does not fit the text is ignored', (
      tester,
    ) async {
      final harness = reading();
      when(() => harness.speech.current).thenReturn(translateOutputSpeechId);
      await harness.pump(tester, child: const OutputCard());
      ranges.add(const SpokenRange(10, 99));
      await tester.pump();
      expect(_spoken(tester), isEmpty);
    });

    testWidgets('not with the setting off', (tester) async {
      final harness = reading(
        settings: const AppSettings(highlightSpokenWord: false),
      );
      when(() => harness.speech.current).thenReturn(translateOutputSpeechId);
      await harness.pump(tester, child: const OutputCard());
      ranges.add(const SpokenRange(8, 10));
      await tester.pump();
      expect(_spoken(tester), isEmpty);
    });

    testWidgets('holds still while text is selected', (tester) async {
      final harness = reading();
      when(() => harness.speech.current).thenReturn(translateOutputSpeechId);
      await harness.pump(tester, child: const OutputCard());
      ranges.add(const SpokenRange(8, 10));
      await tester.pump();
      final editable = tester.state<EditableTextState>(
        find.descendant(of: _text, matching: find.byType(EditableText)),
      );
      editable.userUpdateTextEditingValue(
        editable.textEditingValue.copyWith(
          selection: const TextSelection(baseOffset: 0, extentOffset: 7),
        ),
        SelectionChangedCause.longPress,
      );
      await tester.pump();
      ranges.add(const SpokenRange(11, 16));
      await tester.pump();
      expect(_spoken(tester), ['le']);
      final kept = tester.state<EditableTextState>(
        find.descendant(of: _text, matching: find.byType(EditableText)),
      );
      expect(
        kept.textEditingValue.selection,
        const TextSelection(baseOffset: 0, extentOffset: 7),
      );
    });

    testWidgets('shows over the unsure sentences of the on-device engine', (
      tester,
    ) async {
      final harness = reading();
      final state = translatedState();
      harness.setState(
        state.copyWith(
          uncertainSentences: const [
            AlignedSpan(
              sourceStart: 0,
              sourceEnd: 5,
              targetStart: 0,
              targetEnd: 7,
            ),
          ],
          uncertainResult: () => state.result,
        ),
      );
      when(() => harness.speech.current).thenReturn(translateOutputSpeechId);
      await harness.pump(tester, child: const OutputCard());
      ranges.add(const SpokenRange(0, 7));
      await tester.pump();
      final spoken = _spans(tester).firstWhere((s) => s.text == 'Bonjour');
      expect(spoken.style?.decorationStyle, TextDecorationStyle.dotted);
      expect(
        spoken.style?.backgroundColor,
        spokenWordStyle(Theme.of(tester.element(_text)).colorScheme)
            .backgroundColor,
      );
    });

    testWidgets('a service without progress shows nothing', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      when(() => harness.speech.current).thenReturn(translateOutputSpeechId);
      // spokenRanges is not stubbed: the mock has no stream.
      await harness.pump(tester, child: const OutputCard());
      await tester.pump();
      expect(_spoken(tester), isEmpty);
      expect(tester.takeException(), isNull);
    });
  });
}
