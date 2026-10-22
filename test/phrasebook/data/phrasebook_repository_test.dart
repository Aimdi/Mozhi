import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/data/history_cipher.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:translation_repository/translation_repository.dart'
    show Language;

import '../helpers.dart';
import '../starter_fixtures.dart';

const _hello = PhraseDraft(
  text: 'Hello',
  translation: 'Olá',
  sourceCode: 'en',
  targetCode: 'pt',
);
const _thanks = PhraseDraft(
  text: 'Thank you',
  translation: 'Obrigado',
  sourceCode: 'en',
  targetCode: 'pt',
  note: 'obrigada if you are a woman',
);

/// A key store that forgets what is written (secure storage that fails).
class _ForgetfulStore implements KeyValueStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

void main() {
  late MemoryStore store;
  late MemoryStore keys;
  late FakeFavorites favorites;
  late DateTime now;
  late int ids;

  PhrasebookRepository repo({
    StarterPhrasebooks? starter,
    KeyValueStore? keyStore,
    int maxTombstones = 5000,
  }) => PhrasebookRepository(
    store: store,
    keyStore: keyStore ?? keys,
    favorites: favorites,
    starter: starter,
    clock: () => now,
    newId: () => '${ids++}',
    maxTombstones: maxTombstones,
  );

  /// Moves the clock on by a minute.
  void tick() => now = now.add(const Duration(minutes: 1));

  setUp(() {
    store = MemoryStore();
    keys = MemoryStore();
    favorites = FakeFavorites();
    now = DateTime(2026, 10, 22, 10);
    ids = 1;
  });

  group('reading', () {
    test('an empty phrasebook has only Favorites', () async {
      final phrasebook = repo();
      final collections = await phrasebook.collections();
      expect(collections, hasLength(1));
      expect(collections.single.isFavorites, isTrue);
      expect(collections.single.phraseIds, isEmpty);
      expect(await phrasebook.phrases(), isEmpty);
      expect(await phrasebook.phrase('p:1'), isNull);
      expect(await phrasebook.phrases(collectionId: 'c:none'), isEmpty);
      expect(await phrasebook.lastCollectionId(), isNull);
      expect(await phrasebook.collection('c:none'), isNull);
    });

    test('works without favourites or starter phrasebooks', () async {
      final phrasebook = PhrasebookRepository(store: store, keyStore: keys);
      expect(await phrasebook.collections(), hasLength(1));
      expect(
        await phrasebook.phrases(collectionId: PhraseCollection.favoritesId),
        isEmpty,
      );
      expect(await phrasebook.phrases(collectionId: 'starter:pt'), isEmpty);
      expect(await phrasebook.phrase('s:pt:a1'), isNull);
      expect(await phrasebook.deleteCollection('starter:pt'), isNull);
    });

    test('Favorites are the history favourites, with their notes', () async {
      favorites.set([
        favoriteEntry('2', createdAt: DateTime(2026, 10, 22, 9, 5)),
        favoriteEntry(
          '1',
          source: Language.auto,
          kind: HistoryEntryKind.dictionary,
        ),
      ]);
      final phrasebook = repo();
      await phrasebook.updateNote('h:2', ' Formal ');
      final collections = await phrasebook.collections();
      expect(collections.first.phraseIds, ['h:2', 'h:1']);
      expect(collections.first.updatedAt, now);
      final phrases = await phrasebook.phrases(
        collectionId: PhraseCollection.favoritesId,
      );
      expect(phrases.first.note, 'Formal');
      expect(phrases.first.updatedAt, now);
      expect(phrases.first.origin, PhraseOrigin.favorite);
      expect(phrases.last.sourceCode, Phrase.unknownLanguage);
      expect(phrases.last.updatedAt, DateTime(2026, 10, 22, 9));
      expect((await phrasebook.phrase('h:1'))?.text, 'text 1');
      expect(await phrasebook.phrase('h:9'), isNull);
      expect(await phrasebook.phrases(), hasLength(2));
    });

    test('favourites that fail to load read as none', () async {
      final phrasebook = PhrasebookRepository(
        store: store,
        keyStore: keys,
        favorites: _FailingFavorites(),
      );
      expect((await phrasebook.collections()).first.phraseIds, isEmpty);
    });

    test('installed starter phrasebooks are read-only collections', () async {
      final bytes = starterPackBytes(starterPackJson());
      await installStarterPack(store, bytes);
      final starter = StarterPhrasebooks(
        catalog: StarterPhrasebookCatalog(const <StarterPhrasebookInfo>[]),
        store: store,
      );
      final phrasebook = repo(starter: starter);
      final collections = await phrasebook.collections();
      expect(collections, hasLength(2));
      final pack = collections.last;
      expect(pack.id, 'starter:pt');
      expect(pack.starter, isTrue);
      expect(pack.isEditable, isFalse);
      expect(pack.name, 'Portuguese');
      expect(pack.sourceCode, 'en');
      expect(pack.targetCode, 'pt');
      expect(pack.phraseIds, ['s:pt:a1', 's:pt:a2', 's:pt:b1']);
      final phrases = await phrasebook.phrases(collectionId: pack.id);
      expect(phrases.first.pronunciation, 'oh-LAH');
      expect(phrases.first.topic, 'Basics');
      expect(phrases.last.topic, 'Eating');
      expect((await phrasebook.phrase('s:pt:b1'))?.translation, 'A conta.');
      expect(await phrasebook.phrase('s:pt:zz'), isNull);
      expect(await phrasebook.phrases(), hasLength(3));
      await expectLater(
        phrasebook.updateNote('s:pt:a1', 'x'),
        throwsArgumentError,
      );
      await expectLater(
        phrasebook.addPhrase(_hello, pack.id),
        throwsArgumentError,
      );
      // Deleting it uninstalls it.
      expect(await phrasebook.deleteCollection(pack.id), isNull);
      expect(await phrasebook.collections(), hasLength(1));
    });

    test('a damaged starter phrasebook is left out', () async {
      final bytes = starterPackBytes(starterPackJson());
      await installStarterPack(store, bytes);
      await store.write('${StarterPhrasebooks.packKeyPrefix}pt', 'AAAA');
      final phrasebook = repo(
        starter: StarterPhrasebooks(
          catalog: StarterPhrasebookCatalog(const <StarterPhrasebookInfo>[]),
          store: store,
        ),
      );
      expect(await phrasebook.collections(), hasLength(1));
      expect(await phrasebook.phrases(), isEmpty);
    });
  });

  group('collections', () {
    test('are created first, renamed, given languages and reordered', () async {
      final phrasebook = repo();
      final lisbon = await phrasebook.createCollection(' Trip to Lisbon ');
      tick();
      final pharmacy = await phrasebook.createCollection(
        'Pharmacy',
        sourceCode: 'en',
        targetCode: 'pt',
      );
      expect(lisbon.id, 'c:1');
      expect(lisbon.name, 'Trip to Lisbon');
      expect(pharmacy.sourceCode, 'en');
      var collections = await phrasebook.collections();
      expect(collections.map((c) => c.id), ['favorites', 'c:2', 'c:1']);

      tick();
      await phrasebook.renameCollection('c:1', 'Lisbon');
      await phrasebook.setCollectionLanguages(
        'c:1',
        sourceCode: 'en',
        targetCode: 'pt',
      );
      await phrasebook.reorderCollections(['c:1']);
      collections = await phrasebook.collections();
      expect(collections.map((c) => c.id), ['favorites', 'c:1', 'c:2']);
      expect(collections[1].name, 'Lisbon');
      expect(collections[1].targetCode, 'pt');
      expect(collections[1].updatedAt, now);

      await phrasebook.reorderCollections(['c:2', 'c:1']);
      collections = await phrasebook.collections();
      expect(collections.map((c) => c.id), ['favorites', 'c:2', 'c:1']);
    });

    test('names must not be empty, and built-ins cannot change', () async {
      final phrasebook = repo();
      await expectLater(phrasebook.createCollection('  '), throwsArgumentError);
      final lisbon = await phrasebook.createCollection('Lisbon');
      await expectLater(
        phrasebook.renameCollection(lisbon.id, ''),
        throwsArgumentError,
      );
      await expectLater(
        phrasebook.renameCollection(PhraseCollection.favoritesId, 'Mine'),
        throwsArgumentError,
      );
      await expectLater(
        phrasebook.deleteCollection(PhraseCollection.favoritesId),
        throwsArgumentError,
      );
    });

    test('deleting one deletes the phrases only it had; Undo puts '
        'everything back', () async {
      final phrasebook = repo();
      final lisbon = await phrasebook.createCollection('Lisbon');
      final porto = await phrasebook.createCollection('Porto');
      final hello = (await phrasebook.addPhrase(_hello, lisbon.id)).phrase;
      final thanks = (await phrasebook.addPhrase(_thanks, lisbon.id)).phrase;
      await phrasebook.copyPhrase(thanks.id, porto.id);

      tick();
      final deletion = await phrasebook.deleteCollection(lisbon.id);
      expect(deletion!.index, 1);
      expect(deletion.phrases, [hello]);
      expect(await phrasebook.phrase(hello.id), isNull);
      expect(await phrasebook.phrase(thanks.id), isNotNull);
      expect((await phrasebook.collections()).map((c) => c.id), [
        'favorites',
        porto.id,
      ]);
      final backup = await phrasebook.exportBackup();
      expect((backup['tombstones']! as Map).keys, {lisbon.id, hello.id});

      await phrasebook.restoreCollection(deletion);
      expect((await phrasebook.collections()).map((c) => c.id), [
        'favorites',
        porto.id,
        lisbon.id,
      ]);
      expect(
        (await phrasebook.phrases(collectionId: lisbon.id)).map((p) => p.id),
        [hello.id, thanks.id],
      );
      final after = await phrasebook.exportBackup();
      expect(after['tombstones'], isEmpty);
      // Restoring twice adds nothing.
      await phrasebook.restoreCollection(deletion);
      expect(await phrasebook.collections(), hasLength(3));
    });
  });

  group('phrases', () {
    test(
      'are added to the end once, and the collection is remembered',
      () async {
        final phrasebook = repo();
        final lisbon = await phrasebook.createCollection('Lisbon');
        final first = await phrasebook.addPhrase(_hello, lisbon.id);
        expect(first.added, isTrue);
        expect(first.phrase.id, 'p:2');
        expect(first.phrase.createdAt, now);
        await phrasebook.addPhrase(_thanks, lisbon.id);
        final again = await phrasebook.addPhrase(
          const PhraseDraft(
            text: ' Hello ',
            translation: 'Olá ',
            sourceCode: 'en',
            targetCode: 'pt',
          ),
          lisbon.id,
        );
        expect(again.added, isFalse);
        expect(again.phrase, first.phrase);
        final phrases = await phrasebook.phrases(collectionId: lisbon.id);
        expect(phrases.map((p) => p.text), ['Hello', 'Thank you']);
        expect(phrases.last.note, 'obrigada if you are a woman');
        expect(await phrasebook.lastCollectionId(), lisbon.id);
        expect(await phrasebook.collectionsWith(_hello), {lisbon.id});
        expect(
          await phrasebook.collectionsWith(
            const PhraseDraft(
              text: 'Hello',
              translation: 'Olá',
              sourceCode: 'en',
              targetCode: 'es',
            ),
          ),
          isEmpty,
        );
      },
    );

    test('the same phrase in another collection is the same phrase', () async {
      final phrasebook = repo();
      final lisbon = await phrasebook.createCollection('Lisbon');
      final porto = await phrasebook.createCollection('Porto');
      final a = await phrasebook.addPhrase(_hello, lisbon.id);
      final b = await phrasebook.addPhrase(_hello, porto.id);
      expect(b.added, isTrue);
      expect(b.phrase.id, a.phrase.id);
      expect(await phrasebook.phrases(), hasLength(1));
      expect(await phrasebook.collectionsWith(_hello), {lisbon.id, porto.id});
    });

    test('empty drafts and unknown collections are refused', () async {
      final phrasebook = repo();
      await expectLater(
        phrasebook.addPhrase(
          const PhraseDraft(
            text: ' ',
            translation: 'x',
            sourceCode: 'en',
            targetCode: 'pt',
          ),
          'c:1',
        ),
        throwsArgumentError,
      );
      await expectLater(
        phrasebook.addPhrase(_hello, 'c:none'),
        throwsArgumentError,
      );
      await expectLater(
        phrasebook.addPhrase(_hello, PhraseCollection.favoritesId),
        throwsArgumentError,
      );
    });

    test('imports skip empty and known phrases', () async {
      final phrasebook = repo();
      final lisbon = await phrasebook.createCollection('Lisbon');
      await phrasebook.addPhrase(_hello, lisbon.id);
      final added = await phrasebook.importPhrases(lisbon.id, [
        _hello,
        _thanks,
        const PhraseDraft(
          text: '',
          translation: '',
          sourceCode: 'en',
          targetCode: 'pt',
        ),
        _thanks,
      ]);
      expect(added, 1);
      expect(await phrasebook.phrases(collectionId: lisbon.id), hasLength(2));
      await expectLater(
        phrasebook.importPhrases('c:none', [_hello]),
        throwsArgumentError,
      );
    });

    test('copying a favourite or a starter phrase makes a copy', () async {
      favorites.set([favoriteEntry('7')]);
      final bytes = starterPackBytes(starterPackJson());
      await installStarterPack(store, bytes);
      final phrasebook = repo(
        starter: StarterPhrasebooks(
          catalog: StarterPhrasebookCatalog(const <StarterPhrasebookInfo>[]),
          store: store,
        ),
      );
      await phrasebook.updateNote('h:7', 'From the café');
      final lisbon = await phrasebook.createCollection('Lisbon');
      final favorite = await phrasebook.copyPhrase('h:7', lisbon.id);
      expect(favorite.added, isTrue);
      expect(favorite.phrase.isStored, isTrue);
      expect(favorite.phrase.note, 'From the café');
      expect(favorite.phrase.origin, PhraseOrigin.favorite);
      final starter = await phrasebook.copyPhrase('s:pt:a1', lisbon.id);
      expect(starter.phrase.pronunciation, 'oh-LAH');
      expect(starter.phrase.origin, PhraseOrigin.starter);
      expect(starter.phrase.topic, 'Basics');
      await expectLater(
        phrasebook.copyPhrase('h:missing', lisbon.id),
        throwsArgumentError,
      );
    });

    test('a stored phrase is copied and moved between collections', () async {
      final phrasebook = repo();
      final lisbon = await phrasebook.createCollection('Lisbon');
      final porto = await phrasebook.createCollection('Porto');
      final faro = await phrasebook.createCollection('Faro');
      final hello = (await phrasebook.addPhrase(_hello, lisbon.id)).phrase;
      final copy = await phrasebook.copyPhrase(hello.id, porto.id);
      expect(copy.added, isTrue);
      expect(copy.phrase, hello);
      expect((await phrasebook.copyPhrase(hello.id, porto.id)).added, isFalse);
      expect(await phrasebook.lastCollectionId(), porto.id);

      await phrasebook.movePhrase(hello.id, from: lisbon.id, to: faro.id);
      expect(await phrasebook.phrases(collectionId: lisbon.id), isEmpty);
      expect(await phrasebook.phrases(collectionId: faro.id), [hello]);
      expect(await phrasebook.lastCollectionId(), faro.id);
      // Moving to where it is changes nothing.
      await phrasebook.movePhrase(hello.id, from: faro.id, to: faro.id);
      expect(await phrasebook.phrases(collectionId: faro.id), [hello]);
      await expectLater(
        phrasebook.movePhrase('p:none', from: faro.id, to: lisbon.id),
        throwsArgumentError,
      );
    });

    test('removing the last membership deletes a phrase; Undo puts it '
        'back where it was', () async {
      final phrasebook = repo();
      final lisbon = await phrasebook.createCollection('Lisbon');
      final porto = await phrasebook.createCollection('Porto');
      final hello = (await phrasebook.addPhrase(_hello, lisbon.id)).phrase;
      final thanks = (await phrasebook.addPhrase(_thanks, lisbon.id)).phrase;
      await phrasebook.copyPhrase(hello.id, porto.id);

      final kept = await phrasebook.removePhrase(hello.id, porto.id);
      expect(kept!.deleted, isFalse);
      expect(await phrasebook.phrase(hello.id), hello);

      final gone = await phrasebook.removePhrase(hello.id, lisbon.id);
      expect(gone!.deleted, isTrue);
      expect(gone.index, 0);
      expect(await phrasebook.phrase(hello.id), isNull);
      expect(await phrasebook.removePhrase(hello.id, lisbon.id), isNull);

      tick();
      await phrasebook.restorePhrase(gone);
      final phrases = await phrasebook.phrases(collectionId: lisbon.id);
      expect(phrases.map((p) => p.id), [hello.id, thanks.id]);
      expect(phrases.first.updatedAt, now);
      // Again: it is there already.
      await phrasebook.restorePhrase(gone);
      expect(await phrasebook.phrases(collectionId: lisbon.id), hasLength(2));
      await phrasebook.restorePhrase(kept);
      expect(await phrasebook.phrases(collectionId: porto.id), hasLength(1));
      await expectLater(
        phrasebook.removePhrase(hello.id, 'c:none'),
        throwsArgumentError,
      );
    });

    test('Undo into a deleted collection only keeps the phrase', () async {
      final phrasebook = repo();
      final lisbon = await phrasebook.createCollection('Lisbon');
      final hello = (await phrasebook.addPhrase(_hello, lisbon.id)).phrase;
      final removal = await phrasebook.removePhrase(hello.id, lisbon.id);
      await phrasebook.deleteCollection(lisbon.id);
      await phrasebook.restorePhrase(removal!);
      expect(await phrasebook.phrase(hello.id), isNotNull);
    });

    test('taking a favourite out un-stars it; Undo stars it again', () async {
      favorites.set([favoriteEntry('1')]);
      final phrasebook = repo();
      final removal = await phrasebook.removePhrase(
        'h:1',
        PhraseCollection.favoritesId,
      );
      expect(favorites.removed, ['1']);
      expect((await phrasebook.collections()).first.phraseIds, isEmpty);
      await phrasebook.restorePhrase(removal!);
      expect(favorites.restored, ['1']);
      expect((await phrasebook.collections()).first.phraseIds, ['h:1']);
      expect(
        await phrasebook.removePhrase('h:9', PhraseCollection.favoritesId),
        isNull,
      );
    });

    test('notes', () async {
      final phrasebook = repo();
      final lisbon = await phrasebook.createCollection('Lisbon');
      final hello = (await phrasebook.addPhrase(_hello, lisbon.id)).phrase;
      tick();
      await phrasebook.updateNote(hello.id, '  Informal  ');
      final updated = await phrasebook.phrase(hello.id);
      expect(updated!.note, 'Informal');
      expect(updated.updatedAt, now);
      await phrasebook.updateNote(hello.id, '');
      expect((await phrasebook.phrase(hello.id))!.note, '');
      await expectLater(
        phrasebook.updateNote('p:none', 'x'),
        throwsArgumentError,
      );
    });
  });

  group('storage', () {
    test('is encrypted, and read back by a new repository', () async {
      final phrasebook = repo();
      final lisbon = await phrasebook.createCollection('Lisbon');
      await phrasebook.addPhrase(_hello, lisbon.id);
      final raw = store.values[PhrasebookRepository.storageKey]!;
      expect(raw, startsWith(HistoryCipher.prefix));
      expect(raw, isNot(contains('Olá')));
      expect(keys.values[PhrasebookRepository.keyStorageKey], isNotNull);
      expect(await phrasebook.storedLength(), raw.length);

      final again = repo();
      expect(
        (await again.phrases(collectionId: lisbon.id)).single.text,
        'Hello',
      );
      expect(await again.lastCollectionId(), lisbon.id);
    });

    test('a plaintext document is read and written back encrypted', () async {
      store.values[PhrasebookRepository.storageKey] = jsonEncode({
        'collections': [
          {
            'id': 'c:1',
            'name': 'Old',
            'phraseIds': ['p:1', 'p:gone'],
            'createdAt': '2026-10-01T00:00:00Z',
          },
          {'id': 'favorites', 'name': 'x', 'phraseIds': <String>[]},
          {
            'id': 'c:1',
            'name': 'Duplicate',
            'phraseIds': <String>[],
            'createdAt': '2026-10-01T00:00:00Z',
          },
          'nonsense',
        ],
        'phrases': [
          _hello.toPhrase('p:1', DateTime(2026)).toJson(),
          _hello.toPhrase('h:1', DateTime(2026)).toJson(),
          {'id': 'p:bad'},
          3,
        ],
        'favoriteNotes': {
          'h:1': {'note': 'n', 'updatedAt': '2026-10-01T00:00:00Z'},
          'p:1': {'note': 'not a favourite'},
          'h:2': {'note': 'no time'},
        },
        'tombstones': {'p:old': '2026-10-01T00:00:00Z', 'p:bad': 'never'},
      });
      favorites.set([favoriteEntry('1')]);
      final phrasebook = repo();
      final collections = await phrasebook.collections();
      expect(collections.map((c) => c.id), ['favorites', 'c:1']);
      expect(collections.last.phraseIds, ['p:1']);
      expect(
        (await phrasebook.phrases(collectionId: 'favorites')).single.note,
        'n',
      );
      await phrasebook.renameCollection('c:1', 'New');
      expect(
        store.values[PhrasebookRepository.storageKey],
        startsWith(HistoryCipher.prefix),
      );
      final backup = await phrasebook.exportBackup();
      expect((backup['tombstones']! as Map).keys, ['p:old']);
    });

    test('unreadable JSON reads as an empty phrasebook', () async {
      store.values[PhrasebookRepository.storageKey] = '{not json';
      expect(await repo().collections(), hasLength(1));
      store.values[PhrasebookRepository.storageKey] = '[1, 2]';
      expect(await repo().collections(), hasLength(1));
    });

    test('without its key it is unreadable and left alone, until it is '
        'set aside', () async {
      final phrasebook = repo();
      await phrasebook.createCollection('Lisbon');
      final raw = store.values[PhrasebookRepository.storageKey]!;
      keys.values.clear();

      final again = repo();
      await expectLater(
        again.collections(),
        throwsA(
          isA<PhrasebookUnreadableException>().having(
            (e) => e.keyMissing,
            'keyMissing',
            isTrue,
          ),
        ),
      );
      await expectLater(
        again.createCollection('Porto'),
        throwsA(isA<PhrasebookUnreadableException>()),
      );
      expect(store.values[PhrasebookRepository.storageKey], raw);

      await again.discardUnreadable();
      expect(store.values[PhrasebookRepository.unreadableStorageKey], raw);
      expect(store.values[PhrasebookRepository.storageKey], isNull);
      expect(await again.collections(), hasLength(1));
      // A readable phrasebook is left as it is.
      await again.createCollection('Porto');
      await again.discardUnreadable();
      expect(await again.collections(), hasLength(2));
    });

    test('with a wrong key it is unreadable too', () async {
      await repo().createCollection('Lisbon');
      keys.values[PhrasebookRepository.keyStorageKey] = base64Encode(
        List.filled(HistoryCipher.keyLength, 1),
      );
      await expectLater(
        repo().collections(),
        throwsA(
          isA<PhrasebookUnreadableException>().having(
            (e) => e.keyMissing,
            'keyMissing',
            isFalse,
          ),
        ),
      );
      keys.values[PhrasebookRepository.keyStorageKey] = 'not base64!';
      await expectLater(
        repo().collections(),
        throwsA(isA<PhrasebookUnreadableException>()),
      );
      expect(
        const PhrasebookUnreadableException(keyMissing: true).toString(),
        contains('key missing'),
      );
      expect(
        const PhrasebookUnreadableException(keyMissing: false).toString(),
        contains('bad key'),
      );
    });

    test('nothing is written without a durable key', () async {
      final phrasebook = repo(keyStore: _ForgetfulStore());
      await expectLater(
        phrasebook.createCollection('Lisbon'),
        throwsA(isA<PhrasebookKeyUnavailableException>()),
      );
      expect(store.values, isEmpty);
      expect(
        const PhrasebookKeyUnavailableException().toString(),
        'PhrasebookKeyUnavailableException',
      );
    });

    test('deleteAll removes the data, the key and the starter packs', () async {
      final bytes = starterPackBytes(starterPackJson());
      await installStarterPack(store, bytes);
      final phrasebook = repo(
        starter: StarterPhrasebooks(
          catalog: StarterPhrasebookCatalog(const <StarterPhrasebookInfo>[]),
          store: store,
        ),
      );
      await phrasebook.createCollection('Lisbon');
      store.values[PhrasebookRepository.unreadableStorageKey] = 'old';
      await phrasebook.deleteAll();
      expect(store.values, isEmpty);
      expect(keys.values, isEmpty);
      expect(await phrasebook.collections(), hasLength(1));
    });

    test('tombstones are bounded in number and age', () async {
      final phrasebook = repo(maxTombstones: 2);
      final lisbon = await phrasebook.createCollection('Lisbon');
      for (final text in ['a', 'b', 'c']) {
        tick();
        final phrase = (await phrasebook.addPhrase(
          PhraseDraft(
            text: text,
            translation: text,
            sourceCode: 'en',
            targetCode: 'pt',
          ),
          lisbon.id,
        )).phrase;
        await phrasebook.removePhrase(phrase.id, lisbon.id);
      }
      var backup = await phrasebook.exportBackup();
      expect((backup['tombstones']! as Map).keys, ['p:4', 'p:3']);
      expect(backup['memberTombstones'], hasLength(2));

      now = now.add(const Duration(days: 181));
      await phrasebook.renameCollection(lisbon.id, 'Lisboa');
      backup = await phrasebook.exportBackup();
      expect(backup['tombstones'], isEmpty);
      expect(backup['memberTombstones'], isEmpty);
    });
  });

  group('changes', () {
    test('fire after changes and when favourites change', () async {
      final phrasebook = repo();
      var count = 0;
      final subscription = phrasebook.changes.listen((_) => count++);
      await phrasebook.createCollection('Lisbon');
      await pumpEventQueue();
      expect(count, 1);
      favorites.set([favoriteEntry('1')]);
      await pumpEventQueue();
      expect(count, 2);
      await subscription.cancel();
      await phrasebook.dispose();
      favorites.set(const []);
    });

    test('a failed change fires nothing', () async {
      final phrasebook = repo();
      var count = 0;
      phrasebook.changes.listen((_) => count++);
      await expectLater(
        phrasebook.renameCollection('c:none', 'x'),
        throwsArgumentError,
      );
      await pumpEventQueue();
      expect(count, 0);
    });
  });

  group('backup', () {
    test('exports the user data, not the last collection', () async {
      final phrasebook = repo();
      final lisbon = await phrasebook.createCollection('Lisbon');
      await phrasebook.addPhrase(_hello, lisbon.id);
      await phrasebook.updateNote('h:1', 'note');
      final backup = await phrasebook.exportBackup();
      expect(backup.keys, {
        'collections',
        'phrases',
        'favoriteNotes',
        'tombstones',
        'memberTombstones',
      });
      expect(jsonDecode(jsonEncode(backup)), backup);
    });

    test('replace makes the backup the phrasebook', () async {
      final source = repo();
      final lisbon = await source.createCollection('Lisbon');
      await source.addPhrase(_hello, lisbon.id);
      final backup = await source.exportBackup();

      store = MemoryStore();
      keys = MemoryStore();
      final target = repo();
      final porto = await target.createCollection('Porto');
      await target.addPhrase(_thanks, porto.id);
      await target.restoreBackup(
        jsonDecode(jsonEncode(backup)),
        version: 1,
        merge: false,
      );
      final collections = await target.collections();
      expect(collections.map((c) => c.name), ['', 'Lisbon']);
      expect(
        (await target.phrases(collectionId: lisbon.id)).single.text,
        'Hello',
      );
      // The last collection stays this device's (here: gone).
      expect(await target.lastCollectionId(), isNull);
    });

    test('refuses newer versions and other data', () async {
      final phrasebook = repo();
      expect(
        () => phrasebook.restoreBackup(const {}, version: 2, merge: true),
        throwsFormatException,
      );
      expect(
        () => phrasebook.restoreBackup(const {}, version: 0, merge: true),
        throwsFormatException,
      );
      expect(
        () => phrasebook.restoreBackup('x', version: 1, merge: true),
        throwsFormatException,
      );
      expect(
        () => phrasebook.restoreBackup(
          const {'collections': <Object?>[]},
          version: 1,
          merge: true,
        ),
        throwsFormatException,
      );
    });

    group('merge', () {
      /// The phrasebook of another device (its own store and key), made by
      /// [build], as a backup.
      Future<Map<String, Object?>> other(
        Future<void> Function(PhrasebookRepository other) build,
      ) async {
        final mine = (store, keys);
        store = MemoryStore();
        keys = MemoryStore();
        final device = repo();
        await build(device);
        final backup = await device.exportBackup();
        (store, keys) = mine;
        return jsonDecode(jsonEncode(backup)) as Map<String, Object?>;
      }

      test('keeps both sides and the newer copy of each', () async {
        final phrasebook = repo();
        final lisbon = await phrasebook.createCollection('Lisbon');
        final hello = (await phrasebook.addPhrase(_hello, lisbon.id)).phrase;
        await phrasebook.updateNote('h:1', 'mine, older');
        final shared = await phrasebook.exportBackup();

        tick();
        final backup = await other((device) async {
          await device.restoreBackup(shared, version: 1, merge: false);
          await device.updateNote(hello.id, 'theirs, newer');
          await device.updateNote('h:1', 'theirs on the favourite');
          final porto = await device.createCollection('Porto');
          await device.addPhrase(_thanks, porto.id);
        });
        tick();
        await phrasebook.renameCollection(lisbon.id, 'Lisboa');

        await phrasebook.restoreBackup(backup, version: 1, merge: true);
        final collections = await phrasebook.collections();
        expect(collections.map((c) => c.name), ['', 'Lisboa', 'Porto']);
        final merged = await phrasebook.phrase(hello.id);
        expect(merged!.note, 'theirs, newer');
        expect(await phrasebook.phrases(), hasLength(2));
        final backupAfter = await phrasebook.exportBackup();
        final notes = backupAfter['favoriteNotes']! as Map<String, Object?>;
        expect(
          (notes['h:1']! as Map<String, Object?>)['note'],
          'theirs on the favourite',
        );
      });

      test('a deletion on either side wins over older copies', () async {
        final phrasebook = repo();
        final lisbon = await phrasebook.createCollection('Lisbon');
        final porto = await phrasebook.createCollection('Porto');
        final hello = (await phrasebook.addPhrase(_hello, lisbon.id)).phrase;
        final thanks = (await phrasebook.addPhrase(_thanks, porto.id)).phrase;
        final shared = await phrasebook.exportBackup();

        tick();
        // The other device deletes Porto (and its phrase).
        final backup = await other((device) async {
          await device.restoreBackup(shared, version: 1, merge: false);
          await device.deleteCollection(porto.id);
        });
        // This one deletes Hello.
        tick();
        await phrasebook.removePhrase(hello.id, lisbon.id);

        await phrasebook.restoreBackup(backup, version: 1, merge: true);
        expect((await phrasebook.collections()).map((c) => c.id), [
          'favorites',
          lisbon.id,
        ]);
        expect(await phrasebook.phrase(hello.id), isNull);
        expect(await phrasebook.phrase(thanks.id), isNull);
      });

      test('a phrase edited after it was deleted elsewhere stays', () async {
        final phrasebook = repo();
        final lisbon = await phrasebook.createCollection('Lisbon');
        final hello = (await phrasebook.addPhrase(_hello, lisbon.id)).phrase;
        final shared = await phrasebook.exportBackup();
        tick();
        final backup = await other((device) async {
          await device.restoreBackup(shared, version: 1, merge: false);
          await device.removePhrase(hello.id, lisbon.id);
        });
        tick();
        await phrasebook.updateNote(hello.id, 'still needed');
        await phrasebook.restoreBackup(backup, version: 1, merge: true);
        expect((await phrasebook.phrase(hello.id))!.note, 'still needed');
        final restored = await phrasebook.exportBackup();
        expect(restored['tombstones'], isEmpty);
      });

      test("a collection keeps both copies' phrases, less those taken out "
          'after the other copy changed', () async {
        final phrasebook = repo();
        final lisbon = await phrasebook.createCollection('Lisbon');
        final porto = await phrasebook.createCollection('Porto');
        final hello = (await phrasebook.addPhrase(_hello, lisbon.id)).phrase;
        await phrasebook.copyPhrase(hello.id, porto.id);
        final shared = await phrasebook.exportBackup();

        // Here: Thank you goes into Lisbon.
        tick();
        final thanks = (await phrasebook.addPhrase(_thanks, lisbon.id)).phrase;
        // There, later: Hello is moved out of Lisbon (it stays in Porto),
        // and a new phrase goes in.
        tick();
        final backup = await other((device) async {
          await device.restoreBackup(shared, version: 1, merge: false);
          await device.removePhrase(hello.id, lisbon.id);
          await device.addPhrase(
            const PhraseDraft(
              text: 'Goodbye',
              translation: 'Adeus',
              sourceCode: 'en',
              targetCode: 'pt',
            ),
            lisbon.id,
          );
        });

        await phrasebook.restoreBackup(backup, version: 1, merge: true);
        final phrases = await phrasebook.phrases(collectionId: lisbon.id);
        expect(phrases.map((p) => p.text), ['Goodbye', 'Thank you']);
        expect(await phrasebook.phrase(thanks.id), isNotNull);
        expect(
          (await phrasebook.phrases(collectionId: porto.id)).single.id,
          hello.id,
        );
      });

      test('an older copy of a newer local collection adds its phrases '
          'back unless they were taken out since', () async {
        final phrasebook = repo();
        final lisbon = await phrasebook.createCollection('Lisbon');
        final porto = await phrasebook.createCollection('Porto');
        final hello = (await phrasebook.addPhrase(_hello, lisbon.id)).phrase;
        await phrasebook.copyPhrase(hello.id, porto.id);
        final older = jsonDecode(jsonEncode(await phrasebook.exportBackup()));
        tick();
        await phrasebook.removePhrase(hello.id, lisbon.id);
        await phrasebook.restoreBackup(older, version: 1, merge: true);
        expect(await phrasebook.phrases(collectionId: lisbon.id), isEmpty);
      });
    });
  });
}

class _FailingFavorites implements PhrasebookFavorites {
  @override
  Stream<void> get changes => const Stream.empty();

  @override
  Future<List<HistoryEntry>> favorites() => Future.error(StateError('no'));

  @override
  Future<void> remove(String historyId) async {}

  @override
  Future<void> restore(String historyId) async {}
}
