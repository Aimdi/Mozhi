import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/phrasebook/data/default_phrasebook.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';

import '../helpers.dart';

void main() {
  late HistoryCubit cubit;

  setUp(() {
    cubit = HistoryCubit(
      repository: HistoryRepository(
        store: MemoryStore(),
        keyStore: MemoryStore(),
      ),
    );
  });

  tearDown(() => cubit.close());

  test('waits for the history to load, then reads its favourites', () async {
    await cubit.add(favoriteEntry('1'));
    await cubit.add(
      favoriteEntry('2', text: 'plain').copyWith(isFavorite: false),
    );
    final favorites = HistoryCubitFavorites(cubit);
    expect((await favorites.favorites()).map((e) => e.id), ['1']);

    final fresh = HistoryCubit(
      repository: HistoryRepository(
        store: MemoryStore(),
        keyStore: MemoryStore(),
      ),
    );
    final waiting = HistoryCubitFavorites(fresh).favorites();
    await fresh.add(favoriteEntry('3'));
    expect((await waiting).map((e) => e.id), ['3']);
    await fresh.close();
  });

  test('gives up waiting after the timeout', () async {
    final favorites = HistoryCubitFavorites(
      cubit,
      loadTimeout: const Duration(milliseconds: 10),
    );
    expect(await favorites.favorites(), isEmpty);
  });

  test('changes fire only when the favourites change', () async {
    final favorites = HistoryCubitFavorites(cubit);
    var count = 0;
    final subscription = favorites.changes.listen((_) => count++);
    await cubit.add(favoriteEntry('1'));
    await pumpEventQueue();
    expect(count, 1);
    await cubit.add(
      favoriteEntry('2', text: 'other').copyWith(isFavorite: false),
    );
    cubit.search('x');
    await pumpEventQueue();
    expect(count, 1);
    await cubit.toggleFavorite('1');
    await pumpEventQueue();
    expect(count, 2);
    await subscription.cancel();
  });

  test('remove un-stars an entry and restore stars it again', () async {
    await cubit.add(favoriteEntry('1'));
    final favorites = HistoryCubitFavorites(cubit);
    await favorites.remove('9');
    await favorites.restore('9');
    await favorites.remove('1');
    expect(cubit.state.entries.single.isFavorite, isFalse);
    await favorites.restore('1');
    expect(cubit.state.entries.single.isFavorite, isTrue);
    // Only once.
    await cubit.toggleFavorite('1');
    await favorites.restore('1');
    expect(cubit.state.entries.single.isFavorite, isFalse);
  });

  test(
    'createPhrasebookRepository reads the favourites of the history',
    () async {
      await cubit.add(favoriteEntry('1'));
      final phrasebook = createPhrasebookRepository(
        preferences: MemoryStore(),
        history: cubit,
      );
      expect(phrasebook.favorites, isA<HistoryCubitFavorites>());
      expect(phrasebook.starter, isNotNull);
      final phrases = await phrasebook.phrases(
        collectionId: PhraseCollection.favoritesId,
      );
      expect(phrases.single.id, 'h:1');
      await phrasebook.dispose();
    },
  );
}
