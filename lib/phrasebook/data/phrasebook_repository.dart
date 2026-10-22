import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/data/history_cipher.dart';
import 'package:mozhi/history/data/history_repository.dart'
    show HistoryRepository;
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/phrasebook/data/phrasebook_favorites.dart';
import 'package:mozhi/phrasebook/data/starter_phrasebooks.dart';
import 'package:mozhi/phrasebook/models/phrase.dart';
import 'package:mozhi/phrasebook/models/phrase_collection.dart';
import 'package:mozhi/phrasebook/models/phrase_draft.dart';

export 'package:mozhi/phrasebook/data/phrasebook_favorites.dart';
export 'package:mozhi/phrasebook/data/starter_phrasebooks.dart';
export 'package:mozhi/phrasebook/models/phrase.dart';
export 'package:mozhi/phrasebook/models/phrase_collection.dart';
export 'package:mozhi/phrasebook/models/phrase_draft.dart';
export 'package:mozhi/phrasebook/models/starter_phrasebook.dart';

/// The stored phrasebook exists but cannot be decrypted: its key is
/// missing ([keyMissing]: the app's secure storage was reset) or does not
/// fit (the data is damaged). It is left untouched: every change is
/// refused with this exception until it can be read again or
/// [PhrasebookRepository.discardUnreadable] sets it aside.
class PhrasebookUnreadableException implements Exception {
  const new({required this.keyMissing});

  final bool keyMissing;

  @override
  String toString() =>
      'PhrasebookUnreadableException('
      '${keyMissing ? 'key missing' : 'bad key or data'})';
}

/// The phrasebook key could not be stored durably (it did not read back),
/// so nothing is encrypted with it.
class PhrasebookKeyUnavailableException implements Exception {
  const new();

  @override
  String toString() => 'PhrasebookKeyUnavailableException';
}

/// What [PhrasebookRepository.addPhrase] (and copying a phrase) did: the
/// phrase in the collection, and whether it was [added] (false when the
/// collection had it already).
class PhraseAddition extends Equatable {
  const new({required this.phrase, required this.added});

  final Phrase phrase;
  final bool added;

  @override
  List<Object?> get props => [phrase, added];
}

/// What [PhrasebookRepository.removePhrase] took out, to put it back with
/// [PhrasebookRepository.restorePhrase] (Undo).
class PhraseRemoval extends Equatable {
  const new({
    required this.phrase,
    required this.collectionId,
    required this.index,
    required this.deleted,
  });

  final Phrase phrase;
  final String collectionId;

  /// Its position in the collection.
  final int index;

  /// Whether the phrase was deleted (it was in no other collection).
  final bool deleted;

  @override
  List<Object?> get props => [phrase, collectionId, index, deleted];
}

/// What [PhrasebookRepository.deleteCollection] deleted, to put it back
/// with [PhrasebookRepository.restoreCollection] (Undo).
class CollectionDeletion extends Equatable {
  const new({
    required this.collection,
    required this.index,
    required this.phrases,
  });

  final PhraseCollection collection;

  /// Its position among the user's collections.
  final int index;

  /// Its phrases that were in no other collection (deleted with it).
  final List<Phrase> phrases;

  @override
  List<Object?> get props => [collection, index, phrases];
}

/// The phrasebook: the user's named collections of phrases, the built-in
/// Favorites collection (the history favourites, [favorites]) and the
/// installed starter phrasebooks ([starter]), all on the device.
///
/// Storage: the user's collections and phrases (with the notes on
/// favourites and the deletion tombstones) are one JSON document,
/// encrypted with AES-256-GCM ([HistoryCipher], as the history) and stored
/// under [storageKey] in [store]. Its random 256-bit key is kept in
/// [keyStore] under [keyStorageKey] (the history's key handling: secure
/// storage on Android, the browser storage of [store] on the web, see
/// [HistoryRepository.platformKeyStore]), created on the first write and
/// checked to read back. A document that cannot be decrypted is never
/// overwritten ([PhrasebookUnreadableException], [discardUnreadable]).
///
/// Phrases ([Phrase.id]):
/// * favourites (`h:<history id>`) are read from [favorites] each time;
///   taking one out of Favorites un-stars it in the history, and a note on
///   one is kept here;
/// * starter phrases (`s:<pack>:<id>`) are read from [starter]: read-only,
///   they can be copied into a collection;
/// * every other phrase is stored here and belongs to one collection or
///   more: copying a stored phrase adds the same phrase to another
///   collection, and a phrase taken out of its last collection is deleted.
///
/// Deleted phrases and collections leave a tombstone (their id and the
/// time), and a phrase taken out of a collection a membership tombstone,
/// so that merging a backup or a synced copy ([restoreBackup] with
/// `merge`) does not bring them back. Tombstones
/// are kept for [tombstoneMaxAge], at most [maxTombstones] of each kind.
///
/// Operations are serialised and written through; [changes] fires after
/// each change (and when the favourites or the starter phrasebooks
/// change).
class PhrasebookRepository {
  new({
    KeyValueStore? store,
    this._keyStore,
    HistoryCipher? cipher,
    PhrasebookFavorites? favorites,
    this.starter,
    DateTime Function()? clock,
    String Function()? newId,
    this.maxTombstones = 5000,
    this.tombstoneMaxAge = const Duration(days: 180),
  }) : store = store ?? PreferencesStore(),
       cipher = cipher ?? const HistoryCipher(),
       _clock = clock ?? DateTime.now,
       _newId = newId ?? _randomId {
    _starterSubscription = starter?.changes.listen(_changed);
    if (favorites != null) attachFavorites(favorites);
  }

  /// Key of the encrypted phrasebook in [store].
  static const storageKey = 'phrasebook.v1';

  /// Key in [store] that an unreadable phrasebook is moved to by
  /// [discardUnreadable].
  static const unreadableStorageKey = 'phrasebook.v1.unreadable';

  /// Key of the phrasebook's encryption key in [keyStore].
  static const keyStorageKey = 'phrasebook.key';

  /// The version of [exportBackup]'s data.
  static const backupVersion = 1;

  final KeyValueStore store;

  /// Where the encryption key is kept (see the class docs).
  late final KeyValueStore keyStore =
      _keyStore ?? HistoryRepository.platformKeyStore(store);
  final KeyValueStore? _keyStore;
  final HistoryCipher cipher;

  /// The history favourites (the Favorites collection); none until they
  /// are given ([attachFavorites]).
  PhrasebookFavorites? get favorites => _favorites;
  PhrasebookFavorites? _favorites;

  /// The installed starter phrasebooks; none without it.
  final StarterPhrasebooks? starter;

  /// Tombstones kept at most, of phrases and collections and of
  /// memberships each.
  final int maxTombstones;

  /// How long tombstones are kept.
  final Duration tombstoneMaxAge;

  final DateTime Function() _clock;
  final String Function() _newId;
  final StreamController<void> _changes = StreamController.broadcast();
  StreamSubscription<void>? _starterSubscription;
  StreamSubscription<void>? _favoritesSubscription;

  _Book? _book;
  Uint8List? _key;
  Future<void> _lock = Future.value();

  static final Random _random = Random.secure();

  static String _randomId() {
    final time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final random = List.generate(
      6,
      (_) => _random.nextInt(36).toRadixString(36),
    ).join();
    return '$time$random';
  }

  /// Fires after every change of the phrasebook, the favourites or the
  /// starter phrasebooks.
  Stream<void> get changes => _changes.stream;

  void _changed([void _]) {
    if (!_changes.isClosed) _changes.add(null);
  }

  // Reading ------------------------------------------------------------------

  /// Every collection: Favorites first (also when empty), then the user's
  /// in their order, then the installed starter phrasebooks by name.
  Future<List<PhraseCollection>> collections() async {
    final book = await _synchronized(_current);
    final favorites = await _favoritePhrases(book);
    return List.unmodifiable([
      _favoritesCollection(favorites),
      ...book.collections,
      ...await _starterCollections(),
    ]);
  }

  /// The collection [id], or null.
  Future<PhraseCollection?> collection(String id) async =>
      (await collections()).where((c) => c.id == id).firstOrNull;

  /// The phrases of the collection [collectionId] in its order (oldest
  /// first); [PhraseCollection.favoritesId]: the favourites, newest first.
  /// Null: every phrase (the stored ones, the favourites and the starter
  /// phrases), each once.
  Future<List<Phrase>> phrases({String? collectionId}) async {
    final book = await _synchronized(_current);
    if (collectionId == null) {
      return List.unmodifiable([
        ...book.phrases.values,
        ...await _favoritePhrases(book),
        for (final pack in await _starterPacks()) ...pack,
      ]);
    }
    if (collectionId == PhraseCollection.favoritesId) {
      return List.unmodifiable(await _favoritePhrases(book));
    }
    if (PhraseCollection.starterPackOf(collectionId) case final packId?) {
      final pack = await starter?.load(packId);
      return pack?.phrases ?? const [];
    }
    final collection = book.collectionById(collectionId);
    if (collection == null) return const [];
    return List.unmodifiable([
      for (final id in collection.phraseIds) ?book.phrases[id],
    ]);
  }

  /// The phrase [id], or null when there is none.
  Future<Phrase?> phrase(String id) async {
    final book = await _synchronized(_current);
    if (Phrase.historyIdOf(id) != null) {
      return (await _favoritePhrases(book))
          .where((p) => p.id == id)
          .firstOrNull;
    }
    if (Phrase.starterPackOf(id) case final packId?) {
      final pack = await starter?.load(packId);
      return pack?.phrases.where((p) => p.id == id).firstOrNull;
    }
    return book.phrases[id];
  }

  /// The ids of the user's collections that have a phrase like [draft]
  /// (the same languages, text and translation).
  Future<Set<String>> collectionsWith(PhraseDraft draft) async {
    final book = await _synchronized(_current);
    final key = draft.contentKey;
    final ids = {
      for (final phrase in book.phrases.values)
        if (phrase.contentKey == key) phrase.id,
    };
    return {
      for (final collection in book.collections)
        if (collection.phraseIds.any(ids.contains)) collection.id,
    };
  }

  /// The collection phrases were last added to, if it still exists.
  Future<String?> lastCollectionId() async {
    final book = await _synchronized(_current);
    final id = book.lastCollectionId;
    return id != null && book.collectionById(id) != null ? id : null;
  }

  // Collections --------------------------------------------------------------

  /// Creates a collection named [name] (trimmed, not empty), first among
  /// the user's, with the language pair [sourceCode] → [targetCode] when
  /// given.
  Future<PhraseCollection> createCollection(
    String name, {
    String? sourceCode,
    String? targetCode,
  }) async {
    final trimmed = _name(name);
    return await _mutate((book) {
      final now = _clock();
      final created = PhraseCollection(
        id: '${PhraseCollection.storedIdPrefix}${_newId()}',
        name: trimmed,
        sourceCode: sourceCode,
        targetCode: targetCode,
        phraseIds: const [],
        createdAt: now,
        updatedAt: now,
      );
      book.collections.insert(0, created);
      return created;
    });
  }

  /// Renames the user's collection [id].
  Future<void> renameCollection(String id, String name) async {
    final trimmed = _name(name);
    await _mutate((book) {
      final index = book.indexOfEditable(id);
      book.collections[index] = book.collections[index].copyWith(
        name: trimmed,
        updatedAt: _clock(),
      );
    });
  }

  /// Sets the language pair of the user's collection [id] (null: none).
  Future<void> setCollectionLanguages(
    String id, {
    required String? sourceCode,
    required String? targetCode,
  }) => _mutate((book) {
    final index = book.indexOfEditable(id);
    book.collections[index] = book.collections[index].copyWith(
      sourceCode: () => sourceCode,
      targetCode: () => targetCode,
      updatedAt: _clock(),
    );
  });

  /// Puts the user's collections in the order of [ids]; collections not
  /// in [ids] follow in their current order.
  Future<void> reorderCollections(List<String> ids) => _mutate((book) {
    final position = {for (final (i, id) in ids.indexed) id: i};
    final current = [...book.collections];
    final sorted = [...current]
      ..sort((a, b) {
        final pa = position[a.id] ?? ids.length + current.indexOf(a);
        final pb = position[b.id] ?? ids.length + current.indexOf(b);
        return pa.compareTo(pb);
      });
    book.collections
      ..clear()
      ..addAll(sorted);
  });

  /// Deletes the collection [id] with its phrases that are in no other
  /// collection, and returns what it deleted (for [restoreCollection]);
  /// a starter phrebook ([PhraseCollection.starter]) is uninstalled, and
  /// null is returned. Throws [ArgumentError] for Favorites or an unknown
  /// id.
  Future<CollectionDeletion?> deleteCollection(String id) async {
    if (PhraseCollection.starterPackOf(id) case final packId?) {
      await starter?.delete(packId);
      return null;
    }
    return await _mutate((book) {
      final index = book.indexOfEditable(id);
      final collection = book.collections.removeAt(index);
      final now = _clock();
      book.tombstones[id] = now;
      final deleted = <Phrase>[];
      for (final phraseId in collection.phraseIds) {
        if (book.isInAnyCollection(phraseId)) continue;
        final phrase = book.phrases.remove(phraseId);
        if (phrase == null) continue;
        deleted.add(phrase);
        book.tombstones[phraseId] = now;
      }
      return CollectionDeletion(
        collection: collection,
        index: index,
        phrases: List.unmodifiable(deleted),
      );
    });
  }

  /// Puts back a collection [deleteCollection] deleted, with its phrases.
  Future<void> restoreCollection(CollectionDeletion deletion) =>
      _mutate((book) {
        final now = _clock();
        final collection = deletion.collection;
        book.tombstones.remove(collection.id);
        for (final phrase in deletion.phrases) {
          book.tombstones.remove(phrase.id);
          book.phrases[phrase.id] = phrase.copyWith(updatedAt: now);
        }
        if (book.collectionById(collection.id) != null) return;
        book.collections.insert(
          deletion.index.clamp(0, book.collections.length),
          collection.copyWith(updatedAt: now),
        );
      });

  // Phrases ------------------------------------------------------------------

  /// Adds [draft] to the user's collection [collectionId] (at its end) and
  /// remembers the collection as the last used ([lastCollectionId]).
  ///
  /// A stored phrase with the same languages, text and translation is
  /// reused (the same phrase in several collections), so nothing is added
  /// twice. Throws [ArgumentError] for an empty draft or a collection that
  /// is not the user's.
  Future<PhraseAddition> addPhrase(
    PhraseDraft draft,
    String collectionId,
  ) async {
    if (draft.isEmpty) {
      throw ArgumentError.value(draft, 'draft', 'needs text and translation');
    }
    return await _mutate((book) {
      final addition = _add(book, draft, collectionId);
      book.lastCollectionId = collectionId;
      return addition;
    });
  }

  /// Adds every phrase of [drafts] (empty ones are skipped) to the user's
  /// collection [collectionId] in one write, as [addPhrase] does; returns
  /// how many were added.
  Future<int> importPhrases(String collectionId, List<PhraseDraft> drafts) =>
      _mutate((book) {
        book.indexOfEditable(collectionId);
        var added = 0;
        for (final draft in drafts) {
          if (draft.isEmpty) continue;
          if (_add(book, draft, collectionId).added) added++;
        }
        return added;
      });

  /// Adds the phrase [phraseId] to the user's collection [collectionId]:
  /// a stored phrase itself, a favourite or a starter phrase as a copy
  /// (with its note). Remembers the collection as the last used.
  Future<PhraseAddition> copyPhrase(
    String phraseId,
    String collectionId,
  ) async {
    final phrase = await this.phrase(phraseId);
    if (phrase == null) throw ArgumentError.value(phraseId, 'phraseId');
    if (!phrase.isStored) {
      return await addPhrase(PhraseDraft.fromPhrase(phrase), collectionId);
    }
    return await _mutate((book) {
      final stored = book.phrases[phraseId];
      if (stored == null) throw ArgumentError.value(phraseId, 'phraseId');
      final addition = PhraseAddition(
        phrase: stored,
        added: _addMember(book, collectionId, phraseId),
      );
      book.lastCollectionId = collectionId;
      return addition;
    });
  }

  /// Moves the stored phrase [phraseId] from the collection [from] to the
  /// user's collection [to] (where it goes at the end).
  Future<void> movePhrase(
    String phraseId, {
    required String from,
    required String to,
  }) => _mutate((book) {
    if (book.phrases[phraseId] == null) {
      throw ArgumentError.value(phraseId, 'phraseId');
    }
    if (from == to) return;
    _addMember(book, to, phraseId);
    _removeMember(book, from, phraseId);
    book.lastCollectionId = to;
  });

  /// Takes the phrase [phraseId] out of the collection [collectionId]:
  /// out of Favorites, it is un-starred in the history; a stored phrase
  /// that is in no other collection then is deleted. Returns what
  /// [restorePhrase] needs to undo it, or null when nothing was removed.
  /// Throws [ArgumentError] for a starter collection.
  Future<PhraseRemoval?> removePhrase(
    String phraseId,
    String collectionId,
  ) async {
    if (collectionId == PhraseCollection.favoritesId) {
      final phrase = await this.phrase(phraseId);
      final historyId = Phrase.historyIdOf(phraseId);
      if (phrase == null || historyId == null) return null;
      await favorites?.remove(historyId);
      return PhraseRemoval(
        phrase: phrase,
        collectionId: collectionId,
        index: 0,
        deleted: false,
      );
    }
    return await _mutate<PhraseRemoval?>((book) {
      final index = book.indexOfEditable(collectionId);
      final position = book.collections[index].phraseIds.indexOf(phraseId);
      final phrase = book.phrases[phraseId];
      if (position == -1 || phrase == null) return null;
      _removeMember(book, collectionId, phraseId);
      final deleted = !book.isInAnyCollection(phraseId);
      if (deleted) {
        book.phrases.remove(phraseId);
        book.tombstones[phraseId] = _clock();
      }
      return PhraseRemoval(
        phrase: phrase,
        collectionId: collectionId,
        index: position,
        deleted: deleted,
      );
    });
  }

  /// Undoes [removePhrase]: the phrase is back at its place (a favourite
  /// is starred again).
  Future<void> restorePhrase(PhraseRemoval removal) async {
    if (removal.collectionId == PhraseCollection.favoritesId) {
      final historyId = Phrase.historyIdOf(removal.phrase.id);
      if (historyId != null) await favorites?.restore(historyId);
      return;
    }
    await _mutate((book) {
      final phrase = removal.phrase;
      final now = _clock();
      if (removal.deleted || book.phrases[phrase.id] == null) {
        book.tombstones.remove(phrase.id);
        book.phrases[phrase.id] = phrase.copyWith(updatedAt: now);
      }
      final index = book.collections.indexWhere(
        (c) => c.id == removal.collectionId,
      );
      if (index == -1) return;
      final collection = book.collections[index];
      if (collection.phraseIds.contains(phrase.id)) return;
      final ids = [...collection.phraseIds]
        ..insert(removal.index.clamp(0, collection.length), phrase.id);
      book.collections[index] = collection.copyWith(
        phraseIds: ids,
        updatedAt: now,
      );
      book.memberTombstones.remove(_Book.memberKey(collection.id, phrase.id));
    });
  }

  /// Sets the note of the phrase [phraseId] (trimmed; empty removes it).
  /// Throws [ArgumentError] for a starter phrase or an unknown id.
  Future<void> updateNote(String phraseId, String note) async {
    final trimmed = note.trim();
    if (Phrase.starterPackOf(phraseId) != null) {
      throw ArgumentError.value(phraseId, 'phraseId', 'is read-only');
    }
    await _mutate((book) {
      final now = _clock();
      if (Phrase.historyIdOf(phraseId) != null) {
        book.favoriteNotes[phraseId] = FavoriteNote(
          note: trimmed,
          updatedAt: now,
        );
        return;
      }
      final phrase = book.phrases[phraseId];
      if (phrase == null) throw ArgumentError.value(phraseId, 'phraseId');
      book.phrases[phraseId] = phrase.copyWith(note: trimmed, updatedAt: now);
    });
  }

  // Data ---------------------------------------------------------------------

  /// Deletes everything this repository stores: the phrasebook, a copy
  /// set aside by [discardUnreadable], its key and the starter
  /// phrasebooks.
  Future<void> deleteAll() async {
    await _synchronized(() async {
      _book = _Book();
      _key = null;
      await store.delete(storageKey);
      await store.delete(unreadableStorageKey);
      await keyStore.delete(keyStorageKey);
    });
    await starter?.deleteAll();
    _changed();
  }

  /// Moves a phrasebook that cannot be decrypted aside (to
  /// [unreadableStorageKey]) and starts a new, empty one. Does nothing to
  /// a readable phrasebook.
  Future<void> discardUnreadable() async {
    await _synchronized(() async {
      try {
        await _current();
      } on PhrasebookUnreadableException {
        final raw = await store.read(storageKey);
        if (raw != null) {
          await store.write(unreadableStorageKey, raw);
          await store.delete(storageKey);
        }
        _book = _Book();
      }
    });
    _changed();
  }

  /// How much the phrasebook takes in [store] (UTF-16 code units of the
  /// stored values, without the starter phrasebooks).
  Future<int> storedLength() async {
    final values = [
      await store.read(storageKey),
      await store.read(unreadableStorageKey),
    ];
    return values.fold<int>(0, (sum, value) => sum + (value?.length ?? 0));
  }

  /// The user's phrasebook for a backup ([backupVersion]): collections,
  /// stored phrases, notes on favourites and tombstones (not the starter
  /// phrasebooks, which can be downloaded again, nor the favourites
  /// themselves, which are the history's).
  Future<Map<String, Object?>> exportBackup() async {
    final book = await _synchronized(_current);
    return book.toJson(includeLastCollection: false);
  }

  /// Applies [data] written by [exportBackup] at [version]:
  ///
  /// * [merge] false: the backup becomes the phrasebook;
  /// * [merge] true: per phrase, collection and note the newer copy wins
  ///   (`updatedAt`); a tombstone in either copy at least as new as the
  ///   other copy deletes it; entries on one side only are kept. A
  ///   collection's phrases are both copies' (in the newer copy's order),
  ///   less those the other copy took out after the newer copy changed.
  ///
  /// Throws [FormatException] for a newer [version] or data that is not a
  /// phrasebook backup (nothing changes then). Replacing a phrasebook that
  /// cannot be decrypted sets it aside first ([discardUnreadable]);
  /// merging into one throws [PhrasebookUnreadableException].
  Future<void> restoreBackup(
    Object? data, {
    required int version,
    required bool merge,
  }) async {
    if (version < 1 || version > backupVersion) {
      throw FormatException('Unsupported phrasebook backup version', version);
    }
    if (data is! Map) {
      throw const FormatException('Expected a phrasebook backup object');
    }
    final incoming = _Book.fromJson(Map<String, Object?>.from(data));
    // Replacing needs nothing of a phrasebook that cannot be read: it is
    // set aside (as [discardUnreadable] does), so a backup can bring the
    // phrasebook back after the key was lost. A merge needs it, and fails.
    if (!merge) await discardUnreadable();
    await _mutate((book) {
      final next = merge ? _Book.merged(book, incoming) : incoming;
      final last = book.lastCollectionId;
      book
        ..collections.clear()
        ..collections.addAll(next.collections)
        ..phrases.clear()
        ..phrases.addAll(next.phrases)
        ..favoriteNotes.clear()
        ..favoriteNotes.addAll(next.favoriteNotes)
        ..tombstones.clear()
        ..tombstones.addAll(next.tombstones)
        ..memberTombstones.clear()
        ..memberTombstones.addAll(next.memberTombstones)
        ..lastCollectionId = last;
    });
  }

  /// Makes [source] the Favorites collection, in place of any earlier
  /// one: the app creates the repository at startup (for backups) and
  /// gives it its history's favourites once the `HistoryCubit` exists.
  void attachFavorites(PhrasebookFavorites source) {
    unawaited(_favoritesSubscription?.cancel());
    _favorites = source;
    _favoritesSubscription = source.changes.listen(_changed);
    _changed();
  }

  /// Stops forwarding the favourites' and starter phrasebooks' changes and
  /// closes [changes].
  Future<void> dispose() async {
    await _favoritesSubscription?.cancel();
    await _starterSubscription?.cancel();
    await _changes.close();
  }

  // Internals ----------------------------------------------------------------

  static String _name(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(name, 'name', 'is empty');
    return trimmed;
  }

  PhraseAddition _add(_Book book, PhraseDraft draft, String collectionId) {
    book.indexOfEditable(collectionId);
    final key = draft.contentKey;
    final existing = book.phrases.values
        .where((p) => p.contentKey == key)
        .firstOrNull;
    if (existing != null) {
      return PhraseAddition(
        phrase: existing,
        added: _addMember(book, collectionId, existing.id),
      );
    }
    final phrase = draft.toPhrase(
      '${Phrase.storedIdPrefix}${_newId()}',
      _clock(),
    );
    book.phrases[phrase.id] = phrase;
    _addMember(book, collectionId, phrase.id);
    return PhraseAddition(phrase: phrase, added: true);
  }

  /// Adds [phraseId] to the end of the user's collection [collectionId];
  /// false when it was there already.
  bool _addMember(_Book book, String collectionId, String phraseId) {
    final index = book.indexOfEditable(collectionId);
    final collection = book.collections[index];
    if (collection.phraseIds.contains(phraseId)) return false;
    book.collections[index] = collection.copyWith(
      phraseIds: [...collection.phraseIds, phraseId],
      updatedAt: _clock(),
    );
    book.memberTombstones.remove(_Book.memberKey(collectionId, phraseId));
    return true;
  }

  void _removeMember(_Book book, String collectionId, String phraseId) {
    final index = book.indexOfEditable(collectionId);
    final collection = book.collections[index];
    if (!collection.phraseIds.contains(phraseId)) return;
    final now = _clock();
    book.collections[index] = collection.copyWith(
      phraseIds: [
        for (final id in collection.phraseIds)
          if (id != phraseId) id,
      ],
      updatedAt: now,
    );
    book.memberTombstones[_Book.memberKey(collectionId, phraseId)] = now;
  }

  Future<List<Phrase>> _favoritePhrases(_Book book) async {
    final source = favorites;
    if (source == null) return const [];
    final List<HistoryEntry> entries;
    try {
      entries = await source.favorites();
    } on Object {
      return const [];
    }
    return [for (final entry in entries) _favoritePhrase(entry, book)];
  }

  static Phrase _favoritePhrase(HistoryEntry entry, _Book book) {
    final draft = PhraseDraft.fromHistory(entry);
    final id = Phrase.favoriteId(entry.id);
    final note = book.favoriteNotes[id];
    final updatedAt = note != null && note.updatedAt.isAfter(entry.createdAt)
        ? note.updatedAt
        : entry.createdAt;
    return Phrase(
      id: id,
      text: draft.text,
      translation: draft.translation,
      sourceCode: draft.sourceCode,
      targetCode: draft.targetCode,
      createdAt: entry.createdAt,
      updatedAt: updatedAt,
      note: note?.note ?? '',
      origin: PhraseOrigin.favorite,
    );
  }

  static PhraseCollection _favoritesCollection(List<Phrase> favorites) {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    final newest = favorites.isEmpty
        ? epoch
        : favorites
              .map((p) => p.updatedAt)
              .reduce((a, b) => a.isAfter(b) ? a : b);
    return PhraseCollection(
      id: PhraseCollection.favoritesId,
      name: '',
      phraseIds: List.unmodifiable([for (final p in favorites) p.id]),
      createdAt: epoch,
      updatedAt: newest,
    );
  }

  /// The phrases of each installed starter phrasebook that can be read.
  Future<List<List<Phrase>>> _starterPacks() async {
    final source = starter;
    if (source == null) return const [];
    final packs = <List<Phrase>>[];
    try {
      for (final info in await source.installed()) {
        final pack = await source.load(info.id);
        if (pack != null) packs.add(pack.phrases);
      }
    } on Object {
      return packs;
    }
    return packs;
  }

  Future<List<PhraseCollection>> _starterCollections() async {
    final source = starter;
    if (source == null) return const [];
    final collections = <PhraseCollection>[];
    try {
      for (final info in await source.installed()) {
        final pack = await source.load(info.id);
        if (pack == null) continue;
        collections.add(
          PhraseCollection(
            id: PhraseCollection.starterId(info.id),
            name: info.name,
            sourceCode: pack.baseLanguage,
            targetCode: pack.language,
            phraseIds: List.unmodifiable([for (final p in pack.phrases) p.id]),
            createdAt: info.installedAt,
            updatedAt: info.installedAt,
            starter: true,
          ),
        );
      }
    } on Object {
      return collections;
    }
    return collections;
  }

  /// Applies [change] to a copy of the phrasebook, writes it and returns
  /// what [change] returned (results are returned rather than assigned
  /// from the closure: see the wave's dart2js notes).
  Future<T> _mutate<T>(T Function(_Book book) change) async {
    final result = await _synchronized(() async {
      final next = (await _current()).copy();
      final value = change(next);
      next.prune(
        now: _clock(),
        maxAge: tombstoneMaxAge,
        maxCount: maxTombstones,
      );
      await _write(next);
      _book = next;
      return value;
    });
    _changed();
    return result;
  }

  Future<_Book> _current() async {
    if (_book case final book?) return book;
    return _book = await _readStored();
  }

  Future<_Book> _readStored() async {
    final raw = await store.read(storageKey);
    if (raw == null) return _Book();
    if (!cipher.isEncrypted(raw)) return _Book.decodeLenient(raw);
    final key = _key ?? await _readKey();
    if (key == null) {
      throw const PhrasebookUnreadableException(keyMissing: true);
    }
    final String json;
    try {
      json = await cipher.decrypt(raw, key);
    } on HistoryCipherException {
      throw const PhrasebookUnreadableException(keyMissing: false);
    }
    _key = key;
    return _Book.decodeLenient(json);
  }

  Future<Uint8List?> _readKey() async {
    final value = await keyStore.read(keyStorageKey);
    if (value == null) return null;
    try {
      final key = base64Decode(value);
      return key.length == HistoryCipher.keyLength ? key : null;
    } on FormatException {
      return null;
    }
  }

  /// The stored key, or a new one stored first (it must read back).
  Future<Uint8List> _writeKey() async {
    if (_key case final key?) return key;
    if (await _readKey() case final key?) return _key = key;
    final key = await cipher.newKey();
    final encoded = base64Encode(key);
    await keyStore.write(keyStorageKey, encoded);
    if (await keyStore.read(keyStorageKey) != encoded) {
      throw const PhrasebookKeyUnavailableException();
    }
    return _key = key;
  }

  Future<void> _write(_Book book) async {
    final key = await _writeKey();
    final encrypted = await cipher.encrypt(jsonEncode(book.toJson()), key);
    await store.write(storageKey, encrypted);
  }

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

/// The note on a favourite (kept in the phrasebook, since history entries
/// have none), with when it was written.
@immutable
class FavoriteNote extends Equatable {
  const new({required this.note, required this.updatedAt});

  final String note;
  final DateTime updatedAt;

  @override
  List<Object?> get props => [note, updatedAt];
}

/// The stored phrasebook document (mutable: [PhrasebookRepository] changes
/// a [copy]).
class _Book {
  new({
    List<PhraseCollection>? collections,
    Map<String, Phrase>? phrases,
    Map<String, FavoriteNote>? favoriteNotes,
    Map<String, DateTime>? tombstones,
    Map<String, DateTime>? memberTombstones,
    this.lastCollectionId,
  }) : collections = collections ?? [],
       phrases = phrases ?? {},
       favoriteNotes = favoriteNotes ?? {},
       tombstones = tombstones ?? {},
       memberTombstones = memberTombstones ?? {};

  /// Reads [json] (see [toJson]): invalid collections, phrases, notes and
  /// tombstones are skipped; a collection keeps only the ids of phrases
  /// that exist. Throws [FormatException] when [json] has neither
  /// collections nor phrases lists.
  factory fromJson(Map<String, Object?> json) {
    final collectionsJson = json['collections'];
    final phrasesJson = json['phrases'];
    if (collectionsJson is! List || phrasesJson is! List) {
      throw const FormatException('Not a phrasebook');
    }
    final phrases = <String, Phrase>{};
    for (final item in phrasesJson) {
      if (item is! Map) continue;
      try {
        final phrase = Phrase.fromJson(Map<String, dynamic>.from(item));
        if (phrase.isStored) phrases[phrase.id] = phrase;
      } on FormatException {
        continue;
      }
    }
    final collections = <PhraseCollection>[];
    final ids = <String>{};
    for (final item in collectionsJson) {
      if (item is! Map) continue;
      try {
        final collection = PhraseCollection.fromJson(
          Map<String, dynamic>.from(item),
        );
        if (!collection.id.startsWith(PhraseCollection.storedIdPrefix) ||
            !ids.add(collection.id)) {
          continue;
        }
        collections.add(
          collection.copyWith(
            phraseIds: [
              for (final id in collection.phraseIds)
                if (phrases.containsKey(id)) id,
            ],
          ),
        );
      } on FormatException {
        continue;
      }
    }
    final notes = <String, FavoriteNote>{};
    if (json['favoriteNotes'] case final Map<dynamic, dynamic> map) {
      for (final MapEntry(:key, :value) in map.entries) {
        if (key is! String || Phrase.historyIdOf(key) == null) continue;
        if (value case {'note': final String note}) {
          final time = Phrase.parseTime(value['updatedAt']);
          if (time != null) {
            notes[key] = FavoriteNote(note: note, updatedAt: time);
          }
        }
      }
    }
    return _Book(
      collections: collections,
      phrases: phrases,
      favoriteNotes: notes,
      tombstones: _times(json['tombstones']),
      memberTombstones: _times(json['memberTombstones']),
      lastCollectionId: switch (json['lastCollectionId']) {
        final String id when id.isNotEmpty => id,
        _ => null,
      },
    );
  }

  /// [raw] JSON, or an empty book when it is not a phrasebook.
  factory decodeLenient(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is Map) return _Book.fromJson(Map<String, Object?>.from(json));
    } on FormatException {
      // Unreadable: an empty book.
    }
    return _Book();
  }

  /// [local] merged with [incoming] (see
  /// [PhrasebookRepository.restoreBackup]).
  factory merged(_Book local, _Book incoming) {
    final tombstones = _newest(local.tombstones, incoming.tombstones);
    final memberTombstones = _newest(
      local.memberTombstones,
      incoming.memberTombstones,
    );
    bool buried(String id, DateTime updatedAt) {
      final deletedAt = tombstones[id];
      return deletedAt != null && !deletedAt.isBefore(updatedAt);
    }

    final phrases = <String, Phrase>{};
    for (final id in {...local.phrases.keys, ...incoming.phrases.keys}) {
      final a = local.phrases[id];
      final b = incoming.phrases[id];
      final newer = a == null
          ? b!
          : b == null || !b.updatedAt.isAfter(a.updatedAt)
          ? a
          : b;
      if (buried(id, newer.updatedAt)) continue;
      phrases[id] = newer;
      tombstones.remove(id);
    }

    final byIdLocal = {for (final c in local.collections) c.id: c};
    final byIdIncoming = {for (final c in incoming.collections) c.id: c};
    final order = [
      ...local.collections.map((c) => c.id),
      for (final c in incoming.collections)
        if (!byIdLocal.containsKey(c.id)) c.id,
    ];
    final collections = <PhraseCollection>[];
    for (final id in order) {
      final a = byIdLocal[id];
      final b = byIdIncoming[id];
      final PhraseCollection newer;
      final PhraseCollection? older;
      if (a == null || (b != null && b.updatedAt.isAfter(a.updatedAt))) {
        newer = b!;
        older = a;
      } else {
        newer = a;
        older = b;
      }
      if (buried(id, newer.updatedAt)) continue;
      tombstones.remove(id);
      final members = [
        ...newer.phraseIds,
        if (older != null)
          for (final phraseId in older.phraseIds)
            if (!newer.phraseIds.contains(phraseId) &&
                !_takenOutAfter(
                  memberTombstones[memberKey(id, phraseId)],
                  older.updatedAt,
                ))
              phraseId,
      ];
      collections.add(
        newer.copyWith(
          phraseIds: [
            for (final phraseId in members)
              if (phrases.containsKey(phraseId)) phraseId,
          ],
        ),
      );
    }

    final notes = <String, FavoriteNote>{...local.favoriteNotes};
    for (final MapEntry(:key, :value) in incoming.favoriteNotes.entries) {
      final mine = notes[key];
      if (mine == null || value.updatedAt.isAfter(mine.updatedAt)) {
        notes[key] = value;
      }
    }
    return _Book(
      collections: collections,
      phrases: phrases,
      favoriteNotes: notes,
      tombstones: tombstones,
      memberTombstones: memberTombstones,
      lastCollectionId: local.lastCollectionId,
    );
  }

  final List<PhraseCollection> collections;
  final Map<String, Phrase> phrases;
  final Map<String, FavoriteNote> favoriteNotes;

  /// Deleted phrase and collection ids, with when they were deleted.
  final Map<String, DateTime> tombstones;

  /// Phrases taken out of collections ([memberKey]), with when.
  final Map<String, DateTime> memberTombstones;
  String? lastCollectionId;

  /// The key of [phraseId]'s membership of [collectionId] in
  /// [memberTombstones].
  static String memberKey(String collectionId, String phraseId) =>
      '$collectionId $phraseId';

  /// Whether a membership tombstone at [takenOutAt] (if any) is at least
  /// as new as the copy of the collection that still has the phrase.
  static bool _takenOutAfter(DateTime? takenOutAt, DateTime copyUpdatedAt) =>
      takenOutAt != null && !takenOutAt.isBefore(copyUpdatedAt);

  static Map<String, DateTime> _newest(
    Map<String, DateTime> a,
    Map<String, DateTime> b,
  ) {
    final result = {...a};
    for (final MapEntry(:key, :value) in b.entries) {
      final mine = result[key];
      if (mine == null || value.isAfter(mine)) result[key] = value;
    }
    return result;
  }

  static Map<String, DateTime> _times(Object? json) {
    final result = <String, DateTime>{};
    if (json is! Map) return result;
    for (final MapEntry(:key, :value) in json.entries) {
      final time = Phrase.parseTime(value);
      if (key is String && key.isNotEmpty && time != null) result[key] = time;
    }
    return result;
  }

  PhraseCollection? collectionById(String id) =>
      collections.where((c) => c.id == id).firstOrNull;

  /// The index of the user's collection [id]. Throws [ArgumentError] when
  /// it is not one of the user's (Favorites, a starter phrasebook, an
  /// unknown id).
  int indexOfEditable(String id) {
    final index = collections.indexWhere((c) => c.id == id);
    if (index == -1) {
      throw ArgumentError.value(id, 'collectionId', 'is not a collection');
    }
    return index;
  }

  bool isInAnyCollection(String phraseId) =>
      collections.any((c) => c.phraseIds.contains(phraseId));

  _Book copy() => _Book(
    collections: [...collections],
    phrases: {...phrases},
    favoriteNotes: {...favoriteNotes},
    tombstones: {...tombstones},
    memberTombstones: {...memberTombstones},
    lastCollectionId: lastCollectionId,
  );

  /// Drops tombstones older than [maxAge] and all but the newest
  /// [maxCount] of each kind.
  void prune({
    required DateTime now,
    required Duration maxAge,
    required int maxCount,
  }) {
    final cutoff = now.subtract(maxAge);
    for (final map in [tombstones, memberTombstones]) {
      map.removeWhere((_, time) => time.isBefore(cutoff));
      if (map.length <= maxCount) continue;
      final newest = map.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      map
        ..clear()
        ..addEntries(newest.take(maxCount));
    }
  }

  Map<String, Object?> toJson({bool includeLastCollection = true}) => {
    'collections': [for (final c in collections) c.toJson()],
    'phrases': [for (final p in phrases.values) p.toJson()],
    'favoriteNotes': {
      for (final MapEntry(:key, :value) in favoriteNotes.entries)
        key: {
          'note': value.note,
          'updatedAt': value.updatedAt.toUtc().toIso8601String(),
        },
    },
    'tombstones': {
      for (final MapEntry(:key, :value) in tombstones.entries)
        key: value.toUtc().toIso8601String(),
    },
    'memberTombstones': {
      for (final MapEntry(:key, :value) in memberTombstones.entries)
        key: value.toUtc().toIso8601String(),
    },
    if (includeLastCollection && lastCollectionId != null)
      'lastCollectionId': lastCollectionId,
  };
}
