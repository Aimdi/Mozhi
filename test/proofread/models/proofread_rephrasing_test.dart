import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/proofread/models/proofread_diff.dart';
import 'package:mozhi/proofread/models/proofread_rephrasing.dart';
import 'package:mozhi/proofread/models/sentence_segmenter.dart';

const _base = 'I have an apple. It is red. We like it.';
// Sentences: [0, 16) [17, 27) [28, 39).
const _first = SentenceRange(0, 16);
const _second = SentenceRange(17, 27);
const _third = SentenceRange(28, 39);

ProofreadRephrasing _rephrasing(SentenceRange range, String replacement) =>
    ProofreadRephrasing(
      start: range.start,
      end: range.end,
      original: range.of(_base),
      replacement: replacement,
    );

void main() {
  test('the sample sentences', () {
    expect(SentenceSegmenter.split(_base), const [_first, _second, _third]);
  });

  group('ProofreadRephrasing', () {
    test('has value equality and its sentence', () {
      expect(
        _rephrasing(_second, 'It is crimson.'),
        _rephrasing(_second, 'It is crimson.'),
      );
      expect(_rephrasing(_second, 'x').sentence, _second);
    });
  });

  group('OutputSegment', () {
    test('has value equality and a readable string', () {
      const segment = OutputSegment(
        OutputSegmentType.inserted,
        'have',
        editIndex: 0,
        sentence: 1,
      );
      expect(
        segment,
        const OutputSegment(
          OutputSegmentType.inserted,
          'have',
          editIndex: 0,
          sentence: 1,
        ),
      );
      expect(segment.toString(), 'OutputSegment(inserted, "have", 0, 1)');
    });
  });

  group('ProofreadRephrasings.apply', () {
    test('returns the text without rephrasings', () {
      expect(ProofreadRephrasings.apply(_base, const []), _base);
    });

    test('replaces the sentences, in any order', () {
      expect(
        ProofreadRephrasings.apply(_base, [
          _rephrasing(_third, 'We love it.'),
          _rephrasing(_first, 'I own an apple.'),
        ]),
        'I own an apple. It is red. We love it.',
      );
    });

    test('ignores rephrasings that do not match the text', () {
      expect(
        ProofreadRephrasings.apply(_base, [
          const ProofreadRephrasing(
            start: 0,
            end: 16,
            original: 'Something else.',
            replacement: 'x',
          ),
          const ProofreadRephrasing(
            start: 30,
            end: 99,
            original: 'x',
            replacement: 'y',
          ),
          const ProofreadRephrasing(
            start: 5,
            end: 2,
            original: '',
            replacement: 'y',
          ),
        ]),
        _base,
      );
    });

    test('ignores a rephrasing that overlaps an earlier one', () {
      expect(
        ProofreadRephrasings.apply(_base, [
          _rephrasing(_first, 'One.'),
          ProofreadRephrasing(
            start: 10,
            end: 27,
            original: _base.substring(10, 27),
            replacement: 'Two.',
          ),
        ]),
        'One. It is red. We like it.',
      );
    });
  });

  group('ProofreadRephrasings.replace', () {
    test('adds a rephrasing in order', () {
      final rephrasings = ProofreadRephrasings.replace(
        _base,
        [_rephrasing(_third, 'We love it.')],
        _first,
        '  I own an apple.  ',
      );
      expect(rephrasings, [
        _rephrasing(_first, 'I own an apple.'),
        _rephrasing(_third, 'We love it.'),
      ]);
    });

    test('replaces an earlier rephrasing of the sentence', () {
      expect(
        ProofreadRephrasings.replace(
          _base,
          [_rephrasing(_second, 'It is crimson.')],
          _second,
          'It is scarlet.',
        ),
        [_rephrasing(_second, 'It is scarlet.')],
      );
    });

    test('removes the rephrasing for the sentence itself or blank text', () {
      final rephrasings = [_rephrasing(_second, 'It is crimson.')];
      expect(
        ProofreadRephrasings.replace(_base, rephrasings, _second, 'It is red.'),
        isEmpty,
      );
      expect(
        ProofreadRephrasings.replace(_base, rephrasings, _second, '  '),
        isEmpty,
      );
    });

    test('ignores a range that is no sentence', () {
      final rephrasings = [_rephrasing(_second, 'It is crimson.')];
      expect(
        ProofreadRephrasings.replace(
          _base,
          rephrasings,
          const SentenceRange(0, 5),
          'x',
        ),
        same(rephrasings),
      );
    });
  });

  group('ProofreadRephrasings.remap', () {
    final all = [
      _rephrasing(_first, 'I own an apple.'),
      _rephrasing(_second, 'It is crimson.'),
      _rephrasing(_third, 'We love it.'),
    ];

    test('keeps everything when the text is the same', () {
      expect(ProofreadRephrasings.remap(_base, _base, all), same(all));
      expect(ProofreadRephrasings.remap(_base, 'x', const []), isEmpty);
    });

    test('keeps the sentences before and after a change, shifted', () {
      const next = 'I have an apple. It is very red. We like it.';
      final moved = ProofreadRephrasings.remap(_base, next, all);
      expect(moved, [
        _rephrasing(_first, 'I own an apple.'),
        ProofreadRephrasing(
          start: 33,
          end: 44,
          original: _third.of(_base),
          replacement: 'We love it.',
        ),
      ]);
      expect(
        ProofreadRephrasings.apply(next, moved),
        'I own an apple. It is very red. We love it.',
      );
    });

    test('drops rephrasings that are no longer a sentence', () {
      // The change merges the last two sentences.
      const next = 'I have an apple. It is red, we like it.';
      expect(ProofreadRephrasings.remap(_base, next, all), [
        _rephrasing(_first, 'I own an apple.'),
      ]);
    });

    test('drops rephrasings that do not match the old text', () {
      expect(
        ProofreadRephrasings.remap(_base, '$_base!', [
          const ProofreadRephrasing(
            start: 0,
            end: 16,
            original: 'nope',
            replacement: 'x',
          ),
        ]),
        isEmpty,
      );
    });
  });

  group('ProofreadRephrasings.overlay', () {
    final sentences = SentenceSegmenter.split(_base);

    test('splits unchanged text at its sentences', () {
      expect(
        ProofreadRephrasings.overlay(
          const [DiffSegment.unchanged(_base)],
          _base,
          sentences,
          const [],
        ),
        const [
          OutputSegment(
            OutputSegmentType.unchanged,
            'I have an apple.',
            sentence: 0,
          ),
          OutputSegment(OutputSegmentType.unchanged, ' '),
          OutputSegment(OutputSegmentType.unchanged, 'It is red.', sentence: 1),
          OutputSegment(OutputSegmentType.unchanged, ' '),
          OutputSegment(
            OutputSegmentType.unchanged,
            'We like it.',
            sentence: 2,
          ),
        ],
      );
    });

    test('tags diff segments with their sentence and edit', () {
      const segments = [
        DiffSegment.unchanged('I '),
        DiffSegment.removed('has', editIndex: 0),
        DiffSegment.inserted('have', editIndex: 0),
        DiffSegment.unchanged(' an apple. It is red.'),
        DiffSegment.removed(' Wow', editIndex: 1),
        DiffSegment.unchanged(' We like it.'),
      ];
      expect(
        ProofreadRephrasings.overlay(segments, _base, sentences, const []),
        const [
          OutputSegment(OutputSegmentType.unchanged, 'I ', sentence: 0),
          OutputSegment(
            OutputSegmentType.removed,
            'has',
            editIndex: 0,
            sentence: 0,
          ),
          OutputSegment(
            OutputSegmentType.inserted,
            'have',
            editIndex: 0,
            sentence: 0,
          ),
          OutputSegment(OutputSegmentType.unchanged, ' an apple.', sentence: 0),
          OutputSegment(OutputSegmentType.unchanged, ' '),
          OutputSegment(OutputSegmentType.unchanged, 'It is red.', sentence: 1),
          // A removal at the end of a sentence belongs to it.
          OutputSegment(
            OutputSegmentType.removed,
            ' Wow',
            editIndex: 1,
            sentence: 1,
          ),
          OutputSegment(OutputSegmentType.unchanged, ' '),
          OutputSegment(
            OutputSegmentType.unchanged,
            'We like it.',
            sentence: 2,
          ),
        ],
      );
    });

    test('shows a rephrased sentence once, in place of its parts', () {
      const segments = [
        DiffSegment.unchanged('I '),
        DiffSegment.removed('has', editIndex: 0),
        DiffSegment.inserted('have', editIndex: 0),
        DiffSegment.unchanged(' an apple. It is red. We like it.'),
      ];
      expect(
        ProofreadRephrasings.overlay(segments, _base, sentences, [
          _rephrasing(_first, 'I own an apple.'),
        ]),
        const [
          OutputSegment(
            OutputSegmentType.rephrased,
            'I own an apple.',
            sentence: 0,
          ),
          OutputSegment(OutputSegmentType.unchanged, ' '),
          OutputSegment(OutputSegmentType.unchanged, 'It is red.', sentence: 1),
          OutputSegment(OutputSegmentType.unchanged, ' '),
          OutputSegment(
            OutputSegmentType.unchanged,
            'We like it.',
            sentence: 2,
          ),
        ],
      );
    });

    test('drops a removal at the start of a rephrased sentence', () {
      const base = 'Hi. It is red.';
      final sentences = SentenceSegmenter.split(base);
      const segments = [
        DiffSegment.unchanged('Hi. '),
        DiffSegment.removed('So ', editIndex: 0),
        DiffSegment.unchanged('It is red.'),
      ];
      expect(
        ProofreadRephrasings.overlay(segments, base, sentences, const [
          ProofreadRephrasing(
            start: 4,
            end: 14,
            original: 'It is red.',
            replacement: 'It is crimson.',
          ),
        ]),
        const [
          OutputSegment(OutputSegmentType.unchanged, 'Hi.', sentence: 0),
          OutputSegment(OutputSegmentType.unchanged, ' '),
          OutputSegment(
            OutputSegmentType.rephrased,
            'It is crimson.',
            sentence: 1,
          ),
        ],
      );
    });

    test('keeps leading whitespace and a removal there out of sentences', () {
      const base = '  Hi.';
      expect(
        ProofreadRephrasings.overlay(
          const [
            DiffSegment.removed('x', editIndex: 0),
            DiffSegment.unchanged(base),
          ],
          base,
          SentenceSegmenter.split(base),
          const [],
        ),
        const [
          OutputSegment(OutputSegmentType.removed, 'x', editIndex: 0),
          OutputSegment(OutputSegmentType.unchanged, '  '),
          OutputSegment(OutputSegmentType.unchanged, 'Hi.', sentence: 0),
        ],
      );
    });

    test('shows the text as unchanged when the segments do not match', () {
      expect(
        ProofreadRephrasings.overlay(
          const [DiffSegment.unchanged('Other.')],
          'Hi.',
          SentenceSegmenter.split('Hi.'),
          const [],
        ),
        const [OutputSegment(OutputSegmentType.unchanged, 'Hi.', sentence: 0)],
      );
    });
  });
}
