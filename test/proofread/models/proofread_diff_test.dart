import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/proofread/models/proofread_diff.dart';
import 'package:translation_repository/translation_repository.dart';

ProofreadEdit _edit(String original, String replacement) =>
    ProofreadEdit(original: original, replacement: replacement);

String _before(List<DiffSegment> segments) => segments
    .where((s) => s.type != DiffType.inserted)
    .map((s) => s.text)
    .join();

String _after(List<DiffSegment> segments) =>
    segments.where((s) => s.type != DiffType.removed).map((s) => s.text).join();

void main() {
  group('DiffSegment', () {
    test('supports value equality and named constructors', () {
      expect(
        const DiffSegment.removed('a', editIndex: 1),
        const DiffSegment(DiffType.removed, 'a', editIndex: 1),
      );
      expect(
        const DiffSegment.inserted('a'),
        isNot(const DiffSegment.unchanged('a')),
      );
      expect(
        const DiffSegment.unchanged('x', editIndex: 2).toString(),
        'DiffSegment(unchanged, "x", 2)',
      );
    });
  });

  group('EditLocation', () {
    test('supports value equality', () {
      expect(const EditLocation(1, 3), const EditLocation(1, 3));
      expect(const EditLocation(1, 3), isNot(const EditLocation(1, 4)));
    });
  });

  group('ProofreadDiff.locate', () {
    test('finds edits in order, searching after the previous edit', () {
      expect(
        ProofreadDiff.locate('the cat and the dog', [
          _edit('the', 'a'),
          _edit('the', 'a'),
        ]),
        [const EditLocation(0, 3), const EditLocation(12, 15)],
      );
    });

    test('skips missing, empty, overlapping and out-of-order originals', () {
      expect(
        ProofreadDiff.locate('teh cat sat down', [
          _edit('teh cat', 'the cat'),
          _edit('cat sat', 'cat sits'),
          _edit('', 'x'),
          _edit('missing', 'y'),
          _edit('down', 'up'),
          _edit('teh', 'the'),
        ]),
        [
          const EditLocation(0, 7),
          null,
          null,
          null,
          const EditLocation(12, 16),
          null,
        ],
      );
    });

    test('a skipped edit does not move the cursor', () {
      expect(
        ProofreadDiff.locate('a b a', [
          _edit('a', 'A'),
          _edit('zzz', 'Z'),
          _edit('a', 'A'),
        ]),
        [const EditLocation(0, 1), null, const EditLocation(4, 5)],
      );
    });
  });

  group('ProofreadDiff.apply', () {
    const source = 'I has a apple and a orange.';
    final edits = [
      _edit('has', 'have'),
      _edit('a apple', 'an apple'),
      _edit('a orange', 'an orange'),
    ];

    test('applies all accepted edits', () {
      expect(
        ProofreadDiff.apply(source, edits, {0, 1, 2}),
        'I have an apple and an orange.',
      );
    });

    test('applies only the accepted subset', () {
      expect(
        ProofreadDiff.apply(source, edits, {0, 2}),
        'I have a apple and an orange.',
      );
      expect(ProofreadDiff.apply(source, edits, {}), source);
    });

    test('rejected edits keep their position for later edits', () {
      // The second "the" must be replaced even though the first is rejected.
      expect(
        ProofreadDiff.apply(
          'the the cat',
          [_edit('the', ''), _edit('the', 'a')],
          {1},
        ),
        'the a cat',
      );
    });

    test('ignores accepted indices of skipped edits', () {
      expect(
        ProofreadDiff.apply('hello', [_edit('nope', 'x')], {0, 5}),
        'hello',
      );
    });

    test('handles deletions and empty input', () {
      expect(
        ProofreadDiff.apply('very very good', [_edit('very ', '')], {0}),
        'very good',
      );
      expect(ProofreadDiff.apply('', [_edit('a', 'b')], {0}), '');
    });
  });

  group('ProofreadDiff.editSegments', () {
    test('marks accepted edits with word-level changes', () {
      final segments = ProofreadDiff.editSegments(
        'Hello wrold, how are you',
        [_edit('wrold,', 'world,'), _edit('how are', 'how is')],
        {0, 1},
      );
      expect(segments, const [
        DiffSegment.unchanged('Hello '),
        DiffSegment.removed('wrold', editIndex: 0),
        DiffSegment.inserted('world', editIndex: 0),
        DiffSegment.unchanged(',', editIndex: 0),
        DiffSegment.unchanged(' '),
        DiffSegment.unchanged('how ', editIndex: 1),
        DiffSegment.removed('are', editIndex: 1),
        DiffSegment.inserted('is', editIndex: 1),
        DiffSegment.unchanged(' you'),
      ]);
    });

    test('shows rejected edits unchanged and skips unlocated ones', () {
      final segments = ProofreadDiff.editSegments(
        'one two three',
        [_edit('two', '2'), _edit('four', '4')],
        {1},
      );
      expect(segments, const [
        DiffSegment.unchanged('one '),
        DiffSegment.unchanged('two', editIndex: 0),
        DiffSegment.unchanged(' three'),
      ]);
    });

    test('reconstructs input and output', () {
      const source = 'Their going too the park tomorow.';
      final edits = [
        _edit('Their', "They're"),
        _edit('too', 'to'),
        _edit('tomorow', 'tomorrow'),
      ];
      for (final accepted in [
        <int>{},
        {0},
        {1, 2},
        {0, 1, 2},
      ]) {
        final segments = ProofreadDiff.editSegments(source, edits, accepted);
        expect(_before(segments), source);
        expect(_after(segments), ProofreadDiff.apply(source, edits, accepted));
      }
    });

    test('returns nothing for empty input', () {
      expect(ProofreadDiff.editSegments('', const [], const {}), isEmpty);
    });
  });

  group('ProofreadDiff.tokenize', () {
    test('splits words, whitespace and punctuation', () {
      expect(ProofreadDiff.tokenize("It's  fine, ok?\n"), [
        "It's",
        '  ',
        'fine',
        ',',
        ' ',
        'ok',
        '?',
        '\n',
      ]);
    });

    test('keeps non-Latin words with combining marks together', () {
      expect(ProofreadDiff.tokenize('வணக்கம் உலகம்'), [
        'வணக்கம்',
        ' ',
        'உலகம்',
      ]);
    });
  });

  group('ProofreadDiff.wordDiff', () {
    test('returns a single unchanged segment for equal text', () {
      expect(ProofreadDiff.wordDiff('same', 'same', editIndex: 3), const [
        DiffSegment.unchanged('same', editIndex: 3),
      ]);
      expect(ProofreadDiff.wordDiff('', ''), isEmpty);
    });

    test('handles pure insertions and deletions', () {
      expect(ProofreadDiff.wordDiff('', 'new'), const [
        DiffSegment.inserted('new'),
      ]);
      expect(ProofreadDiff.wordDiff('old', ''), const [
        DiffSegment.removed('old'),
      ]);
      expect(ProofreadDiff.wordDiff('a c', 'a b c'), const [
        DiffSegment.unchanged('a '),
        DiffSegment.inserted('b '),
        DiffSegment.unchanged('c'),
      ]);
    });

    test('puts removals before insertions', () {
      expect(ProofreadDiff.wordDiff('I has it', 'I have it'), const [
        DiffSegment.unchanged('I '),
        DiffSegment.removed('has'),
        DiffSegment.inserted('have'),
        DiffSegment.unchanged(' it'),
      ]);
    });

    test('folds whitespace between adjacent changes into one change', () {
      expect(ProofreadDiff.wordDiff('teh cat sat', 'the dog sat'), const [
        DiffSegment.removed('teh cat'),
        DiffSegment.inserted('the dog'),
        DiffSegment.unchanged(' sat'),
      ]);
    });

    test('reconstructs both sides for arbitrary edits', () {
      final random = Random(42);
      const words = ['a', 'the', 'cat', 'dog', ',', '.', 'is', 'was', '\n'];
      String sentence() => [
        for (var i = 0; i < random.nextInt(25); i++)
          words[random.nextInt(words.length)],
      ].join(random.nextBool() ? ' ' : '  ');
      for (var i = 0; i < 200; i++) {
        final before = sentence();
        final after = sentence();
        final segments = ProofreadDiff.wordDiff(before, after);
        expect(_before(segments), before, reason: '$before -> $after');
        expect(_after(segments), after, reason: '$before -> $after');
      }
    });

    test('falls back to a whole replacement for huge, unrelated texts', () {
      final before = List.generate(3000, (i) => 'a$i').join(' ');
      final after = List.generate(3000, (i) => 'b$i').join(' ');
      final segments = ProofreadDiff.wordDiff(before, after);
      expect(segments, [
        DiffSegment.removed(before),
        DiffSegment.inserted(after),
      ]);
    });

    test('diffs long texts with few changes', () {
      final words = List.generate(2000, (i) => 'w$i');
      final before = words.join(' ');
      final changed = [...words]
        ..[10] = 'first'
        ..[1990] = 'last';
      final segments = ProofreadDiff.wordDiff(before, changed.join(' '));
      expect(segments.where((s) => s.type != DiffType.unchanged), const [
        DiffSegment.removed('w10'),
        DiffSegment.inserted('first'),
        DiffSegment.removed('w1990'),
        DiffSegment.inserted('last'),
      ]);
      expect(_after(segments), changed.join(' '));
    });
  });
}
