import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

/// Asserts value equality: [a] equals [b] (same hash) and differs from
/// every element of [different].
void expectValueEquality(Object a, Object b, List<Object> different) {
  expect(a, equals(b));
  expect(a.hashCode, b.hashCode);
  for (final other in different) {
    expect(a, isNot(equals(other)));
  }
  expect(a, isNot(equals(Object())));
}

/// Defeats const canonicalisation.
T dyn<T>(T value) => value;

void main() {
  group(AlignedSpan, () {
    const span = AlignedSpan(
      sourceStart: 4,
      sourceEnd: 8,
      targetStart: 10,
      targetEnd: 15,
    );

    test('has value equality', () {
      expectValueEquality(
        AlignedSpan(
          sourceStart: dyn(4),
          sourceEnd: 8,
          targetStart: 10,
          targetEnd: 15,
        ),
        span,
        const [
          AlignedSpan(
            sourceStart: 5,
            sourceEnd: 8,
            targetStart: 10,
            targetEnd: 15,
          ),
          AlignedSpan(
            sourceStart: 4,
            sourceEnd: 9,
            targetStart: 10,
            targetEnd: 15,
          ),
          AlignedSpan(
            sourceStart: 4,
            sourceEnd: 8,
            targetStart: 11,
            targetEnd: 15,
          ),
          AlignedSpan(
            sourceStart: 4,
            sourceEnd: 8,
            targetStart: 10,
            targetEnd: 16,
          ),
        ],
      );
    });

    test('round-trips through JSON', () {
      expect(span.toJson(), {
        'sourceStart': 4,
        'sourceEnd': 8,
        'targetStart': 10,
        'targetEnd': 15,
      });
      expect(AlignedSpan.fromJson(span.toJson()), span);
    });

    test('fromJson accepts snake_case keys and whole numbers', () {
      expect(
        AlignedSpan.fromJson(const {
          'source_start': 4,
          'source_end': 8.0,
          'target_start': 10,
          'target_end': 15,
        }),
        span,
      );
    });

    test('fromJson rejects invalid offsets', () {
      const valid = {
        'sourceStart': 4,
        'sourceEnd': 8,
        'targetStart': 10,
        'targetEnd': 15,
      };
      for (final invalid in <Map<String, dynamic>>[
        {...valid}..remove('sourceStart'),
        {...valid, 'sourceEnd': '8'},
        {...valid, 'targetStart': -1},
        {...valid, 'targetEnd': 15.5},
        {...valid, 'sourceEnd': 3},
        {...valid, 'targetEnd': 9},
      ]) {
        expect(
          () => AlignedSpan.fromJson(invalid),
          throwsFormatException,
          reason: '$invalid',
        );
      }
    });

    test('extracts its phrases and tests offsets', () {
      expect(span.sourceIn('the blue house'), 'blue');
      expect(span.targetIn('la maison bleue'), 'bleue');
      expect(span.coversSource(3), isFalse);
      expect(span.coversSource(4), isTrue);
      expect(span.coversSource(7), isTrue);
      expect(span.coversSource(8), isFalse);
      expect(span.coversTarget(9), isFalse);
      expect(span.coversTarget(10), isTrue);
      expect(span.coversTarget(14), isTrue);
      expect(span.coversTarget(15), isFalse);
      expect(span.toString(), 'AlignedSpan(4-8 -> 10-15)');
    });
  });

  group('RefinementSuggestion.exclusiveGroup', () {
    test('is part of equality', () {
      expectValueEquality(
        RefinementSuggestion(
          label: dyn('l'),
          instruction: 'i',
          exclusiveGroup: dyn('length'),
        ),
        const RefinementSuggestion(
          label: 'l',
          instruction: 'i',
          exclusiveGroup: 'length',
        ),
        const [
          RefinementSuggestion(label: 'l', instruction: 'i'),
          RefinementSuggestion(
            label: 'l',
            instruction: 'i',
            exclusiveGroup: 'formality',
          ),
        ],
      );
      expect(
        const RefinementSuggestion(label: 'l', instruction: 'i').exclusiveGroup,
        isNull,
      );
    });

    test('defaults group opposite chips', () {
      final groups = {
        for (final suggestion in RefinementSuggestion.defaults)
          suggestion.label: suggestion.exclusiveGroup,
      };
      expect(groups, {
        'More formal': RefinementSuggestion.formalityGroup,
        'More casual': RefinementSuggestion.formalityGroup,
        'Shorter': RefinementSuggestion.lengthGroup,
        'Simpler': null,
        'More fluent': null,
        'More literal': null,
      });
      expect(RefinementSuggestion.formalityGroup, 'formality');
      expect(RefinementSuggestion.lengthGroup, 'length');
    });
  });

  group('DictionaryEntry round 3 fields', () {
    test('default to empty and null', () {
      const entry = DictionaryEntry(word: 'w');
      expect(entry.relatedWords, isEmpty);
      expect(entry.didYouMean, isNull);
    });

    test('are part of equality', () {
      expectValueEquality(
        DictionaryEntry(
          word: dyn('w'),
          relatedWords: dyn(['a', 'b']),
          didYouMean: dyn('x'),
        ),
        DictionaryEntry(
          word: dyn('w'),
          relatedWords: dyn(['a', 'b']),
          didYouMean: dyn('x'),
        ),
        [
          const DictionaryEntry(word: 'w', relatedWords: ['a', 'b']),
          const DictionaryEntry(
            word: 'w',
            relatedWords: ['a'],
            didYouMean: 'x',
          ),
          const DictionaryEntry(word: 'w', didYouMean: 'x'),
        ],
      );
    });
  });

  test('DictionaryVerbosity has three levels', () {
    expect(DictionaryVerbosity.values, [
      DictionaryVerbosity.concise,
      DictionaryVerbosity.standard,
      DictionaryVerbosity.comprehensive,
    ]);
  });
}
