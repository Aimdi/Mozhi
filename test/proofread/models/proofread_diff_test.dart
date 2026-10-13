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

  group('ProofreadDiff.locate boundaries', () {
    test('prefers whole words for short originals', () {
      expect(ProofreadDiff.locate('This is wrong.', [_edit('is', 'was')]), [
        const EditLocation(5, 7),
      ]);
      expect(
        ProofreadDiff.locate('Mary want a apple and a orange.', [
          _edit('want', 'wants'),
          _edit('a', 'an'),
          _edit('a', 'an'),
        ]),
        [
          const EditLocation(5, 9),
          const EditLocation(10, 11),
          const EditLocation(22, 23),
        ],
      );
      expect(ProofreadDiff.locate('Banana, an apple.', [_edit('an', 'one')]), [
        const EditLocation(8, 10),
      ]);
    });

    test('falls back to a match inside a word', () {
      expect(ProofreadDiff.locate('unbelievable', [_edit('believ', 'x')]), [
        const EditLocation(2, 8),
      ]);
      // Inside a surrogate pair.
      expect(ProofreadDiff.locate('𠀀', [_edit('\uDC00', 'x')]), [
        const EditLocation(1, 2),
      ]);
    });

    test('does not split combining marks or supplementary letters', () {
      expect(ProofreadDiff.locate('cafe\u0301 cafe', [_edit('cafe', 'x')]), [
        const EditLocation(6, 10),
      ]);
      // 𝐀 is a letter outside the Basic Multilingual Plane.
      expect(ProofreadDiff.locate('𝐀abc abc', [_edit('abc', 'x')]), [
        const EditLocation(6, 9),
      ]);
      expect(ProofreadDiff.locate('abc𝐀 abc', [_edit('abc', 'x')]), [
        const EditLocation(6, 9),
      ]);
    });

    test('matches inside text of scripts without spaces', () {
      expect(ProofreadDiff.locate('我买了苹果。', [_edit('苹果', '香蕉')]), [
        const EditLocation(3, 5),
      ]);
      // A character from outside the Basic Multilingual Plane before it.
      expect(ProofreadDiff.locate('𠀀abc abc', [_edit('abc', 'x')]), [
        const EditLocation(2, 5),
      ]);
    });

    test('places out-of-order edits where they do not overlap', () {
      expect(
        ProofreadDiff.locate('Teh cat sat on teh mat.', [
          _edit('mat', 'rug'),
          _edit('Teh', 'The'),
          _edit('teh', 'the'),
        ]),
        [
          const EditLocation(19, 22),
          const EditLocation(0, 3),
          const EditLocation(15, 18),
        ],
      );
      expect(
        ProofreadDiff.locate('the cat and the cat', [
          _edit('and the cat', 'x'),
          _edit('the cat', 'y'),
        ]),
        [const EditLocation(8, 19), const EditLocation(0, 7)],
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

    test('does not edit inside other words', () {
      final edits = [
        _edit('want', 'wants'),
        _edit('a', 'an'),
        _edit('a', 'an'),
      ];
      const source = 'Mary want a apple and a orange.';
      expect(
        ProofreadDiff.apply(source, edits, {1, 2}),
        'Mary want an apple and an orange.',
      );
      expect(
        ProofreadDiff.apply('This is wrong.', [_edit('is', 'was')], {0}),
        'This was wrong.',
      );
    });

    test('applies out-of-order edits at their position', () {
      const source = 'Teh cat sat on teh mat.';
      final edits = [_edit('mat', 'rug'), _edit('Teh', 'The')];
      expect(
        ProofreadDiff.apply(source, edits, {0, 1}),
        'The cat sat on teh rug.',
      );
      expect(
        ProofreadDiff.apply(source, edits, {1}),
        'The cat sat on teh mat.',
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

    test('orders segments of out-of-order edits by position', () {
      const source = 'Teh cat sat on teh mat.';
      final edits = [_edit('mat', 'rug'), _edit('Teh', 'The')];
      final segments = ProofreadDiff.editSegments(source, edits, {0, 1});
      expect(segments.first, const DiffSegment.removed('Teh', editIndex: 1));
      expect(_before(segments), source);
      expect(_after(segments), 'The cat sat on teh rug.');
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

    test('splits scripts without spaces into characters', () {
      expect(ProofreadDiff.tokenize('买了苹果。'), ['买', '了', '苹', '果', '。']);
      expect(ProofreadDiff.tokenize('ไปเมื่อ'), ['ไ', 'ป', 'เ', 'มื่', 'อ']);
      expect(ProofreadDiff.tokenize('abc中文 ラーメン'), [
        'abc',
        '中',
        '文',
        ' ',
        'ラ',
        'ー',
        'メ',
        'ン',
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

    test('shows a one-character change in Chinese and Thai', () {
      expect(ProofreadDiff.wordDiff('我昨天去商店买了苹果。', '我昨天去商店买了香蕉。'), const [
        DiffSegment.unchanged('我昨天去商店买了'),
        DiffSegment.removed('苹果'),
        DiffSegment.inserted('香蕉'),
        DiffSegment.unchanged('。'),
      ]);
      final thai = ProofreadDiff.wordDiff(
        'ฉันไปตลาดเมื่อวานนี้',
        'ฉันไปตลาดเมื่อวานนี้แล้ว',
      );
      expect(thai, const [
        DiffSegment.unchanged('ฉันไปตลาดเมื่อวานนี้'),
        DiffSegment.inserted('แล้ว'),
      ]);
    });

    test('diffs long texts with many changes exactly', () {
      final words = List.generate(2000, (i) => 'w${i % 50}');
      final changed = [
        for (var i = 0; i < words.length; i++)
          if (i % 7 == 0) 'x$i' else words[i],
      ];
      final segments = ProofreadDiff.wordDiff(
        words.join(' '),
        changed.join(' '),
      );
      expect(segments.where((s) => s.type == DiffType.removed), hasLength(286));
      expect(_before(segments), words.join(' '));
      expect(_after(segments), changed.join(' '));
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

  group('ProofreadDiff.reconcile', () {
    String applyAll(String source, List<ProofreadEdit> edits) =>
        ProofreadDiff.apply(source, edits, {
          for (var i = 0; i < edits.length; i++) i,
        });

    test('returns the edits when the corrected text adds nothing', () {
      final edits = [_edit('has', 'have')];
      expect(ProofreadDiff.reconcile('I has it', edits, ''), same(edits));
      expect(ProofreadDiff.reconcile('I has it', edits, '  '), same(edits));
      expect(
        ProofreadDiff.reconcile('I has it', edits, 'I have it'),
        same(edits),
      );
    });

    test('adds unlisted changes as edits of their own', () {
      const source = 'I has a apple. Teh end.';
      final edits = [_edit('has', 'have'), _edit('a apple', 'an apple')];
      final reconciled = ProofreadDiff.reconcile(
        source,
        edits,
        'I have an apple. The end.',
      );
      expect(reconciled, [
        ...edits,
        const ProofreadEdit(
          original: 'Teh',
          replacement: 'The',
          category: ProofreadDiff.otherCategory,
        ),
      ]);
      // Rejecting a listed edit keeps the unlisted change.
      expect(
        ProofreadDiff.apply(source, reconciled, {1, 2}),
        'I has an apple. The end.',
      );
    });

    test('lets listed edits win over a corrected text that omits them', () {
      const source = 'I has a apple and a orange.';
      final edits = [
        _edit('has', 'have'),
        _edit('a apple', 'an apple'),
        _edit('a orange', 'an orange'),
      ];
      expect(ProofreadDiff.reconcile(source, edits, source), same(edits));
    });

    test('widens insertions and ambiguous originals until they are unique', () {
      const source = 'Hello world how are you';
      const corrected = 'Hello, world! How are you?';
      final reconciled = ProofreadDiff.reconcile(source, const [], corrected);
      expect(reconciled.map((e) => (e.original, e.replacement)), [
        ('Hello', 'Hello,'),
        (' how', '! How'),
        ('you', 'you?'),
      ]);
      expect(applyAll(source, reconciled), corrected);

      final second = ProofreadDiff.reconcile(
        'the cat and the dog',
        const [],
        'the cat and a dog',
      );
      expect(second.map((e) => (e.original, e.replacement)), [(' the', ' a')]);
    });

    test('merges changes on both sides of the same word', () {
      final reconciled = ProofreadDiff.reconcile(
        'cat',
        const [],
        'an apple . cat . an an',
      );
      expect(reconciled.map((e) => (e.original, e.replacement)), [
        ('cat', 'an apple . cat . an an'),
      ]);
    });

    test('skips changes it cannot place', () {
      // Nothing to attach an insertion to.
      expect(ProofreadDiff.reconcile('', const [], 'new'), isEmpty);
      // Periodic text never becomes unambiguous.
      final source = List.filled(40, 'a').join(' ');
      expect(
        ProofreadDiff.reconcile(
          source,
          const [],
          '${source.substring(0, source.length - 1)}b',
        ),
        isEmpty,
      );
    });

    test('reproduces arbitrary corrected texts', () {
      final random = Random(7);
      const words = ['a', 'the', 'cat', ',', '.', 'is', 'was', '\n', 'an'];
      String sentence() => [
        for (var i = 0; i < random.nextInt(30); i++)
          words[random.nextInt(words.length)],
      ].join(random.nextBool() ? ' ' : '  ');
      for (var i = 0; i < 300; i++) {
        final source = sentence();
        final corrected = sentence();
        if (source.isEmpty || corrected.trim().isEmpty) continue;
        final reconciled = ProofreadDiff.reconcile(source, const [], corrected);
        expect(
          applyAll(source, reconciled),
          corrected,
          reason: '$source -> $corrected',
        );
      }
    });
  });
}
