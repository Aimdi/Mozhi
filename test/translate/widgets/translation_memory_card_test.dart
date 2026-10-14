import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/data/translation_memory.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';
import 'output_stubs.dart';

const _arabic = Language(code: 'ar', name: 'Arabic', nativeName: 'العربية');

HistoryEntry _entry({
  String text = 'Hello world',
  String translation = 'Bonjour tout le monde',
  Language target = french,
}) => HistoryEntry(
  id: '1',
  text: text,
  translation: translation,
  source: Language.auto,
  target: target,
  engineId: google.id,
  engineName: google.name,
  createdAt: DateTime(2026, 3, 5),
);

MemoryMatch _exact({Language target = french, String? translation}) =>
    MemoryMatch(
      entry: _entry(
        target: target,
        translation: translation ?? 'Bonjour tout le monde',
      ),
      kind: MemoryMatchKind.exact,
      similarity: 1,
    );

const _earlier = 'Please send me the quarterly report by Monday';
const _input = 'Please send me the quarterly report by Friday';

MemoryMatch _similar() => MemoryMatch(
  entry: _entry(text: _earlier, translation: 'Envoyez le rapport lundi'),
  kind: MemoryMatchKind.similar,
  similarity: TranslationMemory.similarity(_earlier, _input),
  diff: TranslationMemory.diff(_earlier, _input),
);

TranslateHarness _harness(TranslateState state) {
  final harness = TranslateHarness(state: state);
  stubOutputExtras(harness);
  return harness;
}

TranslateState _state(MemoryMatch? match, {Language target = french}) =>
    readyState(
      input: match?.isExact ?? true ? 'Hello world' : _input,
      target: target,
    ).copyWith(memoryMatch: () => match);

Finder _card() => find.byKey(const Key('translate_memory_card'));

void main() {
  setUpAll(registerOutputFallbacks);

  group('TranslationMemoryCard', () {
    testWidgets('shows nothing without a match', (tester) async {
      await _harness(_state(null))
          .pump(tester, child: const TranslationMemoryCard());
      expect(_card(), findsNothing);
    });

    testWidgets('shows nothing when the output shows it already', (
      tester,
    ) async {
      final state = _state(_exact()).copyWith(
        result: () => const TranslationResult(
          engineId: 'mozhi:google',
          engineName: 'Google',
          text: 'Bonjour tout le monde',
        ),
        resultInput: () => 'Hello world',
      );
      await _harness(state).pump(tester, child: const TranslationMemoryCard());
      expect(_card(), findsNothing);
    });

    testWidgets('shows an exact match', (tester) async {
      await _harness(_state(_exact()))
          .pump(tester, child: const TranslationMemoryCard());
      expect(find.text('From your history'), findsOneWidget);
      expect(find.text('Bonjour tout le monde'), findsOneWidget);
      expect(find.textContaining('Google · '), findsOneWidget);
      expect(find.byKey(const Key('translate_memory_diff')), findsNothing);
    });

    testWidgets('Use shows it as the output', (tester) async {
      final harness = _harness(_state(_exact()));
      await harness.pump(tester, child: const TranslationMemoryCard());
      final handle = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel('Use the translation from your history'),
        findsOneWidget,
      );
      handle.dispose();
      await tester.tap(find.byKey(const Key('translate_memory_use')));
      verify(harness.translate.useMemoryMatch).called(1);
    });

    testWidgets('the close button hides it', (tester) async {
      final harness = _harness(_state(_exact()));
      await harness.pump(tester, child: const TranslationMemoryCard());
      await tester.tap(
        find.byTooltip('Hide the translation from your history'),
      );
      verify(harness.translate.dismissMemoryMatch).called(1);
    });

    testWidgets('copy copies the earlier translation', (tester) async {
      final clipboard = FakeClipboard(tester);
      await _harness(_state(_exact()))
          .pump(tester, child: const TranslationMemoryCard());
      await tester.tap(
        find.byTooltip('Copy the translation from your history'),
      );
      await tester.pump();
      expect(clipboard.copied, 'Bonjour tout le monde');
      expect(find.text('Copied to clipboard'), findsOneWidget);
    });

    testWidgets('shows similar text with the differences marked', (
      tester,
    ) async {
      final match = _similar();
      await _harness(_state(match))
          .pump(tester, child: const TranslationMemoryCard());
      expect(
        find.text('Similar text in your history · ${match.percent}% match'),
        findsOneWidget,
      );
      expect(find.text('Envoyez le rapport lundi'), findsOneWidget);
      expect(
        find.textContaining('Struck-through words were only in the earlier'),
        findsOneWidget,
      );
      final diff = tester.widget<RichText>(
        find.descendant(
          of: find.byKey(const Key('translate_memory_diff')),
          matching: find.byType(RichText),
        ),
      );
      final spans = (diff.text as TextSpan).children!.first as TextSpan;
      final children = spans.children!.cast<TextSpan>();
      expect(children.map((span) => span.text), [
        'Please send me the quarterly report by',
        ' Monday',
        ' Friday',
      ]);
      expect(children[0].style, isNull);
      expect(children[1].style?.decoration, TextDecoration.lineThrough);
      expect(children[2].style?.decoration, TextDecoration.underline);
    });

    testWidgets('screen readers hear the earlier text plainly', (tester) async {
      final handle = tester.ensureSemantics();
      await _harness(_state(_similar()))
          .pump(tester, child: const TranslationMemoryCard());
      expect(find.bySemanticsLabel('Earlier text: $_earlier'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Similar text in your history'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('writes an RTL translation right to left', (tester) async {
      await _harness(
        _state(
          _exact(target: _arabic, translation: 'مرحبا بالعالم'),
          target: _arabic,
        ),
      ).pump(tester, child: const TranslationMemoryCard());
      final text = tester.widget<Text>(
        find.byKey(const Key('translate_memory_translation')),
      );
      expect(text.textDirection, TextDirection.rtl);
    });

    testWidgets('a custom target takes the direction of the text', (
      tester,
    ) async {
      const custom = Language.custom('Arabic slang');
      await _harness(
        _state(
          _exact(target: custom, translation: 'مرحبا بالعالم'),
          target: custom,
        ),
      ).pump(tester, child: const TranslationMemoryCard());
      final text = tester.widget<Text>(
        find.byKey(const Key('translate_memory_translation')),
      );
      expect(text.textDirection, TextDirection.rtl);
    });

    testWidgets('lays out in an RTL UI at 200% text', (tester) async {
      await _harness(_state(_similar())).pump(
        tester,
        child: const TranslationMemoryCard(),
        size: const Size(320, 900),
        textScale: 2,
        locale: const Locale('ar'),
      );
      expect(tester.takeException(), isNull);
      expect(_card(), findsOneWidget);
    });

    testWidgets('meets the accessibility guidelines', (tester) async {
      final handle = tester.ensureSemantics();
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        await _harness(
          _state(_similar()),
        ).pump(tester, child: const TranslationMemoryCard(), themeMode: mode);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
      }
      handle.dispose();
    });
  });

  group('MemoryResultBadge', () {
    testWidgets('marks an output from history', (tester) async {
      final state = translatedState().copyWith(resultFromMemory: true);
      await _harness(state).pump(tester, child: const OutputCard());
      expect(find.byKey(const Key('translate_memory_badge')), findsOneWidget);
      expect(
        find.byTooltip('Taken from your history: not translated again'),
        findsOneWidget,
      );
    });

    testWidgets('is not shown for an engine translation', (tester) async {
      await _harness(translatedState()).pump(tester, child: const OutputCard());
      expect(find.byKey(const Key('translate_memory_badge')), findsNothing);
    });
  });

  testWidgets('the translate screen shows the card above the output', (
    tester,
  ) async {
    await _harness(_state(_exact())).pump(tester);
    expect(_card(), findsOneWidget);
    expect(
      tester.getTopLeft(_card()).dy,
      lessThan(tester.getTopLeft(find.byType(OutputCard)).dy),
    );
  });
}
