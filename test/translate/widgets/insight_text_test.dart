import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

const _source = 'The cat sleeps. The black cat eats.';
const _output = 'Le chat dort. Le chat noir mange.';

WordInsight _cat(String sourceText) =>
    WordInsight(sourceText: sourceText, targetText: 'chat');

void main() {
  setUpAll(registerTranslateFallbacks);

  group('InsightText.ranges', () {
    test('places a repeated phrase near its source phrase', () {
      final insight = _cat('black cat');
      expect(InsightText.ranges(_output, [insight], source: _source), [
        (17, 21, insight),
      ]);
      // Without the source text the first occurrence is used.
      expect(InsightText.ranges(_output, [insight]), [(3, 7, insight)]);
    });

    test('moves a phrase another insight took to the nearest free one', () {
      final first = _cat('cat sleeps');
      final second = _cat('cat sleeps');
      final third = _cat('cat sleeps');
      expect(
        InsightText.ranges(_output, [first, second, third], source: _source),
        [(3, 7, first), (17, 21, second)],
      );
    });

    test('prefers whole words', () {
      const insight = WordInsight(sourceText: 'the', targetText: 'die');
      expect(InsightText.ranges('Studie die', [insight]), [(7, 10, insight)]);
    });

    test('skips blank and missing phrases', () {
      expect(
        InsightText.ranges(_output, const [
          WordInsight(sourceText: 'a', targetText: ' '),
          WordInsight(sourceText: 'dog', targetText: 'chien'),
        ]),
        isEmpty,
      );
    });

    test('returns ranges in text order', () {
      final late = _cat('black cat');
      const early = WordInsight(sourceText: 'sleeps', targetText: 'dort');
      expect(InsightText.ranges(_output, [late, early], source: _source), [
        (8, 12, early),
        (17, 21, late),
      ]);
    });
  });

  group('InsightText', () {
    testWidgets('reports the tapped insight without an offset callback', (
      tester,
    ) async {
      const insight = WordInsight(sourceText: 'world', targetText: 'monde');
      final tapped = <WordInsight>[];
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: InsightText(
          text: 'Bonjour le monde',
          insights: const [insight],
          onTap: tapped.add,
        ),
      );
      await tester.tapOnText(find.textRange.ofSubstring('monde'));
      expect(tapped, [insight]);
    });

    testWidgets('sheet variations without a language follow their text', (
      tester,
    ) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: InsightSheet(
          // No phrase to take the direction from either.
          insight: const WordInsight(
            sourceText: 'world',
            targetText: '',
            variations: [Alternative(text: 'תבל')],
          ),
          onVariation: (_) {},
        ),
      );
      final variation = tester.widget<Text>(
        find
            .ancestor(
              of: find.text('תבל', findRichText: true),
              matching: find.byType(Text),
            )
            .first,
      );
      expect(variation.textDirection, TextDirection.rtl);
    });

    testWidgets('reports the offset of the tapped highlight', (tester) async {
      final insight = _cat('black cat');
      final tapped = <(WordInsight, int)>[];
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: InsightText(
          text: _output,
          insights: [insight],
          source: _source,
          onTap: (_) => fail('onTapAt wins'),
          onTapAt: (insight, offset) => tapped.add((insight, offset)),
        ),
      );
      await tester.tapOnText(find.textRange.ofSubstring('chat').at(1));
      expect(tapped, [(insight, 17)]);
    });
  });
}
