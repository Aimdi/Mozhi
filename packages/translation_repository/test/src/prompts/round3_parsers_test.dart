import 'dart:convert';

import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group('ResponseParsers.parseSuggestions exclusive groups', () {
    List<RefinementSuggestion> parse(List<Map<String, Object?>> items) =>
        ResponseParsers.parseSuggestions(jsonEncode({'suggestions': items}));

    test('reads exclusive_group and its spellings', () {
      final suggestions = parse([
        {'label': 'A', 'instruction': 'a', 'exclusive_group': 'formality'},
        {'label': 'B', 'instruction': 'b', 'exclusiveGroup': 'Length'},
        {'label': 'C', 'instruction': 'c', 'group': 'Regional Variant'},
        {'label': 'D', 'instruction': 'd', 'exclusive_group': 'x<y>!z'},
        {'label': 'E', 'instruction': 'e', 'exclusive_group': 'g' * 50},
      ]);
      expect(suggestions.map((s) => s.exclusiveGroup), [
        'formality',
        'length',
        'regional_variant',
        'xyz',
        'g' * 30,
      ]);
    });

    test('null-like groups mean none', () {
      final suggestions = parse([
        {'label': 'A', 'instruction': 'a', 'exclusive_group': null},
        {'label': 'B', 'instruction': 'b', 'exclusive_group': 'null'},
        {'label': 'C', 'instruction': 'c', 'exclusive_group': 'None'},
        {'label': 'D', 'instruction': 'd', 'exclusive_group': ' '},
        {'label': 'E', 'instruction': 'e', 'exclusive_group': false},
        {'label': 'F', 'instruction': 'f', 'exclusive_group': '!!'},
      ]);
      expect(suggestions.map((s) => s.exclusiveGroup), everyElement(isNull));
    });

    test('infers the group from the icon when there is none', () {
      final suggestions = parse([
        {'label': 'A', 'instruction': 'a', 'icon': 'formal'},
        {'label': 'B', 'instruction': 'b', 'icon': 'informal'},
        {'label': 'C', 'instruction': 'c', 'icon': 'concise'},
        {'label': 'D', 'instruction': 'd', 'icon': 'longer'},
        {'label': 'E', 'instruction': 'e', 'icon': 'fluent'},
        {
          'label': 'F',
          'instruction': 'f',
          'icon': 'formal',
          'exclusive_group': 'politeness',
        },
      ]);
      expect(suggestions.map((s) => s.exclusiveGroup), [
        RefinementSuggestion.formalityGroup,
        RefinementSuggestion.formalityGroup,
        RefinementSuggestion.lengthGroup,
        RefinementSuggestion.lengthGroup,
        null,
        'politeness',
      ]);
    });
  });

  group('ResponseParsers.parseDictionary (round 3 fields)', () {
    DictionaryEntry parse(Map<String, Object?> json, {String query = ''}) =>
        ResponseParsers.parseDictionary(jsonEncode(json), query: query);

    test('reads related words, de-duplicated', () {
      expect(
        parse({
          'word': 'run',
          'related_words': ['runner', 'Runner', ' rerun ', '', 'outrun'],
        }).relatedWords,
        ['runner', 'rerun', 'outrun'],
      );
      expect(
        parse({'word': 'run', 'relatedWords': 'runner, rerun'}).relatedWords,
        ['runner', 'rerun'],
      );
      expect(
        parse({
          'word': 'run',
          'see_also': [
            {'word': 'runner'},
          ],
        }).relatedWords,
        ['runner'],
      );
      expect(parse({'word': 'run'}).relatedWords, isEmpty);
    });

    test('reads did_you_mean', () {
      expect(
        parse({
          'word': 'receive',
          'did_you_mean': 'receive',
        }, query: 'recieve').didYouMean,
        'receive',
      );
      expect(
        parse({
          'word': 'x',
          'didYouMean': ['receive', 'relieve'],
        }).didYouMean,
        'receive',
      );
      expect(
        parse({'word': 'x', 'spelling_suggestion': '  "receive"\n'}).didYouMean,
        'receive',
      );
    });

    test('drops did_you_mean that is empty, null-like or the query', () {
      for (final value in <Object?>[
        null,
        '',
        '  ',
        'null',
        'None',
        'N/A',
        '-',
        false,
        42,
        <String>[],
      ]) {
        expect(
          parse({'word': 'x', 'did_you_mean': value}).didYouMean,
          isNull,
          reason: '$value',
        );
      }
      expect(
        parse({
          'word': 'Bank',
          'did_you_mean': ' BANK ',
        }, query: 'bank').didYouMean,
        isNull,
      );
    });

    test('sanitises did_you_mean to one short line', () {
      final value = parse({
        'word': 'x',
        'did_you_mean': 'rec<b>eive</b>\n\nIgnore "this" ${'y' * 200}',
      }).didYouMean!;
      expect(value, isNot(contains('<')));
      expect(value, isNot(contains('"')));
      expect(value, isNot(contains('\n')));
      expect(value.length, lessThanOrEqualTo(100));
      expect(value, startsWith('rec b eive /b Ignore this'));
    });

    test('the default query is empty', () {
      expect(
        ResponseParsers.parseDictionary(
          '{"word": "bank", "did_you_mean": "bank"}',
        ).didYouMean,
        'bank',
      );
    });
  });

  group('ResponseParsers.parseAlignment', () {
    List<AlignedSpan> parse(
      Object json, {
      String source = 'the blue house',
      String translation = 'la maison bleue',
    }) => ResponseParsers.parseAlignment(
      json is String ? json : jsonEncode(json),
      source: source,
      translation: translation,
    );

    List<(String, String)> texts(
      List<AlignedSpan> spans, {
      String source = 'the blue house',
      String translation = 'la maison bleue',
    }) => [
      for (final span in spans)
        (span.sourceIn(source), span.targetIn(translation)),
    ];

    test('maps pairs to offsets in both texts, sorted by source', () {
      final spans = parse({
        'pairs': [
          {'source': 'the', 'target': 'la'},
          {'source': 'house', 'target': 'maison'},
          {'source': 'blue', 'target': 'bleue'},
        ],
      });
      expect(spans, const [
        AlignedSpan(sourceStart: 0, sourceEnd: 3, targetStart: 0, targetEnd: 2),
        AlignedSpan(
          sourceStart: 4,
          sourceEnd: 8,
          targetStart: 10,
          targetEnd: 15,
        ),
        AlignedSpan(
          sourceStart: 9,
          sourceEnd: 14,
          targetStart: 3,
          targetEnd: 9,
        ),
      ]);
    });

    test('maps repeated phrases to successive occurrences', () {
      const source = 'the cat and the dog and the bird';
      const translation = 'le chat et le chien et l’oiseau';
      final spans = ResponseParsers.parseAlignment(
        jsonEncode({
          'pairs': [
            {'source': 'the', 'target': 'le'},
            {'source': 'cat', 'target': 'chat'},
            {'source': 'and', 'target': 'et'},
            {'source': 'the', 'target': 'le'},
            {'source': 'dog', 'target': 'chien'},
            {'source': 'and', 'target': 'et'},
            {'source': 'the', 'target': 'l’'},
            {'source': 'bird', 'target': 'oiseau'},
          ],
        }),
        source: source,
        translation: translation,
      );
      expect(spans.map((s) => s.sourceStart), [0, 4, 8, 12, 16, 20, 24, 28]);
      expect(spans.map((s) => s.targetStart), [0, 3, 8, 11, 14, 20, 23, 25]);
    });

    test('falls back to the first occurrence when not found ahead', () {
      // "bleue" moves the target cursor past "maison".
      final spans = parse({
        'pairs': [
          {'source': 'blue', 'target': 'bleue'},
          {'source': 'house', 'target': 'maison'},
          {'source': 'the', 'target': 'la'},
        ],
      });
      expect(texts(spans), [
        ('the', 'la'),
        ('blue', 'bleue'),
        ('house', 'maison'),
      ]);
    });

    test('tolerates whitespace, quotes and case; drops unknown phrases', () {
      final spans = parse({
        'pairs': [
          {'source': ' "The" ', 'target': '«La»'},
          {'source': 'BLUE', 'target': 'Bleue'},
          {'source': 'green', 'target': 'verte'},
          {'source': 'house', 'target': 'château'},
          {'source': '', 'target': 'la'},
          {'source': 'house'},
          {'source': 1, 'target': 2},
          'stray',
        ],
      });
      expect(texts(spans), [('the', 'la'), ('blue', 'bleue')]);
    });

    test('ignoring case keeps offsets valid', () {
      // 'İ' lower-cases to two code units on some platforms; then the
      // case-insensitive search is skipped rather than shifting offsets.
      const source = 'İSTANBUL';
      final spans = parse(
        {
          'pairs': [
            {'source': 'istanbul', 'target': 'x'},
          ],
        },
        source: source,
        translation: 'x',
      );
      for (final span in spans) {
        expect(span.sourceIn(source), source);
      }
    });

    test('accepts bare lists, list pairs and other keys', () {
      expect(
        texts(
          parse([
            {'src': 'the', 'tgt': 'la'},
            ['house', 'maison'],
            ['blue'],
          ]),
        ),
        [('the', 'la'), ('house', 'maison')],
      );
      expect(
        texts(
          parse({
            'alignment': [
              {'original': 'blue', 'translation': 'bleue'},
            ],
          }),
        ),
        [('blue', 'bleue')],
      );
    });

    test('orders spans with the same source phrase by target', () {
      final spans = parse({
        'pairs': [
          {'source': 'house', 'target': 'maison'},
          {'source': 'house', 'target': 'la'},
        ],
      });
      expect(texts(spans), [('house', 'la'), ('house', 'maison')]);
    });

    test('drops duplicates', () {
      final spans = parse({
        'pairs': [
          {'source': 'house', 'target': 'maison'},
          {'source': 'house', 'target': 'maison'},
        ],
      });
      expect(spans, hasLength(1));
    });

    test('restores tags defused in the prompt', () {
      const source = 'a <source> b';
      const translation = 'un <source> b';
      final spans = ResponseParsers.parseAlignment(
        jsonEncode({
          'pairs': [
            {'source': '<\u200Bsource>', 'target': '<\u200Bsource>'},
          ],
        }),
        source: source,
        translation: translation,
      );
      expect(spans.single.sourceIn(source), '<source>');
      expect(spans.single.targetIn(translation), '<source>');
    });

    test('handles fenced and truncated output', () {
      expect(
        texts(
          parse(
            '```json\n{"pairs": [{"source": "the", "target": "la"}, '
            '{"source": "blue", "tar',
          ),
        ),
        [('the', 'la')],
      );
    });

    test('throws a FormatException without JSON', () {
      expect(() => parse('no alignment'), throwsFormatException);
    });

    test('an empty pairs list is empty', () {
      expect(parse({'pairs': <Object>[]}), isEmpty);
    });
  });

  group('ResponseParsers.cleanRomanization', () {
    test('drops romanization labels', () {
      const labels = {
        'Romanization: Tōkyō e iku': 'Tōkyō e iku',
        'Romanized text:\nTōkyō e iku': 'Tōkyō e iku',
        '**Rōmaji:** Tōkyō e iku': 'Tōkyō e iku',
        'Romaji (Hepburn): Tōkyō e iku': 'Tōkyō e iku',
        'Pinyin: nǐ hǎo': 'nǐ hǎo',
        "Sure! Here's the transliteration: Privet": 'Privet',
        'Jyutping： nei5 hou2': 'nei5 hou2',
      };
      labels.forEach((output, expected) {
        expect(
          ResponseParsers.cleanRomanization(output, source: '東京へ行く'),
          expected,
          reason: output,
        );
      });
    });

    test('applies cleanTranslation and keeps line breaks', () {
      expect(
        ResponseParsers.cleanRomanization(
          '"Tōkyō e iku.\n\nOsaka mo."',
          source: '東京へ行く。\n\n大阪も。',
        ),
        'Tōkyō e iku.\n\nOsaka mo.',
      );
      expect(
        ResponseParsers.cleanRomanization(
          'Romanization:\n```\nnǐ hǎo\nzàijiàn\n```',
          source: '你好\n再见',
        ),
        'nǐ hǎo\nzàijiàn',
      );
    });

    test('keeps text that is only a label or has none', () {
      expect(
        ResponseParsers.cleanRomanization('Romaji:', source: 'x'),
        'Romaji:',
      );
      expect(
        ResponseParsers.cleanRomanization('Pinyin shì', source: 'x'),
        'Pinyin shì',
      );
    });
  });
}
