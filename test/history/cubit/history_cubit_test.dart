import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:translation_repository/translation_repository.dart';

class _MockHistoryRepository extends Mock implements HistoryRepository;

HistoryEntry _entry(String id, {bool isFavorite = false}) => HistoryEntry(
  id: id,
  text: 'text $id',
  translation: 'translation $id',
  source: Language.auto,
  target: const Language(code: 'fr', name: 'French'),
  engineId: 'mozhi:google',
  engineName: 'Google',
  createdAt: DateTime(2026),
  isFavorite: isFavorite,
);

void main() {
  late HistoryRepository repository;

  final one = _entry('1');
  final two = _entry('2');

  setUpAll(() {
    registerFallbackValue(_entry('fallback'));
    registerFallbackValue(Duration.zero);
  });

  setUp(() {
    repository = _MockHistoryRepository();
  });

  HistoryCubit buildCubit() => HistoryCubit(repository: repository);

  HistoryState ready(List<HistoryEntry> entries) =>
      HistoryState(status: HistoryStatus.ready, entries: entries);

  group(HistoryCubit, () {
    test('starts in the initial state', () {
      expect(buildCubit().state, const HistoryState());
    });

    test('can be created with the default repository', () async {
      final cubit = HistoryCubit();
      expect(cubit.state, const HistoryState());
      await cubit.close();
    });

    group('load', () {
      blocTest<HistoryCubit, HistoryState>(
        'emits loading then the entries',
        setUp: () =>
            when(() => repository.load()).thenAnswer((_) async => [two, one]),
        build: buildCubit,
        act: (cubit) => cubit.load(),
        expect: () => [
          const HistoryState(status: HistoryStatus.loading),
          ready([two, one]),
        ],
      );

      blocTest<HistoryCubit, HistoryState>(
        'emits failure and reports the error',
        setUp: () =>
            when(() => repository.load()).thenThrow(StateError('no disk')),
        build: buildCubit,
        act: (cubit) => cubit.load(),
        expect: () => const [
          HistoryState(status: HistoryStatus.loading),
          HistoryState(status: HistoryStatus.failure),
        ],
        errors: () => [isA<StateError>()],
      );

      blocTest<HistoryCubit, HistoryState>(
        'does not emit after close',
        setUp: () =>
            when(() => repository.load()).thenAnswer((_) async => [one]),
        build: buildCubit,
        act: (cubit) async {
          final load = cubit.load();
          await cubit.close();
          await load;
        },
        expect: () => const [HistoryState(status: HistoryStatus.loading)],
      );

      blocTest<HistoryCubit, HistoryState>(
        'reports a failure after close without emitting',
        setUp: () =>
            when(() => repository.load())
                .thenAnswer((_) => Future.error(StateError('no disk'))),
        build: buildCubit,
        act: (cubit) async {
          final load = cubit.load();
          await cubit.close();
          await load;
        },
        expect: () => const [HistoryState(status: HistoryStatus.loading)],
        errors: () => [isA<StateError>()],
      );
    });

    group('mutations', () {
      blocTest<HistoryCubit, HistoryState>(
        'add emits the updated entries',
        setUp: () =>
            when(() => repository.add(two)).thenAnswer((_) async => [two, one]),
        build: buildCubit,
        seed: () => ready([one]),
        act: (cubit) => cubit.add(two),
        expect: () => [
          ready([two, one]),
        ],
      );

      blocTest<HistoryCubit, HistoryState>(
        'restore puts a deleted entry back through the repository '
        '(regression: undo must not go through add)',
        setUp: () =>
            when(() => repository.restore(one))
                .thenAnswer((_) async => [two, one]),
        build: buildCubit,
        seed: () => ready([two]),
        act: (cubit) => cubit.restore(one),
        expect: () => [
          ready([two, one]),
        ],
        verify: (_) => verifyNever(() => repository.add(any())),
      );

      blocTest<HistoryCubit, HistoryState>(
        'restore reports storage errors',
        setUp: () =>
            when(() => repository.restore(one))
                .thenThrow(StateError('disk full')),
        build: buildCubit,
        seed: () => ready([two]),
        act: (cubit) => cubit.restore(one),
        expect: () => const <HistoryState>[],
        errors: () => [isA<StateError>()],
      );

      blocTest<HistoryCubit, HistoryState>(
        'toggleFavorite emits the updated entries',
        setUp: () =>
            when(() => repository.toggleFavorite('1'))
                .thenAnswer((_) async => [_entry('1', isFavorite: true)]),
        build: buildCubit,
        seed: () => ready([one]),
        act: (cubit) => cubit.toggleFavorite('1'),
        expect: () => [
          ready([_entry('1', isFavorite: true)]),
        ],
      );

      blocTest<HistoryCubit, HistoryState>(
        'delete emits the updated entries',
        setUp: () =>
            when(() => repository.delete('1')).thenAnswer((_) async => [two]),
        build: buildCubit,
        seed: () => ready([two, one]),
        act: (cubit) => cubit.delete('1'),
        expect: () => [
          ready([two]),
        ],
      );

      blocTest<HistoryCubit, HistoryState>(
        'clear forwards keepFavorites',
        setUp: () =>
            when(() => repository.clear(keepFavorites: true))
                .thenAnswer((_) async => [_entry('1', isFavorite: true)]),
        build: buildCubit,
        seed: () => ready([_entry('1', isFavorite: true), two]),
        act: (cubit) => cubit.clear(keepFavorites: true),
        expect: () => [
          ready([_entry('1', isFavorite: true)]),
        ],
      );

      blocTest<HistoryCubit, HistoryState>(
        'clear removes everything by default',
        setUp: () => when(() => repository.clear()).thenAnswer((_) async => []),
        build: buildCubit,
        seed: () => ready([one]),
        act: (cubit) => cubit.clear(),
        expect: () => [ready(const [])],
      );

      blocTest<HistoryCubit, HistoryState>(
        'keeps the state and reports errors',
        setUp: () =>
            when(() => repository.add(any())).thenThrow(StateError('full')),
        build: buildCubit,
        seed: () => ready([one]),
        act: (cubit) => cubit.add(two),
        expect: () => <HistoryState>[],
        errors: () => [isA<StateError>()],
      );

      blocTest<HistoryCubit, HistoryState>(
        'does not emit after close',
        setUp: () =>
            when(() => repository.add(two)).thenAnswer((_) async => [two]),
        build: buildCubit,
        act: (cubit) async {
          final add = cubit.add(two);
          await cubit.close();
          await add;
        },
        expect: () => <HistoryState>[],
      );
    });

    group('retention', () {
      const week = Duration(days: 7);

      HistoryCubit buildRetaining() =>
          HistoryCubit(repository: repository, maxAge: week);

      blocTest<HistoryCubit, HistoryState>(
        'load applies the initial maxAge',
        setUp: () =>
            when(() => repository.load(maxAge: week))
                .thenAnswer((_) async => [one]),
        build: buildRetaining,
        act: (cubit) => cubit.load(),
        expect: () => [
          const HistoryState(status: HistoryStatus.loading),
          ready([one]),
        ],
      );

      blocTest<HistoryCubit, HistoryState>(
        'add applies the maxAge',
        setUp: () =>
            when(() => repository.add(two, maxAge: week))
                .thenAnswer((_) async => [two]),
        build: buildRetaining,
        seed: () => ready([one]),
        act: (cubit) => cubit.add(two),
        expect: () => [
          ready([two]),
        ],
      );

      blocTest<HistoryCubit, HistoryState>(
        'importJson applies the maxAge',
        setUp: () => when(() => repository.importJson('json', maxAge: week))
            .thenAnswer(
              (_) async => HistoryImport(entries: [two], added: 1, expired: 3),
            ),
        build: buildRetaining,
        act: (cubit) => cubit.importJson('json'),
        expect: () => [
          ready([two]),
        ],
      );

      blocTest<HistoryCubit, HistoryState>(
        'applyRetention prunes right away and applies to later additions',
        setUp: () {
          when(() => repository.prune(week)).thenAnswer((_) async => [two]);
          when(() => repository.add(one, maxAge: week))
              .thenAnswer((_) async => [one, two]);
        },
        build: buildCubit,
        seed: () => ready([two, _entry('old')]),
        act: (cubit) async {
          await cubit.applyRetention(week);
          await cubit.add(one);
        },
        expect: () => [
          ready([two]),
          ready([one, two]),
        ],
      );

      blocTest<HistoryCubit, HistoryState>(
        'applyRetention(null) keeps everything without touching storage',
        setUp: () =>
            when(() => repository.add(two)).thenAnswer((_) async => [two, one]),
        build: buildRetaining,
        seed: () => ready([one]),
        act: (cubit) async {
          await cubit.applyRetention(null);
          await cubit.add(two);
        },
        expect: () => [
          ready([two, one]),
        ],
        verify: (_) {
          verifyNever(() => repository.prune(any()));
          verify(() => repository.add(two)).called(1);
        },
      );

      blocTest<HistoryCubit, HistoryState>(
        'applyRetention reports storage errors and keeps the state',
        setUp: () =>
            when(() => repository.prune(week))
                .thenThrow(StateError('disk full')),
        build: buildCubit,
        seed: () => ready([one]),
        act: (cubit) => cubit.applyRetention(week),
        expect: () => const <HistoryState>[],
        errors: () => [isA<StateError>()],
      );
    });

    group('filters', () {
      blocTest<HistoryCubit, HistoryState>(
        'search updates the query',
        build: buildCubit,
        act: (cubit) => cubit.search('cat'),
        expect: () => const [HistoryState(query: 'cat')],
      );

      blocTest<HistoryCubit, HistoryState>(
        'setFavoritesOnly updates the filter',
        build: buildCubit,
        act: (cubit) => cubit.setFavoritesOnly(enabled: true),
        expect: () => const [HistoryState(favoritesOnly: true)],
      );
    });

    group('import/export', () {
      test('exportJson returns the repository export', () async {
        when(() => repository.exportJson()).thenAnswer((_) async => '[]');

        expect(await buildCubit().exportJson(), '[]');
      });

      blocTest<HistoryCubit, HistoryState>(
        'importJson emits the merged entries',
        setUp: () => when(() => repository.importJson('json')).thenAnswer(
          (_) async => HistoryImport(entries: [two, one], added: 1, expired: 0),
        ),
        build: buildCubit,
        seed: () => ready([one]),
        act: (cubit) => cubit.importJson('json'),
        expect: () => [
          ready([two, one]),
        ],
      );

      test('importJson returns what was imported', () async {
        final result = HistoryImport(entries: [two], added: 1, expired: 3);
        when(() => repository.importJson('json'))
            .thenAnswer((_) async => result);

        expect(await buildCubit().importJson('json'), result);
      });

      test('importJson rethrows invalid input', () async {
        when(() => repository.importJson('bad'))
            .thenAnswer((_) => Future.error(const FormatException('bad')));
        final cubit = buildCubit();

        await expectLater(cubit.importJson('bad'), throwsFormatException);
        expect(cubit.state, const HistoryState());
      });
    });
  });
}
