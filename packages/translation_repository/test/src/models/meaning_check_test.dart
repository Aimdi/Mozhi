import 'dart:convert';

import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

/// Asserts value equality: [a] equals [b] (same hash) and differs from
/// every element of [different].
void expectValueEquality(Object a, Object b, List<Object> different) {
  expect(a, equals(b));
  expect(a.hashCode, b.hashCode);
  for (final other in different) {
    expect(a, isNot(equals(other)), reason: '$other');
  }
  expect(a, isNot(equals(Object())));
}

/// Defeats const canonicalisation.
T dyn<T>(T value) => value;

void main() {
  group(MeaningVerdict, () {
    test('byName ignores case and space; unknown names are null', () {
      expect(MeaningVerdict.byName('same'), MeaningVerdict.same);
      expect(MeaningVerdict.byName(' MINOR '), MeaningVerdict.minor);
      expect(MeaningVerdict.byName('Major'), MeaningVerdict.major);
      expect(MeaningVerdict.byName('different'), isNull);
      expect(MeaningVerdict.byName(''), isNull);
      expect(MeaningVerdict.byName(null), isNull);
    });

    test('fallback is same without issues, else minor', () {
      expect(MeaningVerdict.fallback(hasIssues: false), MeaningVerdict.same);
      expect(MeaningVerdict.fallback(hasIssues: true), MeaningVerdict.minor);
    });

    test('fallback is major when an issue changes the facts', () {
      const factual = {
        MeaningIssueType.negation,
        MeaningIssueType.number,
        MeaningIssueType.omission,
      };
      for (final type in MeaningIssueType.values) {
        expect(
          MeaningVerdict.fallback(
            hasIssues: true,
            issueTypes: [MeaningIssueType.other, type],
          ),
          factual.contains(type) ? MeaningVerdict.major : MeaningVerdict.minor,
          reason: type.name,
        );
      }
      expect(
        MeaningVerdict.fallback(
          hasIssues: false,
          issueTypes: const [MeaningIssueType.negation],
        ),
        MeaningVerdict.same,
      );
    });
  });

  group(MeaningIssueType, () {
    test('byName ignores case and space; unknown names are null', () {
      for (final type in MeaningIssueType.values) {
        expect(MeaningIssueType.byName(' ${type.name.toUpperCase()}'), type);
      }
      expect(MeaningIssueType.byName('missing'), isNull);
      expect(MeaningIssueType.byName(null), isNull);
    });
  });

  group(MeaningIssue, () {
    const issue = MeaningIssue(
      problem: 'The negation is lost.',
      type: MeaningIssueType.negation,
      sourceSpan: 'did not see',
      translationSpan: 'ai vu',
      suggestion: "n'ai pas vu",
      sourceStart: 2,
      sourceEnd: 13,
      translationStart: 2,
      translationEnd: 7,
    );

    test('has value equality', () {
      expectValueEquality(
        MeaningIssue(
          problem: dyn('The negation is lost.'),
          type: MeaningIssueType.negation,
          sourceSpan: 'did not see',
          translationSpan: 'ai vu',
          suggestion: "n'ai pas vu",
          sourceStart: 2,
          sourceEnd: 13,
          translationStart: 2,
          translationEnd: 7,
        ),
        issue,
        const [
          MeaningIssue(
            problem: 'Other.',
            type: MeaningIssueType.negation,
            sourceSpan: 'did not see',
            translationSpan: 'ai vu',
            suggestion: "n'ai pas vu",
            sourceStart: 2,
            sourceEnd: 13,
            translationStart: 2,
            translationEnd: 7,
          ),
          MeaningIssue(
            problem: 'The negation is lost.',
            sourceSpan: 'did not see',
            translationSpan: 'ai vu',
            suggestion: "n'ai pas vu",
            sourceStart: 2,
            sourceEnd: 13,
            translationStart: 2,
            translationEnd: 7,
          ),
          MeaningIssue(
            problem: 'The negation is lost.',
            type: MeaningIssueType.negation,
            sourceSpan: 'did not',
            translationSpan: 'ai vu',
            suggestion: "n'ai pas vu",
            sourceStart: 2,
            sourceEnd: 13,
            translationStart: 2,
            translationEnd: 7,
          ),
          MeaningIssue(
            problem: 'The negation is lost.',
            type: MeaningIssueType.negation,
            sourceSpan: 'did not see',
            translationSpan: 'vu',
            suggestion: "n'ai pas vu",
            sourceStart: 2,
            sourceEnd: 13,
            translationStart: 2,
            translationEnd: 7,
          ),
          MeaningIssue(
            problem: 'The negation is lost.',
            type: MeaningIssueType.negation,
            sourceSpan: 'did not see',
            translationSpan: 'ai vu',
            sourceStart: 2,
            sourceEnd: 13,
            translationStart: 2,
            translationEnd: 7,
          ),
          MeaningIssue(
            problem: 'The negation is lost.',
            type: MeaningIssueType.negation,
            sourceSpan: 'did not see',
            translationSpan: 'ai vu',
            suggestion: "n'ai pas vu",
            sourceStart: 3,
            sourceEnd: 13,
            translationStart: 2,
            translationEnd: 7,
          ),
          MeaningIssue(
            problem: 'The negation is lost.',
            type: MeaningIssueType.negation,
            sourceSpan: 'did not see',
            translationSpan: 'ai vu',
            suggestion: "n'ai pas vu",
            sourceStart: 2,
            sourceEnd: 14,
            translationStart: 2,
            translationEnd: 7,
          ),
          MeaningIssue(
            problem: 'The negation is lost.',
            type: MeaningIssueType.negation,
            sourceSpan: 'did not see',
            translationSpan: 'ai vu',
            suggestion: "n'ai pas vu",
            sourceStart: 2,
            sourceEnd: 13,
            translationStart: 3,
            translationEnd: 7,
          ),
          MeaningIssue(
            problem: 'The negation is lost.',
            type: MeaningIssueType.negation,
            sourceSpan: 'did not see',
            translationSpan: 'ai vu',
            suggestion: "n'ai pas vu",
            sourceStart: 2,
            sourceEnd: 13,
            translationStart: 2,
            translationEnd: 8,
          ),
        ],
      );
    });

    test('has defaults for an issue located in one text only', () {
      const omission = MeaningIssue(
        problem: 'The date is missing.',
        sourceSpan: 'on Monday',
        sourceStart: 4,
        sourceEnd: 13,
      );
      expect(omission.type, MeaningIssueType.other);
      expect(omission.translationSpan, isEmpty);
      expect(omission.suggestion, isEmpty);
      expect(omission.hasSourceRange, isTrue);
      expect(omission.hasTranslationRange, isFalse);
      expect(omission.coversTranslation(0), isFalse);
      expect(omission.coversSource(4), isTrue);
      expect(omission.toString(), 'MeaningIssue(other, 4-13 -> ---)');
    });

    test('round-trips through JSON', () {
      expect(issue.toJson(), {
        'type': 'negation',
        'problem': 'The negation is lost.',
        'sourceSpan': 'did not see',
        'translationSpan': 'ai vu',
        'suggestion': "n'ai pas vu",
        'sourceStart': 2,
        'sourceEnd': 13,
        'translationStart': 2,
        'translationEnd': 7,
      });
      expect(MeaningIssue.fromJson(issue.toJson()), issue);
      final json = jsonDecode(jsonEncode(issue)) as Map<String, dynamic>;
      expect(MeaningIssue.fromJson(json), issue);
    });

    test('toJson leaves out the offsets of an unlocated side', () {
      const addition = MeaningIssue(
        problem: 'Adds a word.',
        type: MeaningIssueType.addition,
        translationSpan: 'très',
        translationStart: 5,
        translationEnd: 9,
      );
      expect(addition.toJson(), {
        'type': 'addition',
        'problem': 'Adds a word.',
        'sourceSpan': '',
        'translationSpan': 'très',
        'suggestion': '',
        'translationStart': 5,
        'translationEnd': 9,
      });
      expect(MeaningIssue.fromJson(addition.toJson()), addition);
    });

    test('fromJson accepts snake_case keys, whole numbers and defaults', () {
      expect(
        MeaningIssue.fromJson(const {
          'type': 'NEGATION',
          'problem': 'The negation is lost.',
          'source_span': 'did not see',
          'translation_span': 'ai vu',
          'suggestion': "n'ai pas vu",
          'source_start': 2.0,
          'source_end': 13,
          'translation_start': 2,
          'translation_end': 7,
        }),
        issue,
      );
      expect(
        MeaningIssue.fromJson(const {'type': 'odd', 'sourceStart': null}),
        const MeaningIssue(problem: ''),
      );
      expect(
        MeaningIssue.fromJson(const {'type': 3}).type,
        MeaningIssueType.other,
      );
    });

    test('fromJson rejects invalid texts and offsets', () {
      final valid = issue.toJson();
      for (final invalid in <Map<String, dynamic>>[
        {...valid, 'problem': 1},
        {
          ...valid,
          'sourceSpan': const ['did'],
        },
        {...valid}..remove('sourceStart'),
        {...valid}..remove('translationEnd'),
        {...valid, 'sourceEnd': '13'},
        {...valid, 'sourceStart': -1},
        {...valid, 'translationEnd': 7.5},
        {...valid, 'sourceEnd': 12},
        {...valid, 'translationStart': 8},
        {...valid, 'translationSpan': ''},
      ]) {
        expect(
          () => MeaningIssue.fromJson(invalid),
          throwsFormatException,
          reason: '$invalid',
        );
      }
    });

    test('tests offsets on both sides', () {
      expect(issue.coversSource(1), isFalse);
      expect(issue.coversSource(2), isTrue);
      expect(issue.coversSource(12), isTrue);
      expect(issue.coversSource(13), isFalse);
      expect(issue.coversTranslation(1), isFalse);
      expect(issue.coversTranslation(2), isTrue);
      expect(issue.coversTranslation(6), isTrue);
      expect(issue.coversTranslation(7), isFalse);
      expect(issue.toString(), 'MeaningIssue(negation, 2-13 -> 2-7)');
    });
  });

  group(MeaningCheck, () {
    const issue = MeaningIssue(
      problem: 'The number differs.',
      type: MeaningIssueType.number,
      sourceSpan: '3',
      translationSpan: '2',
      suggestion: '3',
      sourceStart: 4,
      sourceEnd: 5,
      translationStart: 8,
      translationEnd: 9,
    );
    const check = MeaningCheck(
      verdict: MeaningVerdict.major,
      backTranslation: 'I saw 2 cats',
      issues: [issue],
    );

    test('has defaults', () {
      const empty = MeaningCheck(verdict: MeaningVerdict.same);
      expect(empty.backTranslation, isEmpty);
      expect(empty.issues, isEmpty);
      expect(empty.isPartial, isFalse);
      expect(empty.isSame, isTrue);
      expect(check.isSame, isFalse);
    });

    test('has value equality', () {
      expectValueEquality(
        MeaningCheck(
          verdict: MeaningVerdict.major,
          backTranslation: dyn('I saw 2 cats'),
          issues: [dyn(issue)],
        ),
        check,
        const [
          MeaningCheck(
            verdict: MeaningVerdict.minor,
            backTranslation: 'I saw 2 cats',
            issues: [issue],
          ),
          MeaningCheck(
            verdict: MeaningVerdict.major,
            backTranslation: 'I saw two cats',
            issues: [issue],
          ),
          MeaningCheck(verdict: MeaningVerdict.major, backTranslation: 'x'),
          MeaningCheck(
            verdict: MeaningVerdict.major,
            backTranslation: 'I saw 2 cats',
            issues: [issue],
            isPartial: true,
          ),
        ],
      );
    });

    test('copyWith replaces the given fields only', () {
      expect(check.copyWith(), check);
      expect(
        check.copyWith(
          verdict: MeaningVerdict.minor,
          backTranslation: 'b',
          issues: const [],
          isPartial: true,
        ),
        const MeaningCheck(
          verdict: MeaningVerdict.minor,
          backTranslation: 'b',
          isPartial: true,
        ),
      );
    });

    test('round-trips through JSON', () {
      expect(check.toJson(), {
        'verdict': 'major',
        'backTranslation': 'I saw 2 cats',
        'issues': [issue.toJson()],
        'isPartial': false,
      });
      final json = jsonDecode(jsonEncode(check)) as Map<String, dynamic>;
      expect(MeaningCheck.fromJson(json), check);
      final partial = check.copyWith(isPartial: true);
      expect(MeaningCheck.fromJson(partial.toJson()), partial);
    });

    test('fromJson accepts snake_case keys and defaults the verdict', () {
      expect(
        MeaningCheck.fromJson({
          'verdict': ' Major',
          'back_translation': 'I saw 2 cats',
          'issues': [issue.toJson()],
          'is_partial': true,
        }),
        check.copyWith(isPartial: true),
      );
      expect(
        MeaningCheck.fromJson(const {}),
        const MeaningCheck(verdict: MeaningVerdict.same),
      );
      // A negation issue changes the facts.
      expect(
        MeaningCheck.fromJson({
          'verdict': 'wrong',
          'issues': [issue.toJson()],
        }).verdict,
        MeaningVerdict.major,
      );
      expect(
        MeaningCheck.fromJson({
          'issues': [
            const MeaningIssue(
              problem: 'Past instead of future.',
              type: MeaningIssueType.tense,
            ).toJson(),
          ],
        }).verdict,
        MeaningVerdict.minor,
      );
      expect(
        MeaningCheck.fromJson(const {'verdict': 2}).verdict,
        MeaningVerdict.same,
      );
    });

    test('fromJson rejects invalid fields', () {
      for (final invalid in <Map<String, dynamic>>[
        {'verdict': 'same', 'backTranslation': 1},
        {'verdict': 'same', 'issues': 'none'},
        {
          'verdict': 'same',
          'issues': ['x'],
        },
        {
          'verdict': 'same',
          'issues': [
            {'problem': 2},
          ],
        },
        {'verdict': 'same', 'isPartial': 'yes'},
      ]) {
        expect(
          () => MeaningCheck.fromJson(invalid),
          throwsFormatException,
          reason: '$invalid',
        );
      }
    });

    test('fromJson issues are unmodifiable', () {
      final parsed = MeaningCheck.fromJson(check.toJson());
      expect(() => parsed.issues.add(issue), throwsUnsupportedError);
    });

    test('toString summarises the check', () {
      expect(check.toString(), 'MeaningCheck(major, 1 issues)');
      expect(
        check.copyWith(isPartial: true).toString(),
        'MeaningCheck(major, 1 issues, partial)',
      );
    });
  });
}
