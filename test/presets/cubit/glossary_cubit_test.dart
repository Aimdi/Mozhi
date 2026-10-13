import 'dart:convert';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/presets/cubit/glossary_cubit.dart';
import 'package:mozhi/presets/data/glossary_repository.dart';
import 'package:mozhi/presets/models/glossary.dart';

class _MockStore extends Mock implements KeyValueStore {}

const _cat = GlossaryTerm(source: 'cat', target: 'Katze');
const _dog = GlossaryTerm(source: 'dog', target: 'Hund');
const _bird = GlossaryTerm(source: 'bird', target: 'Vogel');

const _pets = Glossary(
  id: 'pets',
  name: 'Pets',
  sourceCode: 'en',
  targetCode: 'de',
  terms: [_cat, _dog],
);
const _any = Glossary(id: 'any', name: 'Any', terms: [_bird]);

GlossaryState _ready(List<Glossary> glossaries) =>
    GlossaryState(status: GlossaryStatus.ready, glossaries: glossaries);

void main() {
  late MemoryStore store;
  late GlossaryRepository repository;
  late int counter;

  setUp(() {
    store = MemoryStore();
    counter = 0;
    repository = GlossaryRepository(
      store: store,
      generateId: () => 'new${counter++}',
    );
  });

  List<Glossary> stored() => GlossaryRepository.parseGlossaries(
    jsonDecode(store.values[GlossaryRepository.storageKey]!),
  )!;

  GlossaryCubit build() => GlossaryCubit(repository: repository);

  group('GlossaryCubit', () {
    test('defaults to an empty initial state', () {
      expect(GlossaryCubit().state, const GlossaryState());
    });

    blocTest<GlossaryCubit, GlossaryState>(
      'load emits loading then the stored glossaries',
      setUp: () => store.values[GlossaryRepository.storageKey] = jsonEncode(
        GlossaryRepository.encode(const [_pets]),
      ),
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        const GlossaryState(status: GlossaryStatus.loading),
        _ready(const [_pets]),
      ],
    );

    blocTest<GlossaryCubit, GlossaryState>(
      'load emits failure on storage errors',
      build: () {
        final failing = _MockStore();
        when(() => failing.read(any())).thenThrow(StateError('io'));
        return GlossaryCubit(repository: GlossaryRepository(store: failing));
      },
      act: (cubit) => cubit.load(),
      expect: () => [
        const GlossaryState(status: GlossaryStatus.loading),
        const GlossaryState(status: GlossaryStatus.failure),
      ],
      errors: () => [isA<StateError>()],
    );

    blocTest<GlossaryCubit, GlossaryState>(
      'create appends a normalised glossary',
      build: build,
      seed: () => _ready(const [_any]),
      act: (cubit) async {
        final created = await cubit.create(
          name: ' Food ',
          sourceCode: 'en',
          targetCode: '',
          terms: const [
            GlossaryTerm(source: ' bread ', target: 'Brot'),
            GlossaryTerm(source: '', target: 'x'),
          ],
        );
        expect(created.id, 'new0');
        expect(stored(), hasLength(2));
      },
      expect: () => [
        _ready(const [
          _any,
          Glossary(
            id: 'new0',
            name: 'Food',
            sourceCode: 'en',
            terms: [GlossaryTerm(source: 'bread', target: 'Brot')],
          ),
        ]),
      ],
    );

    blocTest<GlossaryCubit, GlossaryState>(
      'save, rename, setScope and setEnabled update one glossary',
      build: build,
      seed: () => _ready(const [_pets, _any]),
      act: (cubit) async {
        await cubit.save(_pets.copyWith(name: ' Animals '));
        await cubit.rename('any', 'General');
        await cubit.setScope('any', sourceCode: 'fr', targetCode: 'it');
        await cubit.setEnabled('pets', enabled: false);
        // Unknown ids and unchanged values do not emit.
        await cubit.rename('zz', 'x');
        await cubit.setEnabled('pets', enabled: false);
      },
      expect: () => [
        _ready([_pets.copyWith(name: 'Animals'), _any]),
        _ready([
          _pets.copyWith(name: 'Animals'),
          _any.copyWith(name: 'General'),
        ]),
        _ready([
          _pets.copyWith(name: 'Animals'),
          _any.copyWith(name: 'General', sourceCode: 'fr', targetCode: 'it'),
        ]),
        _ready([
          _pets.copyWith(name: 'Animals', enabled: false),
          _any.copyWith(name: 'General', sourceCode: 'fr', targetCode: 'it'),
        ]),
      ],
    );

    blocTest<GlossaryCubit, GlossaryState>(
      'delete and restore',
      build: build,
      seed: () => _ready(const [_pets, _any]),
      act: (cubit) async {
        await cubit.delete('pets');
        await cubit.delete('zz');
        await cubit.restore(_pets, index: 5);
      },
      expect: () => [
        _ready(const [_any]),
        _ready(const [_any, _pets]),
      ],
    );

    blocTest<GlossaryCubit, GlossaryState>(
      'move reorders and ignores invalid indexes',
      build: build,
      seed: () => _ready(const [_pets, _any]),
      act: (cubit) async {
        await cubit.move(0, 1);
        await cubit.move(0, 0);
        await cubit.move(0, 2);
        await cubit.move(-1, 0);
      },
      expect: () => [
        _ready(const [_any, _pets]),
      ],
    );

    blocTest<GlossaryCubit, GlossaryState>(
      'addTerm appends or replaces the term with the same source',
      build: build,
      seed: () => _ready(const [_pets]),
      act: (cubit) async {
        await cubit.addTerm('pets', _bird);
        await cubit.addTerm(
          'pets',
          const GlossaryTerm(source: 'CAT', target: 'Kater'),
        );
        await cubit.addTerm('pets', const GlossaryTerm(source: '', target: ''));
      },
      expect: () => [
        _ready([
          _pets.copyWith(terms: const [_cat, _dog, _bird]),
        ]),
        _ready([
          _pets.copyWith(
            terms: const [
              GlossaryTerm(source: 'CAT', target: 'Kater'),
              _dog,
              _bird,
            ],
          ),
        ]),
      ],
    );

    blocTest<GlossaryCubit, GlossaryState>(
      'updateTerm replaces in place and removes duplicates',
      build: build,
      seed: () => _ready([
        _pets.copyWith(terms: const [_cat, _dog, _bird]),
      ]),
      act: (cubit) async {
        await cubit.updateTerm(
          'pets',
          2,
          const GlossaryTerm(source: ' Dog ', target: 'Hündchen'),
        );
        await cubit.updateTerm('pets', 9, _bird);
        await cubit.updateTerm(
          'pets',
          0,
          const GlossaryTerm(source: '', target: 'x'),
        );
      },
      expect: () => [
        _ready([
          _pets.copyWith(
            terms: const [
              _cat,
              GlossaryTerm(source: 'Dog', target: 'Hündchen'),
            ],
          ),
        ]),
      ],
    );

    blocTest<GlossaryCubit, GlossaryState>(
      'removeTerm and insertTerm',
      build: build,
      seed: () => _ready(const [_pets]),
      act: (cubit) async {
        await cubit.removeTerm('pets', 0);
        await cubit.removeTerm('pets', 7);
        await cubit.insertTerm('pets', 0, _cat);
        await cubit.insertTerm('pets', 99, _bird);
        await cubit.insertTerm(
          'pets',
          0,
          const GlossaryTerm(source: ' ', target: 'x'),
        );
        await cubit.insertTerm(
          'pets',
          0,
          const GlossaryTerm(source: 'BIRD', target: 'Vöglein'),
        );
      },
      expect: () => [
        _ready([
          _pets.copyWith(terms: const [_dog]),
        ]),
        _ready(const [_pets]),
        _ready([
          _pets.copyWith(terms: const [_cat, _dog, _bird]),
        ]),
        _ready([
          _pets.copyWith(
            terms: const [
              GlossaryTerm(source: 'BIRD', target: 'Vöglein'),
              _cat,
              _dog,
            ],
          ),
        ]),
      ],
    );

    blocTest<GlossaryCubit, GlossaryState>(
      'importTerms merges pasted terms and reports counts',
      build: build,
      seed: () => _ready(const [_pets]),
      act: (cubit) async {
        final result = await cubit.importTerms(
          'pets',
          'source,target\ncat,Kater\nbird,Vogel\nbroken\n',
        );
        expect(result, (added: 1, updated: 1, skipped: 1));
        await expectLater(
          cubit.importTerms('pets', 'nothing'),
          throwsFormatException,
        );
        await expectLater(
          cubit.importTerms('zz', 'a,b'),
          throwsFormatException,
        );
      },
      expect: () => [
        _ready([
          _pets.copyWith(
            terms: const [
              GlossaryTerm(source: 'cat', target: 'Kater'),
              _dog,
              _bird,
            ],
          ),
        ]),
      ],
    );

    blocTest<GlossaryCubit, GlossaryState>(
      'exportTerms and exportJson',
      build: build,
      seed: () => _ready(const [_pets, _any]),
      act: (cubit) {
        expect(
          cubit.exportTerms('pets', GlossaryExportFormat.csv),
          'source,target,note,case_sensitive\n'
          'cat,Katze,,false\n'
          'dog,Hund,,false\n',
        );
        expect(cubit.exportTerms('zz', GlossaryExportFormat.csv), isNull);
        expect(
          GlossaryRepository.parseGlossaries(jsonDecode(cubit.exportJson())),
          const [_pets, _any],
        );
        expect(
          GlossaryRepository.parseGlossaries(
            jsonDecode(cubit.exportJson(ids: {'any'})),
          ),
          const [_any],
        );
      },
      expect: () => <GlossaryState>[],
    );

    blocTest<GlossaryCubit, GlossaryState>(
      'importJson appends glossaries with fresh ids',
      build: build,
      seed: () => _ready(const [_any]),
      act: (cubit) async {
        expect(
          await cubit.importJson(GlossaryRepository.exportJson(const [_pets])),
          1,
        );
        expect(await cubit.importJson('[]'), 0);
        await expectLater(cubit.importJson('{'), throwsFormatException);
      },
      expect: () => [
        _ready([_any, _pets.copyWith(id: 'new0')]),
      ],
    );

    blocTest<GlossaryCubit, GlossaryState>(
      'activeGlossary merges enabled glossaries for the pair',
      build: build,
      seed: () => _ready([_pets, _any.copyWith(enabled: false)]),
      act: (cubit) {
        expect(cubit.activeGlossary(sourceCode: 'en', targetCode: 'de'), {
          'cat': 'Katze',
          'dog': 'Hund',
        });
        expect(
          cubit.activeGlossary(sourceCode: 'en', targetCode: 'fr'),
          isEmpty,
        );
      },
      expect: () => <GlossaryState>[],
    );

    blocTest<GlossaryCubit, GlossaryState>(
      'keeps the new state and reports storage errors on save',
      build: () {
        final failing = _MockStore();
        when(() => failing.write(any(), any())).thenThrow(StateError('io'));
        return GlossaryCubit(repository: GlossaryRepository(store: failing));
      },
      seed: () => _ready(const [_pets]),
      act: (cubit) => cubit.delete('pets'),
      expect: () => [_ready(const [])],
      errors: () => [isA<StateError>()],
    );

    test('does not emit after close', () async {
      final cubit = build();
      await cubit.close();
      await cubit.load();
      await cubit.delete('x');
      expect(cubit.state, const GlossaryState());
    });
  });

  group('GlossaryState', () {
    test('byId and copyWith', () {
      final state = _ready(const [_pets]);
      expect(state.byId('pets'), _pets);
      expect(state.byId('zz'), isNull);
      expect(state.copyWith(), state);
      expect(
        state.copyWith(status: GlossaryStatus.loading, glossaries: const []),
        const GlossaryState(status: GlossaryStatus.loading),
      );
    });
  });
}
