import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/presets/data/glossary_repository.dart';
import 'package:mozhi/presets/models/glossary.dart';

class _FailingOnceStore extends MemoryStore {
  bool _failed = false;

  @override
  Future<void> write(String key, String value) async {
    if (!_failed) {
      _failed = true;
      throw StateError('disk full');
    }
    await super.write(key, value);
  }
}

void main() {
  const tech = Glossary(
    id: 'tech',
    name: 'Tech',
    sourceCode: 'en',
    targetCode: 'de',
    terms: [
      GlossaryTerm(source: 'cloud', target: 'Cloud'),
      GlossaryTerm(source: 'API', target: 'API', caseSensitive: true),
    ],
  );
  const names = Glossary(
    id: 'names',
    name: 'Names',
    terms: [GlossaryTerm(source: 'Mozhi', target: 'Mozhi', note: 'app')],
  );

  group('GlossaryRepository', () {
    late MemoryStore store;
    late GlossaryRepository repository;
    late int counter;

    setUp(() {
      store = MemoryStore();
      counter = 0;
      repository = GlossaryRepository(
        store: store,
        generateId: () => 'id${counter++}',
      );
    });

    test('defaults to the preferences store and random ids', () {
      final defaults = GlossaryRepository();
      expect(defaults.store, isA<PreferencesStore>());
      expect(defaults.newId(), isNot(defaults.newId()));
    });

    test('load is empty without data or with unreadable data', () async {
      expect(await repository.load(), isEmpty);
      store.values[GlossaryRepository.storageKey] = '{broken';
      expect(await repository.load(), isEmpty);
      store.values[GlossaryRepository.storageKey] = '42';
      expect(await repository.load(), isEmpty);
    });

    test('save and load round-trip and update the cache', () async {
      await repository.save(const [tech, names]);
      expect(repository.glossaries, const [tech, names]);
      final raw = jsonDecode(store.values[GlossaryRepository.storageKey]!);
      expect(raw, containsPair('version', GlossaryRepository.version));
      final fresh = GlossaryRepository(store: store);
      expect(fresh.glossaries, isEmpty);
      expect(await fresh.load(), const [tech, names]);
      expect(fresh.glossaries, const [tech, names]);
    });

    test('a failed write does not block later writes', () async {
      final repo = GlossaryRepository(store: _FailingOnceStore());
      await expectLater(repo.save(const [tech]), throwsStateError);
      await repo.save(const [names]);
      expect(await repo.load(), const [names]);
    });

    test('activeGlossary uses the cache', () async {
      await repository.save(const [tech, names]);
      expect(repository.activeGlossary(sourceCode: 'en', targetCode: 'de'), {
        'cloud': 'Cloud',
        'API': 'API',
        'Mozhi': 'Mozhi',
      });
      expect(repository.activeGlossary(sourceCode: 'fr', targetCode: 'de'), {
        'Mozhi': 'Mozhi',
      });
    });

    group('parseGlossaries', () {
      test('accepts documents of any version and bare lists', () {
        expect(
          GlossaryRepository.parseGlossaries(
            GlossaryRepository.encode(const [tech]),
          ),
          const [tech],
        );
        expect(
          GlossaryRepository.parseGlossaries({
            'version': 7,
            'glossaries': [names.toJson()],
          }),
          const [names],
        );
        expect(GlossaryRepository.parseGlossaries([tech.toJson()]), const [
          tech,
        ]);
      });

      test('skips invalid entries and duplicate ids', () {
        expect(
          GlossaryRepository.parseGlossaries([
            tech.toJson(),
            {'name': 'no id'},
            'garbage',
            {...tech.toJson(), 'name': 'dupe'},
          ]),
          const [tech],
        );
      });

      test('returns null for other shapes', () {
        expect(GlossaryRepository.parseGlossaries('x'), isNull);
        expect(GlossaryRepository.parseGlossaries({'glossaries': 1}), isNull);
      });
    });

    group('parseImport', () {
      test('accepts export documents, lists and single glossaries', () {
        final imported = repository.parseImport(
          GlossaryRepository.exportJson(const [tech, names]),
        );
        expect(imported.map((g) => g.id), ['id0', 'id1']);
        expect(imported.first.terms, tech.terms);
        expect(
          repository.parseImport(jsonEncode([names.toJson()])).single.name,
          'Names',
        );
        expect(
          repository.parseImport(jsonEncode(tech.toJson())).single.name,
          'Tech',
        );
        expect(repository.parseImport('[]'), isEmpty);
      });

      test('throws for invalid input', () {
        expect(() => repository.parseImport('x'), throwsFormatException);
        expect(() => repository.parseImport('3'), throwsFormatException);
        expect(() => repository.parseImport('[1]'), throwsFormatException);
        expect(
          () => repository.parseImport('{"glossaries": [{}]}'),
          throwsFormatException,
        );
      });
    });

    group('parseTerms', () {
      test('reads CSV and TSV', () {
        final csv = GlossaryRepository.parseTerms('a,b\n,\nc,d');
        expect(csv.terms, const [
          GlossaryTerm(source: 'a', target: 'b'),
          GlossaryTerm(source: 'c', target: 'd'),
        ]);
        final tsv = GlossaryRepository.parseTerms('x\ty\nonly');
        expect(tsv.terms, const [GlossaryTerm(source: 'x', target: 'y')]);
        expect(tsv.skipped, 1);
      });

      test('reads JSON exports, glossaries and term lists', () {
        final export = GlossaryRepository.parseTerms(
          GlossaryRepository.exportJson(const [tech, names]),
        );
        expect(export.terms, [...tech.terms, ...names.terms]);

        final single = GlossaryRepository.parseTerms(
          jsonEncode({
            'terms': [
              {'source': 'a', 'target': 'b'},
            ],
          }),
        );
        expect(single.terms, const [GlossaryTerm(source: 'a', target: 'b')]);

        final list = GlossaryRepository.parseTerms(
          '  ${jsonEncode([
            {'source': ' a ', 'target': 'b'},
            {'source': 'missing'},
            3,
            {
              'terms': [
                {'source': 'c', 'target': 'd'},
              ],
            },
          ])}',
        );
        expect(list.terms, const [
          GlossaryTerm(source: 'a', target: 'b'),
          GlossaryTerm(source: 'c', target: 'd'),
        ]);
        expect(list.skipped, 2);

        final term = GlossaryRepository.parseTerms(
          '{"source": "x", "target": "y"}',
        );
        expect(term.terms, const [GlossaryTerm(source: 'x', target: 'y')]);
      });

      test('throws when nothing usable is found', () {
        expect(() => GlossaryRepository.parseTerms(''), throwsFormatException);
        expect(
          () => GlossaryRepository.parseTerms('only one column'),
          throwsFormatException,
        );
        expect(
          () => GlossaryRepository.parseTerms('[1, 2]'),
          throwsFormatException,
        );
        expect(
          () => GlossaryRepository.parseTerms('{broken'),
          throwsFormatException,
        );
      });
    });

    test('exportTerms in every format', () {
      final csv = GlossaryRepository.exportTerms(
        tech,
        GlossaryExportFormat.csv,
      );
      expect(csv, startsWith('source,target,note,case_sensitive\n'));
      expect(csv, contains('API,API,,true'));
      final tsv = GlossaryRepository.exportTerms(
        tech,
        GlossaryExportFormat.tsv,
      );
      expect(tsv, contains('cloud\tCloud\t\tfalse'));
      final json = GlossaryRepository.exportTerms(
        tech,
        GlossaryExportFormat.json,
      );
      expect(GlossaryRepository.parseGlossaries(jsonDecode(json)), const [
        tech,
      ]);
      expect(GlossaryExportFormat.json.mimeType, 'application/json');
      expect(GlossaryExportFormat.tsv.extension, 'tsv');
    });
  });
}
