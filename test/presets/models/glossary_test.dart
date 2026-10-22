import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/presets/models/glossary.dart';

void main() {
  group('LanguageScope', () {
    test('isAny and normalize', () {
      expect(LanguageScope.isAny('any'), isTrue);
      expect(LanguageScope.isAny(' ANY '), isTrue);
      expect(LanguageScope.isAny('*'), isTrue);
      expect(LanguageScope.isAny(''), isTrue);
      expect(LanguageScope.isAny('en'), isFalse);
      expect(LanguageScope.normalize(''), LanguageScope.any);
      expect(LanguageScope.normalize(' de '), 'de');
    });

    test('matches', () {
      expect(LanguageScope.matches('any', 'de'), isTrue);
      expect(LanguageScope.matches('de', 'de'), isTrue);
      expect(LanguageScope.matches('DE', 'de'), isTrue);
      expect(LanguageScope.matches('pt_BR', 'pt-br'), isTrue);
      expect(LanguageScope.matches('de', 'fr'), isFalse);
      // Unknown query languages match every scope.
      expect(LanguageScope.matches('de', 'auto'), isTrue);
      expect(LanguageScope.matches('de', ''), isTrue);
      expect(LanguageScope.matches('de', 'any'), isTrue);
      // Aliases and normalisation.
      expect(LanguageScope.matches('he', 'iw'), isTrue);
      expect(LanguageScope.matches('fr', 'fr-FR'), isTrue);
      // A bare language matches its regional variants, not vice versa.
      expect(LanguageScope.matches('pt', 'pt-PT'), isTrue);
      expect(LanguageScope.matches('pt-BR', 'pt-PT'), isFalse);
      expect(LanguageScope.matches('en-GB', 'en'), isFalse);
    });
  });

  group('GlossaryTerm', () {
    const term = GlossaryTerm(
      source: 'API',
      target: 'API',
      note: 'keep',
      caseSensitive: true,
    );

    test('round-trips through JSON', () {
      expect(GlossaryTerm.fromJson(term.toJson()), term);
      const minimal = GlossaryTerm(source: 'a', target: 'b');
      expect(minimal.toJson(), {'source': 'a', 'target': 'b'});
      expect(GlossaryTerm.fromJson(minimal.toJson()), minimal);
    });

    test('fromJson is tolerant but needs source and target', () {
      expect(
        GlossaryTerm.fromJson(const {
          'source': 'a',
          'target': 'b',
          'note': 3,
          'caseSensitive': 'true',
        }),
        const GlossaryTerm(source: 'a', target: 'b', caseSensitive: true),
      );
      expect(
        () => GlossaryTerm.fromJson(const {'source': 'a'}),
        throwsFormatException,
      );
    });

    test('isValid and trimmed', () {
      expect(term.isValid, isTrue);
      expect(const GlossaryTerm(source: ' ', target: 'x').isValid, isFalse);
      expect(const GlossaryTerm(source: 'x', target: '').isValid, isFalse);
      expect(
        const GlossaryTerm(source: ' a ', target: ' b ', note: ' n ').trimmed(),
        const GlossaryTerm(source: 'a', target: 'b', note: 'n'),
      );
    });

    test('sameSourceAs respects case sensitivity', () {
      const lower = GlossaryTerm(source: 'api', target: 'x');
      const upperSensitive = GlossaryTerm(
        source: 'API',
        target: 'y',
        caseSensitive: true,
      );
      const lowerSensitive = GlossaryTerm(
        source: ' api',
        target: 'y',
        caseSensitive: true,
      );
      expect(lower.sameSourceAs(upperSensitive), isTrue);
      expect(upperSensitive.sameSourceAs(lowerSensitive), isFalse);
      expect(lowerSensitive.sameSourceAs(lowerSensitive), isTrue);
    });

    test('copyWith', () {
      expect(
        term.copyWith(target: 'Schnittstelle', caseSensitive: false),
        const GlossaryTerm(
          source: 'API',
          target: 'Schnittstelle',
          note: 'keep',
        ),
      );
      expect(term.copyWith(source: 'x', note: ''), isNot(term));
    });
  });

  group('mergeTerms', () {
    test('adds, updates in place and skips invalid terms', () {
      const existing = [
        GlossaryTerm(source: 'cat', target: 'Katze'),
        GlossaryTerm(source: 'dog', target: 'Hund'),
      ];
      final merge = mergeTerms(existing, const [
        GlossaryTerm(source: ' Cat ', target: 'Kater'),
        GlossaryTerm(source: 'dog', target: 'Hund'),
        GlossaryTerm(source: 'bird', target: 'Vogel'),
        GlossaryTerm(source: '', target: 'x'),
      ]);
      expect(merge.added, 1);
      expect(merge.updated, 1);
      expect(merge.terms, const [
        GlossaryTerm(source: 'Cat', target: 'Kater'),
        GlossaryTerm(source: 'dog', target: 'Hund'),
        GlossaryTerm(source: 'bird', target: 'Vogel'),
      ]);
    });
  });

  group('Glossary', () {
    const glossary = Glossary(
      id: 'g1',
      name: 'Tech',
      sourceCode: 'en',
      targetCode: 'de',
      enabled: false,
      terms: [GlossaryTerm(source: 'cloud', target: 'Cloud')],
    );

    test('round-trips through JSON', () {
      final json = glossary.toJson();
      expect(json['source'], 'en');
      expect(json['target'], 'de');
      expect(Glossary.fromJson(json), glossary);
    });

    test('fromJson is tolerant', () {
      final parsed = Glossary.fromJson(const {
        'id': 'g2',
        'name': null,
        'sourceCode': 'fr',
        'enabled': 'yes',
        'terms': [
          {'source': 'a', 'target': 'b'},
          {'source': 'missing target'},
          {'source': ' ', 'target': 'x'},
          'garbage',
        ],
      });
      expect(parsed.name, isEmpty);
      expect(parsed.sourceCode, 'fr');
      expect(parsed.targetCode, LanguageScope.any);
      expect(parsed.enabled, isTrue);
      expect(parsed.terms, const [GlossaryTerm(source: 'a', target: 'b')]);
      expect(
        Glossary.fromJson(const {'id': 'g3', 'terms': 'x'}).terms,
        isEmpty,
      );
    });

    test('fromJson throws without an id', () {
      expect(
        () => Glossary.fromJson(const {'name': 'x'}),
        throwsFormatException,
      );
    });

    test('matches and specificity', () {
      expect(glossary.matches(sourceCode: 'en', targetCode: 'de'), isTrue);
      expect(glossary.matches(sourceCode: 'auto', targetCode: 'de'), isTrue);
      expect(glossary.matches(sourceCode: 'en', targetCode: 'fr'), isFalse);
      expect(glossary.specificity, 2);
      expect(const Glossary(id: 'x', targetCode: 'de').specificity, 1);
      expect(const Glossary(id: 'x').specificity, 0);
    });

    test('copyWith normalises scopes', () {
      final copy = glossary.copyWith(
        name: 'New',
        sourceCode: '',
        targetCode: ' fr ',
        enabled: true,
        terms: const [],
        id: 'g9',
      );
      expect(copy.id, 'g9');
      expect(copy.name, 'New');
      expect(copy.sourceCode, LanguageScope.any);
      expect(copy.targetCode, 'fr');
      expect(copy.enabled, isTrue);
      expect(copy.terms, isEmpty);
      expect(glossary.copyWith(), glossary);
    });
  });

  group('mergeActiveGlossaries', () {
    Glossary g(
      String id, {
      required List<GlossaryTerm> terms,
      String source = 'any',
      String target = 'any',
      bool enabled = true,
    }) => Glossary(
      id: id,
      sourceCode: source,
      targetCode: target,
      enabled: enabled,
      terms: terms,
    );

    test('merges enabled matching glossaries', () {
      final result = mergeActiveGlossaries(
        [
          g(
            'any',
            terms: const [GlossaryTerm(source: 'hi', target: 'hallo')],
          ),
          g(
            'pair',
            source: 'en',
            target: 'de',
            terms: const [GlossaryTerm(source: ' cat ', target: ' Katze ')],
          ),
          g(
            'other',
            source: 'en',
            target: 'fr',
            terms: const [GlossaryTerm(source: 'dog', target: 'chien')],
          ),
          g(
            'off',
            enabled: false,
            terms: const [GlossaryTerm(source: 'off', target: 'aus')],
          ),
          g(
            'invalid',
            terms: const [GlossaryTerm(source: 'x', target: ' ')],
          ),
        ],
        sourceCode: 'en',
        targetCode: 'de',
      );
      expect(result, {'cat': 'Katze', 'hi': 'hallo'});
    });

    test('mergeActiveGlossaryTerms also names the case-sensitive terms', () {
      final result = mergeActiveGlossaryTerms(
        [
          g(
            'terms',
            terms: const [
              GlossaryTerm(source: 'IT', target: 'TI', caseSensitive: true),
              GlossaryTerm(source: 'cat', target: 'Katze'),
            ],
          ),
        ],
        sourceCode: 'en',
        targetCode: 'de',
      );
      expect(result.terms, {'IT': 'TI', 'cat': 'Katze'});
      expect(result.caseSensitive, {'IT'});
    });

    test('more specific glossaries win, then list order', () {
      final result = mergeActiveGlossaries(
        [
          g(
            'any',
            terms: const [GlossaryTerm(source: 'bank', target: 'A')],
          ),
          g(
            'target',
            target: 'de',
            terms: const [GlossaryTerm(source: 'Bank', target: 'B')],
          ),
          g(
            'pair1',
            source: 'en',
            target: 'de',
            terms: const [GlossaryTerm(source: 'BANK', target: 'C')],
          ),
          g(
            'pair2',
            source: 'en',
            target: 'de',
            terms: const [GlossaryTerm(source: 'bank', target: 'D')],
          ),
        ],
        sourceCode: 'en',
        targetCode: 'de',
      );
      expect(result, {'BANK': 'C'});
    });

    test('case-sensitive terms only conflict on exact matches', () {
      final result = mergeActiveGlossaries(
        [
          g(
            'a',
            terms: const [
              GlossaryTerm(source: 'US', target: 'USA', caseSensitive: true),
              GlossaryTerm(source: 'us', target: 'uns', caseSensitive: true),
              GlossaryTerm(source: 'US', target: 'dup', caseSensitive: true),
            ],
          ),
          g(
            'b',
            terms: const [
              // Conflicts with both case-sensitive terms (case-insensitive).
              GlossaryTerm(source: 'Us', target: 'x'),
            ],
          ),
        ],
        sourceCode: 'en',
        targetCode: 'de',
      );
      expect(result, {'US': 'USA', 'us': 'uns'});

      final insensitiveFirst = mergeActiveGlossaries(
        [
          g(
            'a',
            terms: const [GlossaryTerm(source: 'web', target: 'Web')],
          ),
          g(
            'b',
            terms: const [
              GlossaryTerm(source: 'WEB', target: 'X', caseSensitive: true),
            ],
          ),
        ],
        sourceCode: 'en',
        targetCode: 'de',
      );
      expect(insensitiveFirst, {'web': 'Web'});
    });

    test('empty input', () {
      expect(
        mergeActiveGlossaries(const [], sourceCode: 'en', targetCode: 'de'),
        isEmpty,
      );
    });
  });

  group('Glossary change time', () {
    final at = DateTime.utc(2026, 10, 20, 9, 30);
    final stamped = Glossary(
      id: 'g',
      name: 'Tech',
      terms: const [GlossaryTerm(source: 'cloud', target: 'Cloud')],
      updatedAt: at,
    );

    test('is written (UTC) only when there is one', () {
      expect(const Glossary(id: 'g').toJson(), isNot(contains('updatedAt')));
      expect(
        Glossary(id: 'g', updatedAt: at.toLocal()).toJson()['updatedAt'],
        '2026-10-20T09:30:00.000Z',
      );
    });

    test('is read back; invalid or missing ones are none', () {
      expect(Glossary.fromJson(stamped.toJson()).updatedAt, at);
      expect(
        Glossary.fromJson(const {'id': 'g', 'updatedAt': 'x'}).updatedAt,
        isNull,
      );
      expect(Glossary.fromJson(const {'id': 'g'}).updatedAt, isNull);
    });

    test('modifiedAt falls back to the epoch', () {
      expect(stamped.modifiedAt, at);
      expect(const Glossary(id: 'g').modifiedAt, DateTime.utc(1970));
    });

    test('is not part of equality', () {
      expect(stamped, stamped.withoutChangeTime());
      expect(stamped.withoutChangeTime().updatedAt, isNull);
      expect(stamped.withoutChangeTime().terms, stamped.terms);
      const plain = Glossary(id: 'g');
      expect(identical(plain.withoutChangeTime(), plain), isTrue);
    });

    test('copyWith keeps or sets it', () {
      final later = at.add(const Duration(days: 1));
      expect(stamped.copyWith(name: 'x').updatedAt, at);
      expect(stamped.copyWith(updatedAt: later).updatedAt, later);
    });
  });
}
