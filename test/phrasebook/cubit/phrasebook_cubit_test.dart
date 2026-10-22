import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/phrasebook/cubit/phrasebook_cubit.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';

import '../helpers.dart';
import '../pump.dart';

class _MockRepository extends Mock implements PhrasebookRepository;

const _hello = PhraseDraft(
  text: 'Hello',
  translation: 'Olá',
  sourceCode: 'en',
  targetCode: 'pt',
);
const _bonjour = PhraseDraft(
  text: 'Bonjour',
  translation: 'Hello',
  sourceCode: 'fr',
  targetCode: 'en',
  note: 'formal',
);
const _apple = PhraseDraft(
  text: 'apple',
  translation: 'maçã',
  sourceCode: 'en',
  targetCode: 'pt',
);

void main() {
  group('PhrasebookState', () {
    final now = DateTime(2026, 10, 22);
    final hello = _hello.toPhrase('p:1', now);
    final bonjour = _bonjour.toPhrase('p:2', now);
    final apple = _apple.toPhrase('p:3', now);
    final collection = PhraseCollection(
      id: 'c:1',
      name: 'Mixed',
      phraseIds: const ['p:1', 'p:2', 'p:3', 'p:gone'],
      createdAt: now,
      updatedAt: now,
    );
    final starter = PhraseCollection(
      id: 'starter:pt',
      name: 'Portuguese',
      phraseIds: const ['p:1', 'p:3'],
      createdAt: now,
      updatedAt: now,
      starter: true,
    );
    final favorites = PhraseCollection(
      id: PhraseCollection.favoritesId,
      name: '',
      phraseIds: const [],
      createdAt: now,
      updatedAt: now,
    );
    final state = PhrasebookState(
      status: PhrasebookStatus.ready,
      collections: [favorites, collection, starter],
      phrases: {
        for (final p in [hello, bonjour, apple]) p.id: p,
      },
      selectedId: collection.id,
    );

    test('groups the collections', () {
      expect(state.favorites, favorites);
      expect(state.userCollections, [collection]);
      expect(state.starterCollections, [starter]);
      expect(state.selected, collection);
      expect(state.copyWith(selectedId: () => 'c:none').selected, isNull);
    });

    test('lists a collection newest first, A to Z, filtered', () {
      expect(state.phrasesOf(collection), [hello, bonjour, apple]);
      expect(state.visible, [apple, bonjour, hello]);
      expect(state.copyWith(sort: PhraseSort.alphabetical).visible, [
        apple,
        bonjour,
        hello,
      ]);
      expect(state.copyWith(query: 'FORMAL').visible, [bonjour]);
      expect(state.copyWith(query: 'olá').visible, [hello]);
      final pair = PhrasePair.of(hello);
      expect(state.copyWith(pair: () => pair).visible, [apple, hello]);
      expect(state.copyWith(pair: () => pair).hasFilters, isTrue);
      expect(state.hasFilters, isFalse);
      expect(state.pairsOf(collection), [
        (const PhrasePair('en', 'pt'), 2),
        (const PhrasePair('fr', 'en'), 1),
      ]);
      // A starter phrasebook keeps its page's order.
      expect(state.copyWith(selectedId: () => starter.id).visible, [
        hello,
        apple,
      ]);
      expect(const PhrasebookState().visible, isEmpty);
    });
  });

  group('PhrasebookCubit', () {
    late FakeFavorites favorites;
    late PhrasebookRepository repository;

    setUp(() {
      favorites = FakeFavorites([favoriteEntry('1')]);
      repository = createPhrasebook(favorites: favorites);
    });

    blocTest<PhrasebookCubit, PhrasebookState>(
      'loads every collection and phrase',
      build: () => PhrasebookCubit(repository: repository),
      act: (cubit) => cubit.load(),
      verify: (cubit) {
        expect(cubit.state.status, PhrasebookStatus.ready);
        expect(cubit.state.collections.single.isFavorites, isTrue);
        expect(cubit.state.phrases.keys, ['h:1']);
      },
    );

    test('reloads when the phrasebook changes, and forgets a deleted '
        'collection', () async {
      final cubit = PhrasebookCubit(repository: repository);
      await cubit.load();
      final lisbon = await repository.createCollection('Lisbon');
      await pumpEventQueue();
      expect(cubit.state.userCollections.single.name, 'Lisbon');
      cubit.select(lisbon.id);
      expect(cubit.state.selected, isNotNull);
      await repository.deleteCollection(lisbon.id);
      await pumpEventQueue();
      expect(cubit.state.selectedId, isNull);
      await cubit.close();
    });

    test('select, search, filter and sort', () async {
      final cubit = PhrasebookCubit(
        repository: repository,
        initialCollectionId: PhraseCollection.favoritesId,
      );
      expect(cubit.state.selectedId, PhraseCollection.favoritesId);
      cubit
        ..search('x')
        ..filterByPair(const PhrasePair('en', 'pt'))
        ..sortBy(PhraseSort.alphabetical);
      expect(cubit.state.query, 'x');
      expect(cubit.state.pair, const PhrasePair('en', 'pt'));
      expect(cubit.state.sort, PhraseSort.alphabetical);
      cubit.select('c:1');
      expect(cubit.state.query, '');
      expect(cubit.state.pair, isNull);
      expect(cubit.state.sort, PhraseSort.recent);
      await cubit.close();
    });

    test('reorders the user collections at once and saves the order', () async {
      final cubit = PhrasebookCubit(repository: repository);
      final a = await repository.createCollection('A');
      final b = await repository.createCollection('B');
      final c = await repository.createCollection('C');
      // The changes reload it.
      await pumpEventQueue();
      expect(cubit.state.userCollections.map((x) => x.id), [c.id, b.id, a.id]);
      unawaited(cubit.reorder(0, 2));
      expect(cubit.state.userCollections.map((x) => x.id), [b.id, a.id, c.id]);
      expect(cubit.state.collections.first.isFavorites, isTrue);
      await pumpEventQueue();
      final saved = await repository.collections();
      expect(saved.skip(1).map((x) => x.id), [b.id, a.id, c.id]);
      // Out of range: nothing.
      await cubit.reorder(9, 0);
      await cubit.close();
    });

    test('unreadable and failing phrasebooks', () async {
      final failing = _MockRepository();
      when(() => failing.changes).thenAnswer((_) => const Stream.empty());
      when(failing.collections)
          .thenThrow(const PhrasebookUnreadableException(keyMissing: true));
      when(failing.discardUnreadable).thenAnswer((_) async {});
      final cubit = PhrasebookCubit(repository: failing);
      await cubit.load();
      expect(cubit.state.status, PhrasebookStatus.unreadable);
      await cubit.discardUnreadable();
      verify(failing.discardUnreadable).called(1);

      when(failing.collections).thenThrow(StateError('storage'));
      final errors = <Object>[];
      final failingCubit = PhrasebookCubit(repository: failing);
      final subscription = failingCubit.stream.listen(
        (_) {},
        onError: errors.add,
      );
      await failingCubit.load();
      expect(failingCubit.state.status, PhrasebookStatus.failure);
      when(failing.discardUnreadable).thenThrow(StateError('again'));
      await failingCubit.discardUnreadable();
      when(() => failing.reorderCollections(any())).thenThrow(StateError('x'));
      await subscription.cancel();
      await cubit.close();
      await failingCubit.close();
    });

    test('a failed reorder reloads', () async {
      final failing = _MockRepository();
      final now = DateTime(2026);
      final collections = [
        PhraseCollection(
          id: 'c:1',
          name: 'A',
          phraseIds: const [],
          createdAt: now,
          updatedAt: now,
        ),
        PhraseCollection(
          id: 'c:2',
          name: 'B',
          phraseIds: const [],
          createdAt: now,
          updatedAt: now,
        ),
      ];
      when(() => failing.changes).thenAnswer((_) => const Stream.empty());
      when(failing.collections).thenAnswer((_) async => collections);
      when(failing.phrases).thenAnswer((_) async => const []);
      when(() => failing.reorderCollections(any()))
          .thenThrow(StateError('storage'));
      final cubit = PhrasebookCubit(repository: failing);
      await cubit.load();
      await cubit.reorder(0, 1);
      expect(cubit.state.userCollections.map((c) => c.id), ['c:1', 'c:2']);
      await cubit.close();
    });

    test('only the newest load is shown', () async {
      final slow = _MockRepository();
      final first = Completer<List<PhraseCollection>>();
      var calls = 0;
      when(() => slow.changes).thenAnswer((_) => const Stream.empty());
      when(
        slow.collections,
      ).thenAnswer((_) => calls++ == 0 ? first.future : Future.value(const []));
      when(slow.phrases).thenAnswer((_) async => const []);
      final cubit = PhrasebookCubit(repository: slow);
      final older = cubit.load();
      await cubit.load();
      first.complete(const []);
      await older;
      expect(cubit.state.status, PhrasebookStatus.ready);
      await cubit.close();
    });
  });
}
