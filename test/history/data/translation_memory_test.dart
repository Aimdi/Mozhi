import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/history/data/translation_memory.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:translation_repository/translation_repository.dart';

const _en = Language(code: 'en', name: 'English');
const _de = Language(code: 'de', name: 'German');
const _fr = Language(code: 'fr', name: 'French');
const _pirate = Language.custom('Pirate speak');

final _now = DateTime(2026, 10, 14, 12);

HistoryEntry _entry(
  String id, {
  required String text,
  String? translation,
  Language source = Language.auto,
  Language target = _de,
  String? detectedSource,
  Duration age = Duration.zero,
  bool isFavorite = false,
}) => HistoryEntry(
  id: id,
  text: text,
  translation: translation ?? 'translation $id',
  source: source,
  target: target,
  engineId: 'mozhi:google',
  engineName: 'Google',
  createdAt: _now.subtract(age),
  detectedSource: detectedSource,
  isFavorite: isFavorite,
);

const _sentence = 'The quick brown fox jumps over the lazy dog';

void main() {
  late TranslationMemory memory;

  setUp(() {
    memory = TranslationMemory();
  });

  MemoryMatch? lookup(
    String text,
    List<HistoryEntry> entries, {
    Language source = Language.auto,
    Language target = _de,
    Duration? maxAge,
    Set<String> excludeFuzzy = const {},
  }) => memory.lookup(
    text,
    source: source,
    target: target,
    entries: entries,
    maxAge: maxAge,
    now: _now,
    excludeFuzzy: excludeFuzzy,
  );

  group('normalize', () {
    test('trims, lower-cases and collapses whitespace', () {
      expect(
        TranslationMemory.normalize('  Hello \n\t  World  '),
        'hello world',
      );
      expect(TranslationMemory.normalize('ÄÖÜ'), 'äöü');
      expect(TranslationMemory.normalize('   '), '');
    });
  });

  group('exact matches', () {
    test('match the normalised text', () {
      final entry = _entry('1', text: 'Hello   World');
      final match = lookup('  hello world\n', [entry]);
      expect(match?.entry, entry);
      expect(match?.kind, MemoryMatchKind.exact);
      expect(match?.isExact, isTrue);
      expect(match?.similarity, 1);
      expect(match?.percent, 100);
      expect(match?.diff, isEmpty);
    });

    test('short text matches exactly', () {
      final entry = _entry('1', text: 'Hi');
      expect(lookup('hi', [entry])?.entry, entry);
    });

    test('pick the newest of several', () {
      final newer = _entry('2', text: 'hello', translation: 'hallo');
      final older = _entry('1', text: 'Hello', translation: 'servus');
      expect(lookup('hello', [newer, older])?.entry, newer);
    });

    test('win over a more recent similar match', () {
      final similar = _entry('2', text: '${_sentence}s');
      final exact = _entry('1', text: _sentence);
      expect(lookup(_sentence, [similar, exact])?.entry, exact);
    });

    test('nothing for empty input', () {
      expect(lookup('   ', [_entry('1', text: '')]), isNull);
    });

    test('skip entries with an empty text or translation', () {
      expect(
        lookup('hello', [_entry('1', text: 'hello', translation: ' ')]),
        isNull,
      );
      expect(lookup('', [_entry('1', text: ' ')]), isNull);
    });

    test('nothing for different text', () {
      expect(lookup('hello', [_entry('1', text: 'goodbye')]), isNull);
    });

    test('skip dictionary look-ups (their translation is a summary)', () {
      final lookUp = HistoryEntry(
        id: 'dictionary:1',
        kind: HistoryEntryKind.dictionary,
        text: _sentence,
        translation: 'noun · A sentence with every letter.',
        source: Language.auto,
        target: _de,
        engineId: 'ai:claude',
        engineName: 'Claude',
        createdAt: _now,
      );
      final translation = _entry('2', text: _sentence);

      expect(lookup(_sentence, [lookUp]), isNull);
      expect(lookup('${_sentence}s', [lookUp]), isNull);
      expect(lookup(_sentence, [lookUp, translation])?.entry, translation);
    });

    test('punctuation is not normalised', () {
      // Short text only matches exactly; punctuation is not normalised.
      expect(lookup('hello!', [_entry('1', text: 'hello')]), isNull);
    });
  });

  group('languages', () {
    test('the target must match', () {
      final entry = _entry('1', text: 'hello', target: _fr);
      expect(lookup('hello', [entry]), isNull);
      expect(lookup('hello', [entry], target: _fr)?.entry, entry);
    });

    test('target codes are compared normalised', () {
      final entry = _entry(
        '1',
        text: 'hello',
        target: const Language(code: 'iw', name: 'Hebrew'),
      );
      expect(
        lookup('hello', [
          entry,
        ], target: const Language(code: 'he', name: 'Hebrew'))?.entry,
        entry,
      );
    });

    test('custom targets match by name, not a code', () {
      final entry = _entry('1', text: 'hello', target: _pirate);
      expect(lookup('hello', [entry], target: _pirate)?.entry, entry);
      expect(
        lookup('hello', [
          entry,
        ], target: const Language.custom('pirate SPEAK'))?.entry,
        entry,
      );
      expect(
        lookup('hello', [
          entry,
        ], target: const Language(code: 'Pirate speak', name: 'x')),
        isNull,
      );
    });

    test('an auto source matches any entry source', () {
      final entry = _entry('1', text: 'hello', source: _en);
      expect(lookup('hello', [entry])?.entry, entry);
    });

    test('a chosen source must match the entry source', () {
      final entry = _entry('1', text: 'hello', source: _en);
      expect(lookup('hello', [entry], source: _en)?.entry, entry);
      expect(lookup('hello', [entry], source: _fr), isNull);
    });

    test('an auto entry matches a chosen source by its detected language', () {
      final detected = _entry('1', text: 'hello', detectedSource: 'en');
      final unknown = _entry('2', text: 'hello');
      expect(lookup('hello', [detected], source: _en)?.entry, detected);
      expect(lookup('hello', [detected], source: _fr), isNull);
      expect(lookup('hello', [unknown], source: _fr)?.entry, unknown);
    });

    test('custom sources', () {
      const slang = Language.custom('Gen Z slang');
      final custom = _entry('1', text: 'hello', source: slang);
      final detected = _entry('2', text: 'hello', detectedSource: 'en');
      final unknown = _entry('3', text: 'hello');
      expect(lookup('hello', [custom], source: slang)?.entry, custom);
      expect(lookup('hello', [custom], source: _en), isNull);
      expect(lookup('hello', [detected], source: slang), isNull);
      expect(lookup('hello', [unknown], source: slang)?.entry, unknown);
    });
  });

  group('similar matches', () {
    test('match text that differs a little', () {
      final entry = _entry(
        '1',
        text: 'The quick brown fox jumps over the lazy cat',
      );
      final match = lookup(_sentence, [entry]);
      expect(match?.entry, entry);
      expect(match?.kind, MemoryMatchKind.similar);
      expect(match?.isExact, isFalse);
      expect(match!.similarity, closeTo(1 - 3 / 43, 1e-9));
      expect(match.percent, 93);
      expect(match.diff, const [
        MemoryDiffSegment(
          'The quick brown fox jumps over the lazy',
          MemoryDiffOp.equal,
        ),
        MemoryDiffSegment(' cat', MemoryDiffOp.removed),
        MemoryDiffSegment(' dog', MemoryDiffOp.added),
      ]);
    });

    test('pick the most similar entry', () {
      final far = _entry(
        '1',
        text: 'The quick brown fox jumps over a lazy cat',
      );
      final near = _entry(
        '2',
        text: 'The quick brown fox jumps over the lazy dot',
      );
      expect(lookup(_sentence, [far, near])?.entry, near);
    });

    test('the newest of equally similar entries', () {
      final newer = _entry(
        '1',
        text: 'The quick brown fox jumps over the lazy dot',
      );
      final older = _entry(
        '2',
        text: 'The quick brown fox jumps over the lazy dig',
      );
      expect(lookup(_sentence, [newer, older])?.entry, newer);
    });

    test('not below the threshold', () {
      final entry = _entry(
        '1',
        text: 'The slow brown bear walks past the lazy dog',
      );
      expect(
        TranslationMemory.similarity(entry.text, _sentence),
        lessThan(0.85),
      );
      expect(lookup(_sentence, [entry]), isNull);
    });

    test('exactly at the threshold', () {
      // 20 characters, 3 edits: similarity 0.85.
      const text = 'abcdefghijklmnopqrst';
      final entry = _entry('1', text: 'abcdefghijklmnopqXYZ');
      final match = lookup(text, [entry]);
      expect(match?.similarity, closeTo(0.85, 1e-9));
      // One more edit is too many.
      expect(lookup(text, [_entry('2', text: 'abcdefghijklmnopWXYZ')]), isNull);
    });

    test('only for input of at least minFuzzyLength characters', () {
      final entry = _entry('1', text: 'Hello there my frien');
      expect(lookup('Hello there my friend', [entry])?.entry, entry);
      expect(
        lookup('Hello there my fri', [_entry('2', text: 'Hello there my fr')]),
        isNull,
      );
    });

    test('not against short entries', () {
      memory = TranslationMemory(minFuzzyLength: 10);
      expect(lookup('abcdefghij', [_entry('1', text: 'abcdefghi')]), isNull);
    });

    test('not for input longer than maxFuzzyLength', () {
      memory = TranslationMemory(maxFuzzyLength: 30);
      final entry = _entry(
        '1',
        text: 'The quick brown fox jumps over the lazy cat',
      );
      expect(lookup(_sentence, [entry]), isNull);
      // Exact matches still work.
      expect(lookup(entry.text, [entry])?.isExact, isTrue);
    });

    test('skip excluded entries', () {
      final entry = _entry(
        '1',
        text: 'The quick brown fox jumps over the lazy cat',
      );
      expect(lookup(_sentence, [entry], excludeFuzzy: {'1'}), isNull);
      // ... but not for an exact match.
      expect(lookup(entry.text, [entry], excludeFuzzy: {'1'})?.entry, entry);
    });

    test('respect the target language', () {
      final entry = _entry(
        '1',
        text: 'The quick brown fox jumps over the lazy cat',
        target: _fr,
      );
      expect(lookup(_sentence, [entry]), isNull);
    });

    test('compare at most maxCandidates entries exactly', () {
      memory = TranslationMemory(maxCandidates: 1);
      // Both pass the trigram filter; the rotated text shares more
      // trigrams but is too many edits away.
      final shuffled = _entry(
        '1',
        text: 'over the lazy dog The quick brown fox jumps',
      );
      final close = _entry(
        '2',
        text: 'The quick brown fox jumps over the lazy cat',
      );
      expect(lookup(_sentence, [shuffled, close]), isNull);
      memory = TranslationMemory(maxCandidates: 2);
      expect(lookup(_sentence, [shuffled, close])?.entry, close);
    });
  });

  group('limits', () {
    test('only the maxEntries newest entries are searched', () {
      memory = TranslationMemory(maxEntries: 2);
      final entries = [
        _entry('1', text: 'one'),
        _entry('2', text: 'two'),
        _entry('3', text: 'three'),
      ];
      expect(lookup('two', entries)?.entry, entries[1]);
      expect(lookup('three', entries), isNull);
    });

    test('dictionary look-ups do not count towards maxEntries', () {
      memory = TranslationMemory(maxEntries: 2);
      HistoryEntry lookUp(String id) => HistoryEntry(
        id: 'dictionary:$id',
        kind: HistoryEntryKind.dictionary,
        text: 'word $id',
        translation: 'noun · A word.',
        source: Language.auto,
        target: _de,
        engineId: 'ai:claude',
        engineName: 'Claude',
        createdAt: _now,
      );
      final entries = [
        lookUp('1'),
        lookUp('2'),
        lookUp('3'),
        _entry('1', text: 'one'),
        _entry('2', text: 'two'),
        _entry('3', text: 'three'),
      ];
      expect(lookup('two', entries)?.entry, entries[4]);
      expect(lookup('three', entries), isNull);
    });

    test('retention: expired non-favourites are skipped', () {
      final old = _entry('1', text: 'hello', age: const Duration(days: 8));
      final starred = _entry(
        '2',
        text: 'goodbye',
        age: const Duration(days: 8),
        isFavorite: true,
      );
      const week = Duration(days: 7);
      expect(lookup('hello', [old], maxAge: week), isNull);
      expect(lookup('hello', [old])?.entry, old);
      expect(lookup('goodbye', [starred], maxAge: week)?.entry, starred);
    });

    test('retention uses the real clock without now', () {
      final entry = HistoryEntry(
        id: '1',
        text: 'hello',
        translation: 'hallo',
        source: Language.auto,
        target: _de,
        engineId: 'e',
        engineName: 'E',
        createdAt: DateTime.now().subtract(const Duration(days: 2)),
      );
      expect(
        memory.lookup(
          'hello',
          source: Language.auto,
          target: _de,
          entries: [entry],
          maxAge: const Duration(days: 1),
        ),
        isNull,
      );
    });

    test('500 entries are searched quickly', () {
      final entries = [
        for (var i = 0; i < 600; i++)
          _entry(
            '$i',
            text:
                'Entry number $i talks about topic ${i * 7919 % 1000} and '
                'a few more words to make it a realistic sentence length.',
          ),
      ];
      const query =
          'Entry number 599 talks about topic 921 and a few more words to '
          'make it a realistic sentence lengths.';
      // Warm the per-entry cache once, like the first keystroke.
      memory.lookup(
        query,
        source: Language.auto,
        target: _de,
        entries: entries,
      );
      final watch = Stopwatch()..start();
      MemoryMatch? match;
      for (var i = 0; i < 20; i++) {
        match = memory.lookup(
          '$query $i',
          source: Language.auto,
          target: _de,
          entries: entries,
        );
      }
      watch.stop();
      // Entry 599 is beyond the 500 newest: the best is one of the others.
      expect(match, isNotNull);
      expect(int.parse(match!.entry.id), lessThan(500));
      // Well under a frame per lookup even on slow CI machines.
      expect(watch.elapsedMilliseconds / 20, lessThan(16));
    });

    test('a cold lookup over 500 long entries stays bounded', () {
      final long = List.filled(40, 'lorem ipsum dolor sit amet').join(' ');
      final entries = [
        for (var i = 0; i < 500; i++) _entry('$i', text: '$long $i'),
      ];
      final watch = Stopwatch()..start();
      final match = memory.lookup(
        '$long x',
        source: Language.auto,
        target: _de,
        entries: entries,
      );
      watch.stop();
      expect(match?.kind, MemoryMatchKind.similar);
      expect(watch.elapsedMilliseconds, lessThan(500));
    });
  });

  group('similarity', () {
    test('of equal and empty texts is 1', () {
      expect(TranslationMemory.similarity('Abc', ' abc '), 1);
      expect(TranslationMemory.similarity('', ''), 1);
    });

    test('is 1 - distance / longest', () {
      expect(TranslationMemory.similarity('kitten', 'sitting'), 1 - 3 / 7);
      expect(TranslationMemory.similarity('', 'abc'), 0);
    });
  });

  group('boundedLevenshtein', () {
    test('computes the distance within the bound', () {
      expect(TranslationMemory.boundedLevenshtein('kitten', 'sitting', 3), 3);
      expect(TranslationMemory.boundedLevenshtein('sitting', 'kitten', 5), 3);
      expect(TranslationMemory.boundedLevenshtein('abc', 'abc', 0), 0);
      expect(TranslationMemory.boundedLevenshtein('', 'ab', 2), 2);
      expect(TranslationMemory.boundedLevenshtein('flaw', 'lawn', 2), 2);
    });

    test('is null beyond the bound', () {
      expect(
        TranslationMemory.boundedLevenshtein('kitten', 'sitting', 2),
        isNull,
      );
      expect(TranslationMemory.boundedLevenshtein('a', 'abcd', 2), isNull);
      expect(TranslationMemory.boundedLevenshtein('', 'abc', 2), isNull);
      expect(TranslationMemory.boundedLevenshtein('a', 'b', -1), isNull);
      expect(
        TranslationMemory.boundedLevenshtein('abcdef', 'ghijkl', 3),
        isNull,
      );
    });

    test('agrees with the full computation', () {
      int full(String a, String b) {
        var row = List.generate(b.length + 1, (j) => j);
        for (var i = 1; i <= a.length; i++) {
          final next = [i, ...List.filled(b.length, 0)];
          for (var j = 1; j <= b.length; j++) {
            next[j] = [
              row[j] + 1,
              next[j - 1] + 1,
              row[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1),
            ].reduce((x, y) => x < y ? x : y);
          }
          row = next;
        }
        return row.last;
      }

      const words = [
        'translation',
        'transition',
        'translator',
        'memory',
        'memories',
        'mammary',
        'abcxyz',
        'zyxcba',
        '',
        'a',
      ];
      for (final a in words) {
        for (final b in words) {
          final distance = full(a, b);
          for (var max = 0; max <= 12; max++) {
            expect(
              TranslationMemory.boundedLevenshtein(a, b, max),
              distance <= max ? distance : isNull,
              reason: '$a/$b max $max',
            );
          }
        }
      }
    });
  });

  group('diff', () {
    test('marks changed words', () {
      expect(
        TranslationMemory.diff(
          'Please send me the  report today',
          'please send the final report tomorrow',
        ),
        const [
          MemoryDiffSegment('please send', MemoryDiffOp.equal),
          MemoryDiffSegment(' me', MemoryDiffOp.removed),
          MemoryDiffSegment(' the', MemoryDiffOp.equal),
          MemoryDiffSegment(' final', MemoryDiffOp.added),
          MemoryDiffSegment(' report', MemoryDiffOp.equal),
          MemoryDiffSegment(' today', MemoryDiffOp.removed),
          MemoryDiffSegment(' tomorrow', MemoryDiffOp.added),
        ],
      );
    });

    test('of equal texts is one segment', () {
      expect(TranslationMemory.diff('a b c d', 'a b c d'), const [
        MemoryDiffSegment('a b c d', MemoryDiffOp.equal),
      ]);
    });

    test('compares short text per character', () {
      expect(TranslationMemory.diff('東京に行く', '京都に行く'), const [
        MemoryDiffSegment('東', MemoryDiffOp.removed),
        MemoryDiffSegment('京', MemoryDiffOp.equal),
        MemoryDiffSegment('都', MemoryDiffOp.added),
        MemoryDiffSegment('に行く', MemoryDiffOp.equal),
      ]);
    });

    test('handles empty sides', () {
      expect(TranslationMemory.diff('', 'ab'), const [
        MemoryDiffSegment('ab', MemoryDiffOp.added),
      ]);
      expect(TranslationMemory.diff('ab', ''), const [
        MemoryDiffSegment('ab', MemoryDiffOp.removed),
      ]);
      expect(TranslationMemory.diff('', ''), isEmpty);
    });

    test('segments print readably', () {
      expect(
        const MemoryDiffSegment('a\nb', MemoryDiffOp.added).toString(),
        r'added(a\nb)',
      );
    });
  });
}
