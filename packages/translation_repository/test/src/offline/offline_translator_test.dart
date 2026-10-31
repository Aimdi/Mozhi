import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

OfflineWord _word(
  int start,
  int end, {
  int? source,
  int? sourceEnd,
  double? p = 0.9,
}) => OfflineWord(
  targetStart: start,
  targetEnd: end,
  sourceStart: source,
  sourceEnd: sourceEnd,
  alignment: p,
);

void main() {
  group('OfflineTranslation.alignedSpans', () {
    test('one span per aligned word, joining words of one source', () {
      // "Wie geht es dir?" <- "How are you?": geht + es <- are.
      const translation = OfflineTranslation(
        text: 'Wie geht es dir?',
        sentences: [
          OfflineSentence(
            sourceStart: 0,
            sourceEnd: 12,
            targetStart: 0,
            targetEnd: 16,
            words: [
              OfflineWord(
                targetStart: 0,
                targetEnd: 3,
                sourceStart: 0,
                sourceEnd: 3,
                alignment: 0.99,
              ),
              OfflineWord(
                targetStart: 4,
                targetEnd: 8,
                sourceStart: 4,
                sourceEnd: 7,
                alignment: 0.92,
              ),
              OfflineWord(
                targetStart: 9,
                targetEnd: 11,
                sourceStart: 4,
                sourceEnd: 7,
                alignment: 0.92,
              ),
              OfflineWord(
                targetStart: 12,
                targetEnd: 16,
                sourceStart: 8,
                sourceEnd: 12,
                alignment: 0.98,
              ),
            ],
          ),
        ],
      );

      expect(translation.alignedSpans(), const [
        AlignedSpan(sourceStart: 0, sourceEnd: 3, targetStart: 0, targetEnd: 3),
        AlignedSpan(
          sourceStart: 4,
          sourceEnd: 7,
          targetStart: 4,
          targetEnd: 11,
        ),
        AlignedSpan(
          sourceStart: 8,
          sourceEnd: 12,
          targetStart: 12,
          targetEnd: 16,
        ),
      ]);
    });

    test('leaves out unsure, unaligned and empty words', () {
      final translation = OfflineTranslation(
        text: 'a b c d e f',
        sentences: [
          OfflineSentence(
            sourceStart: 0,
            sourceEnd: 5,
            targetStart: 0,
            targetEnd: 11,
            words: [
              _word(0, 1, source: 0, sourceEnd: 1),
              _word(2, 3, source: 0, sourceEnd: 1, p: 0.1),
              _word(4, 5, source: 0, sourceEnd: 1),
              _word(6, 7),
              _word(8, 8, source: 2, sourceEnd: 3),
              _word(10, 11, source: 3, sourceEnd: 3),
            ],
          ),
          OfflineSentence(
            sourceStart: 6,
            sourceEnd: 7,
            targetStart: 12,
            targetEnd: 13,
            words: [_word(12, 13, source: 6, sourceEnd: 7, p: null)],
          ),
        ],
      );

      // The unsure word in between splits the two words from source 0.
      expect(translation.alignedSpans(), const [
        AlignedSpan(sourceStart: 0, sourceEnd: 1, targetStart: 0, targetEnd: 1),
        AlignedSpan(sourceStart: 0, sourceEnd: 1, targetStart: 4, targetEnd: 5),
      ]);
      expect(translation.alignedSpans(minimum: 0), hasLength(2));
      expect(
        translation.alignedSpans(minimum: 0.05).first.targetEnd,
        5,
        reason: 'all three words of source 0 are one span',
      );
    });

    test('spans never join across sentences', () {
      final translation = OfflineTranslation(
        text: 'a. b.',
        sentences: [
          OfflineSentence(
            sourceStart: 0,
            sourceEnd: 2,
            targetStart: 0,
            targetEnd: 2,
            words: [_word(0, 2, source: 0, sourceEnd: 2)],
          ),
          OfflineSentence(
            sourceStart: 0,
            sourceEnd: 2,
            targetStart: 3,
            targetEnd: 5,
            words: [_word(3, 5, source: 0, sourceEnd: 2)],
          ),
        ],
      );

      expect(translation.alignedSpans(), hasLength(2));
    });
  });

  group('OfflineTranslation', () {
    const sure = OfflineSentence(
      sourceStart: 0,
      sourceEnd: 3,
      targetStart: 0,
      targetEnd: 4,
      score: -0.1,
    );
    const unsure = OfflineSentence(
      sourceStart: 4,
      sourceEnd: 7,
      targetStart: 5,
      targetEnd: 9,
      score: -0.9,
      isLowConfidence: true,
    );

    test('reports low confidence', () {
      const translation = OfflineTranslation(
        text: 'Gut. Sehr?',
        sentences: [sure, unsure],
      );

      expect(translation.hasLowConfidence, isTrue);
      expect(translation.lowConfidenceSentences, [unsure]);
      expect(
        const OfflineTranslation(text: 'x', sentences: [sure]).hasLowConfidence,
        isFalse,
      );
    });

    test('has value equality', () {
      const a = OfflineTranslation(text: 'x', sentences: [sure]);
      const b = OfflineTranslation(text: 'x', sentences: [sure]);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const OfflineTranslation(text: 'x')));
      expect(a, isNot(const OfflineTranslation(text: 'y', sentences: [sure])));
      expect('$a', 'OfflineTranslation(1 chars, 1 sentences)');
    });
  });

  group('OfflineSentence', () {
    const sentence = OfflineSentence(
      sourceStart: 1,
      sourceEnd: 6,
      targetStart: 2,
      targetEnd: 7,
      score: -0.2,
      words: [
        OfflineWord(
          targetStart: 2,
          targetEnd: 7,
          sourceStart: 1,
          sourceEnd: 6,
          alignment: 0.8,
          score: -0.2,
        ),
      ],
    );

    test('finds itself in the texts', () {
      expect(sentence.sourceIn(' Hello'), 'Hello');
      expect(sentence.targetIn('  Hallo'), 'Hallo');
    });

    test('shifts with its words', () {
      expect(sentence.shift(), same(sentence));
      final shifted = sentence.shift(source: 10, target: 20);

      expect(
        shifted,
        const OfflineSentence(
          sourceStart: 11,
          sourceEnd: 16,
          targetStart: 22,
          targetEnd: 27,
          score: -0.2,
          words: [
            OfflineWord(
              targetStart: 22,
              targetEnd: 27,
              sourceStart: 11,
              sourceEnd: 16,
              alignment: 0.8,
              score: -0.2,
            ),
          ],
        ),
      );
      expect(
        sentence
            .withLowConfidence(value: true)
            .shift(target: 1)
            .isLowConfidence,
        isTrue,
      );
    });

    test('withLowConfidence copies only when it changes', () {
      expect(sentence.withLowConfidence(value: false), same(sentence));
      final flagged = sentence.withLowConfidence(value: true);

      expect(flagged.isLowConfidence, isTrue);
      expect(flagged.words, sentence.words);
      expect(flagged.score, sentence.score);
      expect(flagged, isNot(sentence));
    });

    test('has value equality and a short description', () {
      expect(sentence, sentence.shift(source: 1).shift(source: -1));
      expect(
        sentence.hashCode,
        sentence.shift(source: 1).shift(source: -1).hashCode,
      );
      expect('$sentence', 'OfflineSentence(1-6 -> 2-7, score -0.2, 1 words)');
      const unsure = OfflineSentence(
        sourceStart: 0,
        sourceEnd: 1,
        targetStart: 0,
        targetEnd: 1,
        isLowConfidence: true,
      );
      expect('$unsure', 'OfflineSentence(0-1 -> 0-1, low confidence, 0 words)');
    });
  });

  group('OfflineWord', () {
    test('shifts, keeping unknown sources unknown', () {
      const word = OfflineWord(targetStart: 1, targetEnd: 2);

      expect(word.shift(), same(word));
      expect(
        word.shift(source: 5, target: 3),
        const OfflineWord(targetStart: 4, targetEnd: 5),
      );
    });

    test('has value equality and a short description', () {
      const word = OfflineWord(
        targetStart: 1,
        targetEnd: 2,
        sourceStart: 3,
        sourceEnd: 4,
      );

      expect(word, word.shift(target: 1).shift(target: -1));
      expect(word.hashCode, word.shift(target: 1).shift(target: -1).hashCode);
      expect(word, isNot(const OfflineWord(targetStart: 1, targetEnd: 2)));
      expect('$word', 'OfflineWord(1-2 <- 3-4)');
      expect(
        '${const OfflineWord(targetStart: 1, targetEnd: 2)}',
        'OfflineWord(1-2)',
      );
    });
  });

  test('OfflineTranslationCancelledException', () {
    expect(
      '${const OfflineTranslationCancelledException()}',
      'OfflineTranslationCancelledException()',
    );
  });

  test('OfflineDownloadCancelledException', () {
    expect(const OfflineDownloadCancelledException().language, isNull);
    expect(
      '${const OfflineDownloadCancelledException()}',
      'OfflineDownloadCancelledException()',
    );
    expect(
      '${const OfflineDownloadCancelledException('de')}',
      'OfflineDownloadCancelledException(de)',
    );
  });
}
