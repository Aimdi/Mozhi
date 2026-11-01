import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/data/history_repository.dart';

void main() {
  group('HistoryRepository drafts', () {
    late MemoryStore store;
    late MemoryStore keys;
    late HistoryRepository repository;

    setUp(() {
      store = MemoryStore();
      keys = MemoryStore();
      repository = HistoryRepository(store: store, keyStore: keys);
    });

    test('keeps the draft encrypted and reads it back', () async {
      await repository.saveDraft('Bonjour tout le monde');

      final stored = store.values[HistoryRepository.draftStorageKey]!;
      expect(stored, isNot(contains('Bonjour')));
      expect(keys.values[HistoryRepository.keyStorageKey], isNotNull);
      expect(await repository.readDraft(), 'Bonjour tout le monde');
      // Another launch, with the same key.
      expect(
        await HistoryRepository(store: store, keyStore: keys).readDraft(),
        'Bonjour tout le monde',
      );
    });

    test('a blank draft and deleteDraft delete it', () async {
      await repository.saveDraft('Hallo');
      await repository.saveDraft('  ');
      expect(await repository.readDraft(), isNull);

      await repository.saveDraft('Hallo');
      await repository.deleteDraft();
      expect(store.values, isNot(contains(HistoryRepository.draftStorageKey)));
    });

    test('deleteAll deletes it', () async {
      await repository.saveDraft('Hallo');
      await repository.deleteAll();
      expect(await repository.readDraft(), isNull);
      expect(store.values, isNot(contains(HistoryRepository.draftStorageKey)));
    });

    test('is not kept while the history cannot be decrypted (its key is '
        'never replaced)', () async {
      store.values[HistoryRepository.storageKey] =
          '${HistoryCipher.prefix}AAAA';
      await repository.saveDraft('Hallo');
      expect(store.values, isNot(contains(HistoryRepository.draftStorageKey)));
      expect(keys.values, isEmpty);
    });

    test('reads nothing without its key or when it is damaged', () async {
      await repository.saveDraft('Hallo');
      final other = HistoryRepository(store: store, keyStore: MemoryStore());
      expect(await other.readDraft(), isNull);

      store.values[HistoryRepository.draftStorageKey] = base64Encode([1, 2]);
      expect(
        await HistoryRepository(store: store, keyStore: keys).readDraft(),
        isNull,
      );
    });
  });
}
