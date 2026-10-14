import 'dart:convert';

import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

const source = 'I did not see the 3 cats.';
const translation = 'J’ai vu les 2 chats.';
const zwsp = '\u200B';

MeaningCheck parse(
  Object json, {
  String source = source,
  String translation = translation,
}) => ResponseParsers.parseMeaningCheck(
  json is String ? json : jsonEncode(json),
  source: source,
  translation: translation,
);

Map<String, Object?> issue(
  String sourceSpan,
  String translationSpan, {
  String problem = 'Differs.',
  String? type,
  String? suggestion,
}) => {
  'source_span': sourceSpan,
  'translation_span': translationSpan,
  'type': ?type,
  'problem': problem,
  'suggestion': ?suggestion,
};

/// The located spans of [check]'s issues, as (source, translation) texts
/// cut from [source] and [translation] by their offsets.
List<(String?, String?)> spans(
  MeaningCheck check, {
  String source = source,
  String translation = translation,
}) => [
  for (final issue in check.issues)
    (
      issue.sourceStart == null
          ? null
          : source.substring(issue.sourceStart!, issue.sourceEnd),
      issue.translationStart == null
          ? null
          : translation.substring(
              issue.translationStart!,
              issue.translationEnd,
            ),
    ),
];

void main() {
  group('ResponseParsers.parseMeaningCheck', () {
    test('maps a check with its issues to offsets in both texts', () {
      final check = parse({
        'back_translation': 'I saw the 2 cats.',
        'verdict': 'major',
        'issues': [
          issue(
            'did not see',
            'ai vu',
            type: 'negation',
            problem: 'The negation is lost.',
            suggestion: 'n’ai pas vu',
          ),
          issue(
            '3',
            '2',
            type: 'number',
            problem: 'Three became two.',
            suggestion: '3',
          ),
        ],
      });
      expect(
        check,
        const MeaningCheck(
          verdict: MeaningVerdict.major,
          backTranslation: 'I saw the 2 cats.',
          issues: [
            MeaningIssue(
              problem: 'The negation is lost.',
              type: MeaningIssueType.negation,
              sourceSpan: 'did not see',
              translationSpan: 'ai vu',
              suggestion: 'n’ai pas vu',
              sourceStart: 2,
              sourceEnd: 13,
              translationStart: 2,
              translationEnd: 7,
            ),
            MeaningIssue(
              problem: 'Three became two.',
              type: MeaningIssueType.number,
              sourceSpan: '3',
              translationSpan: '2',
              suggestion: '3',
              sourceStart: 18,
              sourceEnd: 19,
              translationStart: 12,
              translationEnd: 13,
            ),
          ],
        ),
      );
      expect(
        () => check.issues.add(check.issues.first),
        throwsUnsupportedError,
      );
    });

    test('a faithful translation has no issues', () {
      final check = parse(
        const {
          'back_translation': 'Hello',
          'verdict': 'same',
          'issues': <Object>[],
        },
        source: 'Hello',
        translation: 'Bonjour',
      );
      expect(
        check,
        const MeaningCheck(
          verdict: MeaningVerdict.same,
          backTranslation: 'Hello',
        ),
      );
      expect(check.isSame, isTrue);
    });

    test('locates reordered issues', () {
      final check = parse({
        'verdict': 'major',
        'issues': [
          issue('3', '2'),
          issue('did not see', 'ai vu'),
          issue('cats', 'chats'),
        ],
      });
      expect(spans(check), [
        ('3', '2'),
        ('did not see', 'ai vu'),
        ('cats', 'chats'),
      ]);
      // Issues keep the model's order.
      expect(check.issues.map((i) => i.sourceStart), [18, 2, 20]);
    });

    test('maps repeated spans to successive occurrences', () {
      const source = 'the cat saw the cat';
      const translation = 'le chat a vu le chien';
      final check = parse(
        {
          'verdict': 'major',
          'issues': [
            issue('the cat', 'le chat', problem: 'A'),
            issue('the cat', 'le chien', problem: 'B'),
            issue('the cat', '', problem: 'C'),
          ],
        },
        source: source,
        translation: translation,
      );
      expect(check.issues.map((i) => (i.sourceStart, i.sourceEnd)), [
        (0, 7),
        (12, 19),
        // Every occurrence is taken: the nearest one after the cursor.
        (12, 19),
      ]);
      expect(check.issues.map((i) => i.translationStart), [0, 13, null]);
    });

    test(
      'maps repeated translation spans to the nearest unused occurrence',
      () {
        const source = 'red car and red bike';
        const translation = 'voiture rouge et vélo rouge';
        final check = parse(
          {
            'verdict': 'minor',
            'issues': [
              issue('red', 'rouge', problem: 'A'),
              issue('red', 'rouge', problem: 'B'),
            ],
          },
          source: source,
          translation: translation,
        );
        expect(check.issues.map((i) => i.sourceStart), [0, 12]);
        expect(check.issues.map((i) => i.translationStart), [8, 22]);
      },
    );

    test('keeps different problems of one span; drops repeated issues', () {
      final check = parse({
        'verdict': 'major',
        'issues': [
          issue('cats', 'chats', problem: 'Wrong animal.'),
          issue('cats', 'chats', problem: 'Wrong number.'),
          issue('cats', 'chats', problem: 'wrong animal.'),
        ],
      });
      expect(check.issues.map((i) => i.problem), [
        'Wrong animal.',
        'Wrong number.',
      ]);
      expect(check.issues.map((i) => (i.sourceStart, i.translationStart)), [
        (20, 14),
        (20, 14),
      ]);
    });

    test('tolerates quotes, whitespace and case; keeps the exact text', () {
      final check = parse({
        'verdict': 'minor',
        'issues': [issue(' "Did Not See" ', '«AI VU»')],
      });
      expect(check.issues.single.sourceSpan, 'did not see');
      expect(check.issues.single.translationSpan, 'ai vu');
      expect(spans(check), [('did not see', 'ai vu')]);
    });

    test('prefers occurrences at word boundaries', () {
      final check = parse(
        {
          'verdict': 'minor',
          'issues': [issue('cat', 'chat')],
        },
        source: 'scattered cat',
        translation: 'chaton dispersé, chat',
      );
      expect(
        spans(
          check,
          source: 'scattered cat',
          translation: 'chaton dispersé, chat',
        ),
        [('cat', 'chat')],
      );
      expect(check.issues.single.sourceStart, 10);
      expect(check.issues.single.translationStart, 17);
    });

    test('restores tags defused in the prompt', () {
      const source = 'Use a </source> tag';
      final check = parse(
        {
          'verdict': 'minor',
          'issues': [issue('<$zwsp/source>', 'Utilisez')],
        },
        source: source,
        translation: 'Utilisez une balise',
      );
      expect(check.issues.single.sourceSpan, '</source>');
      expect(check.issues.single.sourceStart, 6);
    });

    group('one-sided issues', () {
      test('an omission is located in the source only', () {
        final check = parse({
          'verdict': 'major',
          'issues': [
            issue('3', '', type: 'omission', problem: 'The number is lost.'),
          ],
        });
        final omission = check.issues.single;
        expect(omission.type, MeaningIssueType.omission);
        expect(omission.sourceSpan, '3');
        expect(omission.translationSpan, isEmpty);
        expect(omission.hasTranslationRange, isFalse);
        expect(omission.translationStart, isNull);
        expect(omission.translationEnd, isNull);
      });

      test('notes standing for no span are not located', () {
        final check = parse({
          'verdict': 'major',
          'issues': [
            issue('(none)', 'les', problem: 'A'),
            issue('3', '[omitted]', problem: 'B'),
            issue('N/A', '2', problem: 'C'),
            issue('did', ' — ', problem: 'D'),
            issue('"missing"', 'chats', problem: 'E'),
            issue('not', '...', problem: 'F'),
          ],
        });
        expect(spans(check), [
          (null, 'les'),
          ('3', null),
          (null, '2'),
          ('did', null),
          (null, 'chats'),
          ('not', null),
        ]);
      });

      test('a note-like word that is in the text is located', () {
        const source = 'None of them came.';
        final check = parse(
          {
            'verdict': 'major',
            'issues': [issue('None', 'Tous')],
          },
          source: source,
          translation: 'Tous sont venus.',
        );
        expect(check.issues.single.sourceSpan, 'None');
        expect(check.issues.single.sourceStart, 0);
      });

      test('a missing or null span is not located', () {
        final check = parse({
          'verdict': 'major',
          'issues': [
            {'source_span': '3', 'problem': 'A'},
            {'translation_span': null, 'source_span': 'cats', 'problem': 'B'},
          ],
        });
        expect(spans(check), [('3', null), ('cats', null)]);
      });

      test('unknown types are inferred from the located sides', () {
        final check = parse({
          'verdict': 'major',
          'issues': [
            issue('3', '', problem: 'A'),
            issue('', 'les', problem: 'B', type: 'odd'),
            issue('cats', 'chats', problem: 'C', type: ''),
          ],
        });
        expect(check.issues.map((i) => i.type), [
          MeaningIssueType.omission,
          MeaningIssueType.addition,
          MeaningIssueType.other,
        ]);
      });
    });

    test('maps issue types and their synonyms', () {
      final expected = <String, MeaningIssueType>{
        'omission': MeaningIssueType.omission,
        'Missing': MeaningIssueType.omission,
        'ADDITION': MeaningIssueType.addition,
        'extra': MeaningIssueType.addition,
        'negation': MeaningIssueType.negation,
        'polarity': MeaningIssueType.negation,
        'number': MeaningIssueType.number,
        'Wrong number': MeaningIssueType.number,
        'date': MeaningIssueType.number,
        'tense': MeaningIssueType.tense,
        'wrong-tense': MeaningIssueType.tense,
        'mistranslation': MeaningIssueType.mistranslation,
        'false friend': MeaningIssueType.mistranslation,
        'terminology': MeaningIssueType.mistranslation,
        'other': MeaningIssueType.other,
        'something else': MeaningIssueType.other,
      };
      for (final MapEntry(key: raw, value: type) in expected.entries) {
        final check = parse({
          'verdict': 'minor',
          'issues': [issue('cats', 'chats', type: raw)],
        });
        expect(check.issues.single.type, type, reason: raw);
      }
    });

    group('dropped issues', () {
      test('spans that are not in the text drop the issue', () {
        final check = parse({
          'verdict': 'major',
          'issues': [
            issue('the dogs', 'les'),
            issue('3', 'les 3 chiens'),
            issue('', ''),
            issue('(none)', '[none]'),
            issue('cats', 'chats'),
          ],
        });
        expect(spans(check), [('cats', 'chats')]);
      });

      test('a dropped issue does not move the cursors', () {
        const source = 'a b a b';
        final check = parse(
          {
            'verdict': 'major',
            'issues': [
              issue('b', 'zzz', problem: 'dropped'),
              issue('a', 'x', problem: 'kept'),
            ],
          },
          source: source,
          translation: 'x y x y',
        );
        expect(check.issues.single.sourceStart, 0);
        expect(check.issues.single.translationStart, 0);
      });

      test('issues without a problem, and items that are not objects', () {
        final check = parse({
          'verdict': 'major',
          'issues': [
            issue('3', '2', problem: '  '),
            {'source_span': 'did', 'translation_span': 'ai'},
            'The negation is lost.',
            42,
            null,
            ['3', '2'],
            issue('cats', 'chats'),
          ],
        });
        expect(spans(check), [('cats', 'chats')]);
      });
    });

    group('verdict', () {
      MeaningVerdict verdictOf(Object? verdict, {bool withIssue = false}) =>
          parse({
            'back_translation': 'x',
            'verdict': verdict,
            'issues': [if (withIssue) issue('cats', 'chats')],
          }).verdict;

      test('reads the three verdicts and common synonyms', () {
        final expected = <String, MeaningVerdict>{
          'same': MeaningVerdict.same,
          ' SAME ': MeaningVerdict.same,
          'Identical': MeaningVerdict.same,
          'equivalent.': MeaningVerdict.same,
          'no differences': MeaningVerdict.same,
          'minor': MeaningVerdict.minor,
          'Minor differences': MeaningVerdict.minor,
          'slight': MeaningVerdict.minor,
          'major': MeaningVerdict.major,
          'MAJOR!': MeaningVerdict.major,
          'significant': MeaningVerdict.major,
          'different': MeaningVerdict.major,
          'major-issues': MeaningVerdict.major,
        };
        for (final MapEntry(key: raw, value: verdict) in expected.entries) {
          expect(verdictOf(raw), verdict, reason: raw);
        }
      });

      test('defaults to same on garbage without issues', () {
        for (final garbage in <Object?>[
          'banana',
          '',
          42,
          true,
          null,
          ['x'],
        ]) {
          expect(verdictOf(garbage), MeaningVerdict.same, reason: '$garbage');
        }
      });

      test('defaults to minor on garbage with issues', () {
        for (final garbage in <Object?>['banana', 3, null]) {
          expect(
            verdictOf(garbage, withIssue: true),
            MeaningVerdict.minor,
            reason: '$garbage',
          );
        }
      });

      test('same with issues becomes minor; major stays without issues', () {
        expect(verdictOf('same', withIssue: true), MeaningVerdict.minor);
        expect(verdictOf('major'), MeaningVerdict.major);
        expect(verdictOf('minor'), MeaningVerdict.minor);
      });

      test('is read from alternative keys', () {
        expect(
          parse(const {'result': 'major', 'issues': <Object>[]}).verdict,
          MeaningVerdict.major,
        );
        expect(
          parse(const {'assessment': 'minor'}).verdict,
          MeaningVerdict.minor,
        );
      });

      test('reads more synonyms', () {
        final expected = <String, MeaningVerdict>{
          'Substantial': MeaningVerdict.major,
          'changed': MeaningVerdict.major,
          'meaning changed': MeaningVerdict.major,
          'slightly different': MeaningVerdict.minor,
          'mostly-equivalent': MeaningVerdict.minor,
          // Ambiguous under `rating` (a high rating is good).
          'high': MeaningVerdict.same,
          'low': MeaningVerdict.same,
        };
        for (final MapEntry(key: raw, value: verdict) in expected.entries) {
          expect(verdictOf(raw), verdict, reason: raw);
        }
      });

      group('when the model listed differences', () {
        const source = 'I will not come on Monday.';
        const translation = 'Ich komme am Montag.';

        MeaningCheck check(Object? verdict, List<Object?> issues) => parse(
          {
            'back_translation': 'I come on Monday.',
            'verdict': verdict,
            'issues': issues,
          },
          source: source,
          translation: translation,
        );

        /// An issue whose spans paraphrase the texts, so that it cannot be
        /// located.
        Map<String, Object?> paraphrased({String? type}) => issue(
          'the negative part',
          'the verb',
          type: type,
          problem: 'The negation is lost.',
        );

        test('a missing verdict is never same, even when the issues '
            'cannot be located', () {
          for (final verdict in <Object?>[null, 'banana', 7]) {
            final result = check(verdict, [paraphrased()]);
            expect(
              result,
              const MeaningCheck(
                verdict: MeaningVerdict.minor,
                backTranslation: 'I come on Monday.',
              ),
              reason: '$verdict',
            );
          }
          expect(
            check(null, [paraphrased(type: 'negation')]).verdict,
            MeaningVerdict.major,
          );
        });

        test('same with differences it cannot locate is not same', () {
          expect(check('same', [paraphrased()]).verdict, MeaningVerdict.minor);
          expect(
            check('same', [paraphrased(type: 'negation')]).verdict,
            MeaningVerdict.major,
          );
        });

        test('without a verdict, issues without spans count too', () {
          expect(
            check(null, [
              {'problem': 'The negation is lost.'},
            ]).verdict,
            MeaningVerdict.minor,
          );
          expect(
            check(null, ['The negation is lost.']).verdict,
            MeaningVerdict.minor,
          );
          expect(
            check(null, [
              {'type': 'negation', 'problem': 'The negation is lost.'},
            ]).verdict,
            MeaningVerdict.major,
          );
        });

        test('placeholders are not differences', () {
          for (final verdict in <Object?>[null, 'same']) {
            final result = check(verdict, [
              '',
              'None',
              '(none)',
              {'source_span': 'not', 'translation_span': '', 'problem': ' '},
              {'source_span': 'the verb', 'type': 'negation'},
              const <String, Object?>{},
              42,
            ]);
            expect(result.verdict, MeaningVerdict.same, reason: '$verdict');
          }
        });

        test('same keeps span-less filler items', () {
          // A copy of the prompt's example, or a "no differences" note.
          expect(
            check('same', [
              issue('...', '...', type: 'omission', problem: '...'),
              {'type': 'other', 'problem': 'No differences.'},
              'No differences.',
            ]).verdict,
            MeaningVerdict.same,
          );
        });

        test('differences that change the facts make it major', () {
          const majorTypes = [
            'negation',
            'polarity',
            'number',
            'date',
            'omission',
            'missing',
          ];
          const minorTypes = [
            'addition',
            'tense',
            'mistranslation',
            'other',
            'odd',
          ];
          for (final verdict in <Object?>[null, 'banana', 'same']) {
            for (final type in majorTypes) {
              expect(
                check(verdict, [
                  issue('Monday', 'Montag', type: 'tense', problem: 'A'),
                  issue('not', '', type: type, problem: 'B'),
                ]).verdict,
                MeaningVerdict.major,
                reason: '$verdict $type',
              );
              // Also when the issue cannot be located.
              expect(
                check(verdict, [paraphrased(type: type)]).verdict,
                MeaningVerdict.major,
                reason: '$verdict $type (unlocated)',
              );
            }
            for (final type in minorTypes) {
              expect(
                check(verdict, [
                  issue('come', 'komme', type: type, problem: 'A'),
                  paraphrased(type: type),
                ]).verdict,
                MeaningVerdict.minor,
                reason: '$verdict $type',
              );
            }
          }
        });

        test('an inferred omission is major, an inferred addition minor', () {
          expect(
            check(null, [issue('not', '', problem: 'Lost.')]).verdict,
            MeaningVerdict.major,
          );
          expect(
            check(null, [paraphrased()..['translation_span'] = '']).verdict,
            MeaningVerdict.major,
          );
          expect(
            check(null, [issue('', 'komme', problem: 'Added.')]).verdict,
            MeaningVerdict.minor,
          );
        });

        test('an explicit minor or major verdict is kept', () {
          expect(
            check('minor', [paraphrased(type: 'negation')]).verdict,
            MeaningVerdict.minor,
          );
          expect(
            check('minor', [issue('not', '', type: 'negation')]).verdict,
            MeaningVerdict.minor,
          );
          expect(check('major', const []).verdict, MeaningVerdict.major);
        });
      });
    });

    group('output shapes', () {
      test('tolerates prose, fences and think blocks', () {
        final check = parse(
          '<think>The 3 became 2.</think>Here is my check:\n```json\n'
          '${jsonEncode({
            'verdict': 'major',
            'issues': [issue('3', '2')],
          })}\n```',
        );
        expect(check.verdict, MeaningVerdict.major);
        expect(spans(check), [('3', '2')]);
      });

      test('reads alternative keys', () {
        final check = parse({
          'backTranslation': 'I saw',
          'verdict': 'major',
          'differences': [
            {
              'source': 'did not see',
              'translation': 'ai vu',
              'category': 'negation',
              'explanation': 'Lost negation.',
              'correction': 'n’ai pas vu',
            },
          ],
        });
        expect(check.backTranslation, 'I saw');
        expect(
          check.issues.single,
          const MeaningIssue(
            problem: 'Lost negation.',
            type: MeaningIssueType.negation,
            sourceSpan: 'did not see',
            translationSpan: 'ai vu',
            suggestion: 'n’ai pas vu',
            sourceStart: 2,
            sourceEnd: 13,
            translationStart: 2,
            translationEnd: 7,
          ),
        );
      });

      test('accepts a bare list of issues', () {
        final check = parse([issue('3', '2'), issue('did not see', 'ai vu')]);
        expect(check.verdict, MeaningVerdict.minor);
        expect(check.backTranslation, isEmpty);
        expect(spans(check), [('3', '2'), ('did not see', 'ai vu')]);
      });

      test('accepts a single issue object', () {
        final check = parse({'verdict': 'major', 'issues': issue('3', '2')});
        expect(spans(check), [('3', '2')]);
      });

      test('unwraps a check wrapped in an object of its own', () {
        for (final key in ['result', 'meaning_check']) {
          final check = parse({
            key: {
              'verdict': 'major',
              'issues': [issue('3', '2')],
            },
          });
          expect(check.verdict, MeaningVerdict.major, reason: key);
          expect(spans(check), [('3', '2')], reason: key);
        }
        expect(parse(const {'result': 'major'}).verdict, MeaningVerdict.major);
        expect(spans(parse({'issues': issue('3', '2')})), [('3', '2')]);
        expect(
          () => parse(const {
            'wrapper': {'foo': 1},
          }),
          throwsFormatException,
        );
      });

      group('a check wrapped in an array', () {
        test('is unwrapped', () {
          const source = 'I will not come on Monday.';
          const translation = 'Ich komme am Montag.';
          final check = parse(
            [
              {
                'back_translation': 'I come on Monday.',
                'verdict': 'major',
                'issues': [
                  issue(
                    'not',
                    '',
                    type: 'negation',
                    problem: 'The negation is lost.',
                  ),
                ],
              },
            ],
            source: source,
            translation: translation,
          );
          expect(
            check,
            const MeaningCheck(
              verdict: MeaningVerdict.major,
              backTranslation: 'I come on Monday.',
              issues: [
                MeaningIssue(
                  problem: 'The negation is lost.',
                  type: MeaningIssueType.negation,
                  sourceSpan: 'not',
                  sourceStart: 7,
                  sourceEnd: 10,
                ),
              ],
            ),
          );
        });

        test('is unwrapped without issues, or with a note on its verdict', () {
          expect(
            parse(const [
              {'back_translation': 'I saw the cats.', 'verdict': 'same'},
            ]),
            const MeaningCheck(
              verdict: MeaningVerdict.same,
              backTranslation: 'I saw the cats.',
            ),
          );
          expect(
            parse(const [
              {'verdict': 'minor', 'explanation': 'A nuance is lost.'},
            ]).verdict,
            MeaningVerdict.minor,
          );
          expect(
            parse(const [
              {
                'result': {'verdict': 'major', 'back_translation': 'I saw.'},
              },
            ]),
            const MeaningCheck(
              verdict: MeaningVerdict.major,
              backTranslation: 'I saw.',
            ),
          );
        });

        test('several checks are merged', () {
          final check = parse([
            const {
              'back_translation': 'I did not see',
              'verdict': 'same',
              'issues': <Object>[],
            },
            {
              'back_translation': ['the 2 cats.'],
              'verdict': 'major',
              'issues': [issue('3', '2', type: 'number')],
            },
            const {'verdict': 'minor', 'issues': <Object>[]},
            issue('cats', 'chats', problem: 'Listed beside the checks.'),
          ]);
          expect(check.verdict, MeaningVerdict.major);
          expect(check.backTranslation, 'I did not see\nthe 2 cats.');
          expect(spans(check), [('3', '2'), ('cats', 'chats')]);
        });

        test('the most severe verdict wins; same with issues is not '
            'same', () {
          expect(
            parse([
              const {'verdict': 'minor', 'back_translation': 'a'},
              const {'verdict': 'same', 'back_translation': 'b'},
            ]).verdict,
            MeaningVerdict.minor,
          );
          expect(
            parse([
              const {'verdict': 'same', 'back_translation': 'a'},
              issue('3', '2', type: 'number'),
            ]).verdict,
            MeaningVerdict.major,
          );
        });

        test('issues are not mistaken for checks', () {
          final check = parse([
            {...issue('3', '2', type: 'number'), 'severity': 'major'},
            {
              ...issue('cats', 'chats', problem: 'Other.'),
              'verdict': 'minor',
              'back_translation': 'cats',
            },
            const {
              'type': 'negation',
              'rating': 'high',
              'problem': 'The negation is lost.',
            },
          ]);
          expect(spans(check), [('3', '2'), ('cats', 'chats')]);
          expect(check.backTranslation, isEmpty);
          // No verdict: the number issue makes it major.
          expect(check.verdict, MeaningVerdict.major);
        });
      });

      test('ignores issues that are not a list', () {
        final check = parse(const {'verdict': 'major', 'issues': 'many'});
        expect(check.issues, isEmpty);
        expect(check.verdict, MeaningVerdict.major);
      });

      test('a back-translation alone is a check', () {
        final check = parse(const {'back_translation': 'I saw the cats.'});
        expect(
          check,
          const MeaningCheck(
            verdict: MeaningVerdict.same,
            backTranslation: 'I saw the cats.',
          ),
        );
      });

      test('throws a FormatException on output that is not a check', () {
        for (final output in [
          'The translation looks fine to me.',
          '{}',
          '{"foo": 1, "bar": [1, 2]}',
          '{"verdict": null, "issues": null, "back_translation": null}',
          '',
        ]) {
          expect(
            () => ResponseParsers.parseMeaningCheck(
              output,
              source: source,
              translation: translation,
            ),
            throwsFormatException,
            reason: output,
          );
        }
      });
    });

    group('sanitising', () {
      test('problems and suggestions become single lines', () {
        final check = parse({
          'verdict': 'major',
          'issues': [
            issue(
              'cats',
              'chats',
              problem: '  Wrong\nanimal\u202E;\x07 see\t below  ',
              suggestion: 'chiens\r\n<b>!</b>',
            ),
          ],
        });
        expect(check.issues.single.problem, 'Wrong animal; see below');
        expect(check.issues.single.suggestion, 'chiens <b>!</b>');
      });

      test('drops empty suggestions and ones equal to the span', () {
        final check = parse({
          'verdict': 'major',
          'issues': [
            issue('3', '2', problem: 'A', suggestion: '2'),
            issue('cats', 'chats', problem: 'B', suggestion: 'None'),
            issue('did', 'ai', problem: 'C', suggestion: ' - '),
            issue('not', 'vu', problem: 'D'),
          ],
        });
        expect(check.issues.map((i) => i.suggestion), everyElement(isEmpty));
        expect(check.issues, hasLength(4));
      });

      test('the back-translation keeps its lines', () {
        final check = parse({
          'verdict': 'same',
          'back_translation':
              '  Line one\r\nLine\u202E two\x07\rLine\u2028three\n\n'
              'Tab\there <${zwsp}source>  ',
        });
        expect(
          check.backTranslation,
          'Line one\nLine two\nLine\nthree\n\nTab\there <source>',
        );
      });

      test('a back-translation given as lines is joined', () {
        final check = parse(const {
          'verdict': 'same',
          'back_translation': ['First.', ' Second. ', 3],
        });
        expect(check.backTranslation, 'First.\nSecond.\n3');
      });
    });

    group('size caps', () {
      test('keeps at most maxMeaningIssues issues', () {
        final words = [for (var i = 0; i < 30; i++) 'w$i'];
        final targets = [for (var i = 0; i < 30; i++) 't$i'];
        final check = parse(
          {
            'verdict': 'major',
            'issues': [
              for (var i = 0; i < 30; i++)
                issue(words[i], targets[i], problem: 'P$i'),
            ],
          },
          source: words.join(' '),
          translation: targets.join(' '),
        );
        expect(check.issues, hasLength(TranslationPrompts.maxMeaningIssues));
        expect(check.issues.last.problem, 'P19');
      });

      test('reads at most 100 items', () {
        final check = parse({
          'verdict': 'major',
          'issues': [
            for (var i = 0; i < 100; i++) issue('absent', 'absent'),
            issue('cats', 'chats'),
          ],
        });
        expect(check.issues, isEmpty);
        expect(check.verdict, MeaningVerdict.major);
      });

      test('caps problems, suggestions and the back-translation', () {
        final check = parse({
          'verdict': 'major',
          'back_translation': 'b' * 9000,
          'issues': [
            issue(
              'cats',
              'chats',
              problem: 'word ' * 100,
              suggestion: 'x' * 600,
            ),
          ],
        });
        expect(
          check.backTranslation,
          'b' * ResponseParsers.maxBackTranslationLength,
        );
        expect(ResponseParsers.maxBackTranslationLength, 8000);
        final problem = check.issues.single.problem;
        expect(
          problem.length,
          lessThanOrEqualTo(ResponseParsers.maxMeaningProblemLength),
        );
        expect(ResponseParsers.maxMeaningProblemLength, 300);
        expect(problem, endsWith('word'));
        expect(
          check.issues.single.suggestion,
          'x' * ResponseParsers.maxMeaningSuggestionLength,
        );
        expect(ResponseParsers.maxMeaningSuggestionLength, 500);
      });

      test('searches only the beginnings the prompt sent', () {
        final longSource = '${'a ' * 2500}tail';
        final check = parse({
          'verdict': 'major',
          'issues': [
            issue('tail', 'chats', problem: 'beyond the cut'),
            issue('a', 'chats', problem: 'within'),
          ],
        }, source: longSource);
        expect(check.issues.map((i) => i.problem), ['within']);
        expect(check.isPartial, isTrue);
      });

      test('isPartial tells whether either text was cut', () {
        final full = 'y' * TranslationPrompts.maxMeaningCheckChars;
        const json = {'verdict': 'same'};
        expect(parse(json).isPartial, isFalse);
        expect(parse(json, source: full, translation: full).isPartial, isFalse);
        expect(parse(json, source: '${full}y').isPartial, isTrue);
        expect(parse(json, translation: '${full}y').isPartial, isTrue);
      });
    });
  });
}
