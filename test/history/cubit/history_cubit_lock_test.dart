import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:translation_repository/translation_repository.dart';

class _MockHistoryRepository extends Mock implements HistoryRepository;

/// Counts how often the stored history is read.
class _CountingStore extends MemoryStore {
  int reads = 0;

  @override
  Future<String?> read(String key) {
    if (key == HistoryRepository.storageKey) reads++;
    return super.read(key);
  }
}

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
    when(() => repository.forgetCache()).thenAnswer((_) async {});
    when(() => repository.load()).thenAnswer((_) async => [two, one]);
  });

  Future<HistoryCubit> loaded() async {
    final cubit = HistoryCubit(repository: repository);
    addTearDown(cubit.close);
    await cubit.load();
    expect(cubit.state.entries, [two, one]);
    return cubit;
  }

  group('forgetForLock', () {
    test('drops the entries here and in the repository', () async {
      final cubit = await loaded();

      await cubit.forgetForLock();

      expect(cubit.state.entries, isEmpty);
      expect(cubit.state.status, HistoryStatus.ready);
      verify(() => repository.forgetCache()).called(1);
    });

    test('saves while locked without keeping the entries', () async {
      final cubit = await loaded();
      await cubit.forgetForLock();
      final three = _entry('3');
      when(() => repository.add(three, maxAge: any(named: 'maxAge')))
          .thenAnswer((_) async => [three, two, one]);

      await cubit.add(three);
      await pumpEventQueue();

      verify(() => repository.add(three, maxAge: any(named: 'maxAge')))
          .called(1);
      expect(cubit.state.entries, isEmpty);
      verify(() => repository.forgetCache()).called(2);
    });

    test('waits for the unlock to load', () async {
      final cubit = await loaded();
      await cubit.forgetForLock();
      clearInteractions(repository);

      await cubit.load();

      verifyNever(() => repository.load());
      expect(cubit.state.entries, isEmpty);
    });

    test('reports a repository that fails', () async {
      final cubit = await loaded();
      when(() => repository.forgetCache()).thenThrow(StateError('broken'));

      await cubit.forgetForLock();

      expect(cubit.state.entries, isEmpty);
    });

    test('does nothing once closed', () async {
      final cubit = HistoryCubit(repository: repository);
      await cubit.close();
      await cubit.forgetForLock();
      verifyNever(() => repository.forgetCache());
    });
  });

  group('reloadAfterLock', () {
    test('reads the history again', () async {
      final cubit = await loaded();
      await cubit.forgetForLock();

      await cubit.reloadAfterLock();

      expect(cubit.state.entries, [two, one]);
      verify(() => repository.load()).called(2);
    });

    test('does nothing without a lock before', () async {
      final cubit = await loaded();
      await cubit.reloadAfterLock();
      verify(() => repository.load()).called(1);
    });
  });

  group('HistoryRepository.forgetCache', () {
    test('reads the stored history again next time', () async {
      final store = _CountingStore();
      final history = HistoryRepository(store: store, keyStore: MemoryStore());
      await history.add(one);
      await history.exportJson();
      final reads = store.reads;

      await history.exportJson();
      expect(store.reads, reads, reason: 'kept in memory');

      await history.forgetCache();
      final json = await history.exportJson();

      expect(store.reads, reads + 1);
      expect(json, contains('text 1'));
    });
  });
}
