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

    test('finds a quoted phrase in a text shorter than the quotes', () {
      final spans = parse(
        {
          'pairs': [
            {'source': '"cat"', 'target': '«chat»'},
          ],
        },
        source: 'cat',
        translation: 'chat',
      );
      expect(spans, const [
        AlignedSpan(sourceStart: 0, sourceEnd: 3, targetStart: 0, targetEnd: 4),
      ]);
    });

    test('ignoring case gives offsets in the original text', () {
      // 'İ' lower-cases to two code units on the web: offsets must not
      // come from a lower-cased copy.
      const source = 'İzmir and PARIS';
      const translation = 'Izmir et Paris';
      final spans = parse(
        {
          'pairs': [
            {'source': 'paris', 'target': 'PARIS'},
            {'source': 'izmir', 'target': 'izmir'},
          ],
        },
        source: source,
        translation: translation,
      );
      expect(texts(spans, source: source, translation: translation), [
        ('PARIS', 'Paris'),
      ]);
      expect(spans.single.sourceStart, 10);
      expect(spans.single.targetStart, 9);
    });

    test('ignores case with simple case mappings only', () {
      // 'İ' matches 'i' only with full case folding: the pair is dropped
      // (on every platform) rather than mapped to shifted offsets.
      final spans = parse(
        {
          'pairs': [
            {'source': 'istanbul', 'target': 'x'},
          ],
        },
        source: 'İSTANBUL',
        translation: 'x',
      );
      expect(spans, isEmpty);
      final greek = parse(
        {
          'pairs': [
            {'source': 'σοφία', 'target': 'Sagesse'},
          ],
        },
        source: 'Η ΣΟΦΊΑ',
        translation: 'La sagesse',
      );
      expect(texts(greek, source: 'Η ΣΟΦΊΑ', translation: 'La sagesse'), [
        ('ΣΟΦΊΑ', 'sagesse'),
      ]);
    });

    test('maps reordered repeated phrases to the right occurrences', () {
      // Adjectives follow the noun in French: target positions are not in
      // source order.
      const source = 'the red car and the blue car';
      const translation = 'la voiture rouge et la voiture bleue';
      final spans = parse(
        {
          'pairs': [
            {'source': 'the', 'target': 'la'},
            {'source': 'red', 'target': 'rouge'},
            {'source': 'car', 'target': 'voiture'},
            {'source': 'and', 'target': 'et'},
            {'source': 'the', 'target': 'la'},
            {'source': 'blue', 'target': 'bleue'},
            {'source': 'car', 'target': 'voiture'},
          ],
        },
        source: source,
        translation: translation,
      );
      expect(
        [for (final s in spans) (s.sourceStart, s.targetStart)],
        [(0, 0), (4, 11), (8, 3), (12, 17), (16, 20), (20, 31), (25, 23)],
      );
    });

    test('maps a verb-final translation by proximity', () {
      // German puts the verb last; the second "hat" pair follows the first.
      const source = 'he has the book and she has the pen';
      const translation = 'er hat das Buch und sie hat den Stift';
      final spans = parse(
        {
          'pairs': [
            {'source': 'he', 'target': 'er'},
            {'source': 'has', 'target': 'hat'},
            {'source': 'the book', 'target': 'das Buch'},
            {'source': 'and', 'target': 'und'},
            {'source': 'she', 'target': 'sie'},
            {'source': 'has', 'target': 'hat'},
            {'source': 'the pen', 'target': 'den Stift'},
          ],
        },
        source: source,
        translation: translation,
      );
      expect(
        texts(spans, source: source, translation: translation).map((p) => p.$2),
        ['er', 'hat', 'das Buch', 'und', 'sie', 'hat', 'den Stift'],
      );
      expect(spans.map((s) => s.targetStart), [0, 3, 7, 16, 20, 24, 28]);
    });

    test('prefers whole words to matches inside other words', () {
      const source = 'I scattered the cat';
      const translation = 'Le chat a été dispersé par chatouille';
      final spans = parse(
        {
          'pairs': [
            {'source': 'cat', 'target': 'chat'},
          ],
        },
        source: source,
        translation: translation,
      );
      expect(spans.single.sourceStart, 16, reason: 'not inside "scattered"');
      expect(spans.single.targetStart, 3);
    });

    test('reads characters outside the BMP as whole characters', () {
      // 𝐀 (a mathematical letter) continues a word; 𠀀 (a Han character)
      // belongs to a script without spaces, so it does not.
      final spans = parse(
        {
          'pairs': [
            {'source': 'cat', 'target': 'chat'},
            {'source': 'cat', 'target': 'chat'},
          ],
        },
        source: '𝐀cat cat𝐀 cat 𠀀cat',
        translation: 'chat chat',
      );
      expect(spans.map((s) => s.sourceStart), [12, 18]);
      expect(spans.map((s) => s.targetStart), [0, 5]);
    });

    test('falls back to a match inside a word', () {
      // Compounds and scripts without spaces have no word boundaries.
      final german = parse(
        {
          'pairs': [
            {'source': 'house', 'target': 'Haus'},
          ],
        },
        source: 'the house work',
        translation: 'die Hausarbeit',
      );
      expect(german.single.targetStart, 4);
      final japanese = parse(
        {
          'pairs': [
            {'source': '猫', 'target': 'cat'},
            {'source': '犬', 'target': 'dog'},
          ],
        },
        source: '猫と犬',
        translation: 'a cat and a dog',
      );
      expect(japanese.map((s) => s.sourceStart), [0, 2]);
    });

    test('prefers a used whole word to an unused match inside a word', () {
      // Overlapping pairs ("the cat" and "cat") share the whole word.
      const source = 'I scattered the cat';
      final spans = parse(
        {
          'pairs': [
            {'source': 'the cat', 'target': 'le chat'},
            {'source': 'cat', 'target': 'chat'},
          ],
        },
        source: source,
        translation: "J'ai dispersé le chat",
      );
      expect(spans.map((s) => s.sourceStart), [12, 16]);
    });

    test('does not move back after an earlier occurrence', () {
      final spans = parse(
        {
          'pairs': [
            {'source': 'a', 'target': 'x'},
            {'source': 'c', 'target': 'z'},
            {'source': 'b', 'target': 'y'},
            {'source': 'a', 'target': 'x'},
          ],
        },
        source: 'a b a c a',
        translation: 'x y x z x',
      );
      // "b" is only found before "c"; the next "a" is still looked for
      // after "c".
      expect(spans.map((s) => s.sourceStart), [0, 2, 6, 8]);
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

    group('bounded work', () {
      const max = TranslationPrompts.maxAlignmentChars;

      test('reads at most maxAlignmentPairs items', () {
        List<AlignedSpan> withPairAt(int index) =>
            ResponseParsers.parseAlignment(
              jsonEncode({
                'pairs': [
                  for (var i = 0; i < index; i++)
                    {'source': 'missing', 'target': 'missing'},
                  {'source': 'blue', 'target': 'bleue'},
                ],
              }),
              source: 'the blue house',
              translation: 'la maison bleue',
            );
        expect(ResponseParsers.maxAlignmentPairs, 1000);
        expect(withPairAt(999), hasLength(1));
        expect(withPairAt(1000), isEmpty, reason: 'the 1001st is ignored');
      });

      test('searches only the beginning that the prompt sends', () {
        final filler = List.filled(max ~/ 5, 'abcd').join(' ');
        final source = '$filler tail';
        final translation = 'queue $filler';
        expect(source.length, greaterThan(max));
        final sent = TranslationPrompts.align(
          source: source,
          translation: translation,
          sourceLanguage: Language.auto,
          targetLanguage: Language.auto,
        ).last.content;
        expect(sent, isNot(contains('tail')));
        final spans = ResponseParsers.parseAlignment(
          jsonEncode({
            'pairs': [
              {'source': 'tail', 'target': 'queue'},
              {'source': 'abcd', 'target': 'abcd'},
            ],
          }),
          source: source,
          translation: translation,
        );
        // "tail" lies beyond what the model saw; "abcd" maps to offsets in
        // the whole texts.
        expect(spans, hasLength(1));
        expect(spans.single.sourceIn(source), 'abcd');
        expect(spans.single.sourceStart, 0);
        expect(spans.single.targetIn(translation), 'abcd');
        expect(spans.single.targetStart, 6);
      });

      test('stays fast for a hostile or runaway reply', () {
        // Formerly about 10 s for 300 such pairs on a 20,000-character
        // text: every pair scanned every occurrence and every earlier
        // pair.
        final repeated = List.filled(10000, 'a').join(' ');
        final inside = List.filled(4000, 'baaab').join(' ');
        final watch = Stopwatch()..start();
        for (final text in [repeated, inside]) {
          final spans = ResponseParsers.parseAlignment(
            jsonEncode({
              'pairs': List.filled(5000, {'source': 'a', 'target': 'A'}),
            }),
            source: text,
            translation: text,
          );
          expect(spans, hasLength(ResponseParsers.maxAlignmentPairs));
        }
        expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      });

      test('maps successive repeats in order on a long text', () {
        final text = List.filled(1000, 'a').join(' ');
        final spans = ResponseParsers.parseAlignment(
          jsonEncode({
            'pairs': List.filled(800, {'source': 'a', 'target': 'a'}),
          }),
          source: text,
          translation: text,
        );
        expect(spans.map((s) => s.sourceStart), [
          for (var i = 0; i < 800; i++) 2 * i,
        ]);
        expect(spans.map((s) => s.targetStart), [
          for (var i = 0; i < 800; i++) 2 * i,
        ]);
      });
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

    test('keeps a label word that the source starts with', () {
      expect(
        ResponseParsers.cleanRomanization(
          'Rōmaji: Nihongo o raten moji de kaku hōhō',
          source: 'ローマ字：日本語をラテン文字で書く方法',
        ),
        'Rōmaji: Nihongo o raten moji de kaku hōhō',
      );
      expect(
        ResponseParsers.cleanRomanization(
          'Pinyin: zhè shì yī gè lìzi',
          source: 'Pinyin: 这是一个例子',
        ),
        'Pinyin: zhè shì yī gè lìzi',
      );
      expect(
        ResponseParsers.cleanRomanization('Pīnyīn: hànzì', source: '拼音：汉字'),
        'Pīnyīn: hànzì',
      );
      // Another leading label (a speaker) does not protect the model's.
      expect(
        ResponseParsers.cleanRomanization(
          'Romaji: Tanaka: konnichiwa',
          source: '田中：こんにちは',
        ),
        'Tanaka: konnichiwa',
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
