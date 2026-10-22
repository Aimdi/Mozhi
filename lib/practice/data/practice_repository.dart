import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/data/history_cipher.dart';
import 'package:mozhi/history/data/history_repository.dart'
    show HistoryRepository;
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/practice/models/practice_card.dart';
import 'package:mozhi/practice/models/practice_item.dart';
import 'package:mozhi/practice/models/practice_settings.dart';

/// The stored practice progress exists but cannot be decrypted: its key is
/// missing ([keyMissing]: the app's secure storage was reset) or does not
/// fit (the data is damaged). It is left untouched: every change is
/// refused with this exception until [PracticeRepository.discardUnreadable]
/// sets it aside.
class PracticeUnreadableException implements Exception {
  const new({required this.keyMissing});

  final bool keyMissing;

  @override
  String toString() =>
      'PracticeUnreadableException('
      '${keyMissing ? 'key missing' : 'bad key or data'})';
}

/// The practice key could not be stored durably (it did not read back),
/// so nothing is encrypted with it.
class PracticeKeyUnavailableException implements Exception {
  const new();

  @override
  String toString() => 'PracticeKeyUnavailableException';
}

/// Everything practice needs at one moment: the phrasebook's collections,
/// the phrases of the practised ones as cards ([items]: one per phrase and
/// practised direction, new ones included) and the [settings].
@immutable
class PracticeDeck {
  new({
    required List<PhraseCollection> collections,
    required List<PracticeItem> items,
    required this.settings,
    required Map<String, int> collectionSizes,
    required this.introducedToday,
    required this.userLanguage,
  }) : collections = List.unmodifiable(collections),
       items = List.unmodifiable(items),
       collectionSizes = Map.unmodifiable(collectionSizes);

  /// Every collection of the phrasebook that has phrases.
  final List<PhraseCollection> collections;

  /// The cards of the practised collections in the practised directions,
  /// in the phrasebook's order.
  final List<PracticeItem> items;
  final PracticeSettings settings;

  /// How many phrases each collection has (by id).
  final Map<String, int> collectionSizes;

  /// How many new cards were first reviewed today (local time).
  final int introducedToday;

  /// The user's language ([userLanguageOf]).
  final String userLanguage;

  /// How many new cards may still be introduced today.
  int get newAllowance =>
      math.max(0, settings.newCardsPerDay - introducedToday);

  /// The cards already learned that are due at [now].
  List<PracticeItem> due(DateTime now) => [
    for (final item in items)
      if (item.card.isDue(now)) item,
  ];

  /// The new cards that may be introduced now: at most [newAllowance], one
  /// per phrase (none of the phrases in [except], e.g. those reviewed in
  /// the same session), oldest phrases first, recognise before produce,
  /// in the phrasebook's order among phrases of the same time.
  List<PracticeItem> newCards({Set<String> except = const {}}) {
    final order = {for (final (i, item) in items.indexed) item.id: i};
    final fresh =
        items
            .where(
              (item) => item.card.isNew && !except.contains(item.phrase.id),
            )
            .toList()
          ..sort((a, b) {
            final byTime = a.phrase.createdAt.compareTo(b.phrase.createdAt);
            if (byTime != 0) return byTime;
            final byDirection = a.direction.index.compareTo(b.direction.index);
            if (byDirection != 0) return byDirection;
            return order[a.id]!.compareTo(order[b.id]!);
          });
    final phrases = <String>{};
    return [
      for (final item in fresh)
        if (phrases.length < newAllowance && phrases.add(item.phrase.id)) item,
    ];
  }

  /// Learned cards due later, soonest first.
  DateTime? nextDue(DateTime now) {
    DateTime? next;
    for (final item in items) {
      if (item.card.isNew || !item.card.fsrs.due.isAfter(now)) continue;
      final due = item.card.fsrs.due;
      if (next == null || due.isBefore(next)) next = due;
    }
    return next;
  }
}

/// The practice progress (the FSRS state of every card reviewed so far)
/// and settings, on this device, built on the phrasebook
/// ([PhrasebookRepository], which it only reads).
///
/// * Cards are made from the phrases of the practised collections
///   ([PracticeSettings.collectionIds]), one per practised direction; a
///   card is only stored once it was reviewed (new cards cost nothing).
///   Their texts are read from the phrases, so cards follow edits.
/// * Cards whose phrase was deleted are removed (with a tombstone) when
///   the [deck] is read: a favourite's when the favourites can be read
///   and do not have it (none listed may mean the history is locked or
///   loading, so they are kept), a starter phrase's when its phrasebook
///   is installed and does not have it (an uninstalled one may come back,
///   and its progress with it).
///
/// Storage: one JSON document (settings, cards, tombstones), encrypted
/// with AES-256-GCM ([HistoryCipher], as the history and the phrasebook)
/// under [storageKey] in [store]; its random 256-bit key under
/// [keyStorageKey] in [keyStore] (secure storage on Android, the browser
/// storage of [store] on the web: [HistoryRepository.platformKeyStore]),
/// created on the first write and checked to read back. A document that
/// cannot be decrypted is never overwritten
/// ([PracticeUnreadableException], [discardUnreadable]).
///
/// Operations are serialised and written through; [changes] fires after
/// each change and [dueCount] follows the cards due for review.
class PracticeRepository {
  new({
    required this.phrasebook,
    KeyValueStore? store,
    this._keyStore,
    HistoryCipher? cipher,
    DateTime Function()? clock,
    this.maxTombstones = 5000,
    this.tombstoneMaxAge = const Duration(days: 180),
  }) : store = store ?? PreferencesStore(),
       cipher = cipher ?? const HistoryCipher(),
       _clock = clock ?? DateTime.now {
    _phrasebookChanges = phrasebook.changes.listen((_) => _scheduleRefresh());
  }

  /// Key of the encrypted practice document in [store].
  static const storageKey = 'practice.v1';

  /// Key in [store] an unreadable document is moved to by
  /// [discardUnreadable].
  static const unreadableStorageKey = 'practice.v1.unreadable';

  /// Key of the encryption key in [keyStore].
  static const keyStorageKey = 'practice.key';

  /// Bound into the stored document as GCM associated data, so that it is
  /// never taken for another value encrypted with [HistoryCipher].
  static const associatedData = 'mozhi.practice';

  /// The version of the stored document and of [exportBackup]'s data.
  static const backupVersion = 1;

  final PhrasebookRepository phrasebook;
  final KeyValueStore store;

  /// Where the encryption key is kept (see the class docs).
  late final KeyValueStore keyStore =
      _keyStore ?? HistoryRepository.platformKeyStore(store);
  final KeyValueStore? _keyStore;
  final HistoryCipher cipher;

  /// Tombstones kept at most.
  final int maxTombstones;

  /// How long tombstones are kept.
  final Duration tombstoneMaxAge;

  final DateTime Function() _clock;
  final StreamController<void> _changes = StreamController.broadcast();
  final ValueNotifier<int> _dueCount = ValueNotifier(0);
  late final StreamSubscription<void> _phrasebookChanges;
  _Progress? _progress;
  Uint8List? _key;
  Future<void> _lock = Future.value();
  Timer? _refreshTimer;
  bool _disposed = false;

  /// Fires after every change of the progress or the settings.
  Stream<void> get changes => _changes.stream;

  /// How many learned cards of the practised collections are due for
  /// review now (new cards are not counted: they are no chore). 0 until
  /// [refreshDueCount] (or another read) ran.
  ValueListenable<int> get dueCount => _dueCount;

  /// The settings (the defaults when nothing is stored).
  Future<PracticeSettings> settings() async =>
      (await _synchronized(_current)).settings;

  /// Stores [settings] (stamped with the time).
  Future<void> saveSettings(PracticeSettings settings) => _mutate(
    (progress) =>
        progress.settings = settings.copyWith(updatedAt: _clock().toUtc()),
  );

  /// The deck for [appLanguage] (the app's language, see [userLanguageOf])
  /// with [settings] (default: the stored ones), at the current time;
  /// removes the cards of deleted phrases (see the class docs).
  ///
  /// [onlyCollection] practises that collection alone (a collection's
  /// Practice button), whatever the settings say.
  Future<PracticeDeck> deck({
    required String appLanguage,
    PracticeSettings? settings,
    String? onlyCollection,
  }) async {
    final now = _clock();
    final collections = await phrasebook.collections();
    final everything = await phrasebook.phrases();
    final progress = await _synchronized(_current);
    final chosen = settings ?? progress.settings;
    final sizes = <String, int>{};
    final memberships = <String, Phrase>{};
    final listed = <PhraseCollection>[];
    for (final collection in collections) {
      if (collection.phraseIds.isEmpty) continue;
      listed.add(collection);
      sizes[collection.id] = collection.length;
      final practised = onlyCollection == null
          ? chosen.includes(collection.id)
          : collection.id == onlyCollection;
      if (!practised) continue;
      for (final phrase in await phrasebook.phrases(
        collectionId: collection.id,
      )) {
        if (phrase.text.trim().isEmpty || phrase.translation.trim().isEmpty) {
          continue;
        }
        memberships.putIfAbsent(phrase.id, () => phrase);
      }
    }
    await _removeOrphans(collections, everything);
    final cards = (await _synchronized(_current)).cards;
    final user = userLanguageOf(memberships.values, appLanguage);
    final items = <PracticeItem>[
      for (final phrase in memberships.values)
        for (final direction in CardDirection.values)
          if (chosen.directions.contains(direction))
            PracticeItem(
              card:
                  cards[PracticeCard.idOf(phrase.id, direction)] ??
                  PracticeCard.fresh(phrase.id, direction, now),
              phrase: phrase,
              foreignIsSource: learnedSideOf(phrase, user),
            ),
    ];
    final deck = PracticeDeck(
      collections: listed,
      items: items,
      settings: chosen,
      collectionSizes: sizes,
      introducedToday: _introducedOn(cards.values, now),
      userLanguage: user,
    );
    if (onlyCollection == null && settings == null) {
      _setDueCount(deck.due(now).length);
    }
    return deck;
  }

  /// Recounts [dueCount] (e.g. when the menu that shows it opens). Never
  /// throws: on a failure the count stays.
  Future<int> refreshDueCount() async {
    try {
      final settings = await this.settings();
      final now = _clock();
      final collections = await phrasebook.collections();
      final cards = (await _synchronized(_current)).cards;
      final phraseIds = <String>{
        for (final collection in collections)
          if (settings.includes(collection.id)) ...collection.phraseIds,
      };
      var count = 0;
      for (final card in cards.values) {
        if (settings.directions.contains(card.direction) &&
            phraseIds.contains(card.phraseId) &&
            card.isDue(now)) {
          count++;
        }
      }
      _setDueCount(count);
    } on Object {
      // Shown as it was.
    }
    return _dueCount.value;
  }

  /// Stores [card] (a review, or a card put back by undo: a new card
  /// forgets the progress, it is new again).
  Future<void> saveCard(PracticeCard card) => _mutate((progress) {
    if (card.isNew) {
      progress.cards.remove(card.id);
    } else {
      progress.cards[card.id] = card;
    }
    progress.tombstones.remove(card.id);
  }, refresh: true);

  /// The stored (reviewed) cards, by id.
  Future<Map<String, PracticeCard>> cards() async =>
      Map.unmodifiable((await _synchronized(_current)).cards);

  /// How many cards were reviewed at least once.
  Future<int> reviewedCount() async =>
      (await _synchronized(_current)).cards.length;

  /// Deletes everything this repository stores: the progress, the
  /// settings, a copy set aside by [discardUnreadable] and the key.
  Future<void> deleteAll() async {
    await _synchronized(() async {
      _progress = _Progress();
      _key = null;
      await store.delete(storageKey);
      await store.delete(unreadableStorageKey);
      await keyStore.delete(keyStorageKey);
    });
    _setDueCount(0);
    _changed();
  }

  /// Moves a document that cannot be decrypted aside (to
  /// [unreadableStorageKey]) and starts over. Does nothing to a readable
  /// one.
  Future<void> discardUnreadable() async {
    await _synchronized(() async {
      try {
        await _current();
      } on PracticeUnreadableException {
        final raw = await store.read(storageKey);
        if (raw != null) {
          await store.write(unreadableStorageKey, raw);
          await store.delete(storageKey);
        }
        _progress = _Progress();
      }
    });
    _changed();
  }

  /// The progress and settings for a backup ([backupVersion]).
  Future<Map<String, Object?>> exportBackup() async =>
      (await _synchronized(_current)).toJson();

  /// How many cards [data] (from [exportBackup]) holds; null when it is
  /// not practice data of a known version.
  static int? countBackupCards(Object? data, {required int version}) {
    if (version < 1 || version > backupVersion) return null;
    if (data is! Map || data['cards'] is! List) return null;
    return (data['cards'] as List).length;
  }

  /// Applies [data] written by [exportBackup] at [version]:
  ///
  /// * [merge] false: the backup becomes the progress and the settings;
  /// * [merge] true: per card the newer copy wins (`updatedAt`); a
  ///   tombstone in either copy at least as new as the other copy deletes
  ///   it; cards on one side only are kept; the newer settings win.
  ///
  /// Throws [FormatException] for a newer [version] or data that is not
  /// practice data (nothing changes then).
  Future<void> restoreBackup(
    Object? data, {
    required int version,
    required bool merge,
  }) async {
    if (version < 1 || version > backupVersion) {
      throw FormatException('Unsupported practice backup version', version);
    }
    if (data is! Map) {
      throw const FormatException('Expected a practice backup object');
    }
    final incoming = _Progress.fromJson(Map<String, Object?>.from(data));
    await _mutate((progress) {
      final next = merge ? _Progress.merged(progress, incoming) : incoming;
      progress
        ..settings = next.settings
        ..cards.clear()
        ..cards.addAll(next.cards)
        ..tombstones.clear()
        ..tombstones.addAll(next.tombstones);
    }, refresh: true);
  }

  /// Stops listening to the phrasebook and closes [changes].
  Future<void> dispose() async {
    _disposed = true;
    _refreshTimer?.cancel();
    await _phrasebookChanges.cancel();
    await _changes.close();
    _dueCount.dispose();
  }

  // Internals ----------------------------------------------------------------

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _setDueCount(int count) {
    if (!_disposed) _dueCount.value = count;
  }

  /// Recounts [dueCount] soon (once for a burst of phrasebook changes).
  void _scheduleRefresh() {
    if (_disposed) return;
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(refreshDueCount());
    });
  }

  /// How many of [cards] were first reviewed on [now]'s local day.
  static int _introducedOn(Iterable<PracticeCard> cards, DateTime now) {
    final today = now.toLocal();
    var count = 0;
    for (final card in cards) {
      final first = card.firstReviewedAt?.toLocal();
      if (first != null &&
          first.year == today.year &&
          first.month == today.month &&
          first.day == today.day) {
        count++;
      }
    }
    return count;
  }

  /// Removes the stored cards whose phrase is gone (see the class docs).
  Future<void> _removeOrphans(
    List<PhraseCollection> collections,
    List<Phrase> everything,
  ) async {
    final existing = {for (final phrase in everything) phrase.id};
    final favorites = collections
        .where((collection) => collection.isFavorites)
        .firstOrNull;
    final starters = {
      for (final collection in collections)
        ?PhraseCollection.starterPackOf(collection.id): collection.phraseIds
            .toSet(),
    };
    bool gone(String phraseId) {
      if (existing.contains(phraseId)) return false;
      if (Phrase.historyIdOf(phraseId) != null) {
        return favorites != null && favorites.phraseIds.isNotEmpty;
      }
      if (Phrase.starterPackOf(phraseId) case final pack?) {
        final ids = starters[pack];
        return ids != null && ids.isNotEmpty && !ids.contains(phraseId);
      }
      return true;
    }

    final progress = await _synchronized(_current);
    final orphans = [
      for (final card in progress.cards.values)
        if (gone(card.phraseId)) card.id,
    ];
    if (orphans.isEmpty) return;
    await _mutate((progress) {
      final time = _clock().toUtc();
      for (final id in orphans) {
        progress.cards.remove(id);
        progress.tombstones[id] = time;
      }
    });
  }

  Future<_Progress> _current() async {
    if (_progress case final progress?) return progress;
    final raw = await store.read(storageKey);
    if (raw == null) return _progress = _Progress();
    final key = _key ?? await _readKey();
    if (key == null) {
      throw const PracticeUnreadableException(keyMissing: true);
    }
    final String json;
    try {
      json = await cipher.decrypt(raw, key, aad: associatedData);
    } on HistoryCipherException {
      throw const PracticeUnreadableException(keyMissing: false);
    }
    _key = key;
    try {
      final decoded = jsonDecode(json);
      return _progress = decoded is Map
          ? _Progress.fromJson(Map<String, Object?>.from(decoded))
          : _Progress();
    } on FormatException {
      return _progress = _Progress();
    }
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

  /// The key to encrypt with: the stored one, or a new one stored first
  /// (it must read back). Only called once the stored data was read.
  Future<Uint8List> _writeKey() async {
    if (_key case final key?) return key;
    if (await _readKey() case final key?) return _key = key;
    final key = await cipher.newKey();
    final encoded = base64Encode(key);
    await keyStore.write(keyStorageKey, encoded);
    if (await keyStore.read(keyStorageKey) != encoded) {
      throw const PracticeKeyUnavailableException();
    }
    return _key = key;
  }

  Future<void> _mutate(
    void Function(_Progress progress) change, {
    bool refresh = false,
  }) async {
    await _synchronized(() async {
      final current = await _current();
      final next = current.copy();
      change(next);
      next.prune(_clock().toUtc(), tombstoneMaxAge, maxTombstones);
      final key = await _writeKey();
      await store.write(
        storageKey,
        await cipher.encrypt(
          jsonEncode(next.toJson()),
          key,
          aad: associatedData,
        ),
      );
      _progress = next;
    });
    _changed();
    if (refresh) unawaited(refreshDueCount());
  }

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

/// The stored document: settings, reviewed cards and tombstones.
final class _Progress {
  new({
    this.settings = const PracticeSettings(),
    Map<String, PracticeCard>? cards,
    Map<String, DateTime>? tombstones,
  }) : cards = cards ?? {},
       tombstones = tombstones ?? {};

  factory fromJson(Map<String, Object?> json) {
    final settings = json['settings'];
    final cards = <String, PracticeCard>{};
    if (json['cards'] case final List<Object?> list) {
      for (final item in list) {
        if (item is! Map) continue;
        try {
          final card = PracticeCard.fromJson(Map<String, Object?>.from(item));
          cards[card.id] = card;
        } on Object {
          // An invalid card is skipped.
        }
      }
    }
    final tombstones = <String, DateTime>{};
    if (json['tombstones'] case final Map<Object?, Object?> map) {
      for (final MapEntry(:key, :value) in map.entries) {
        final time = value is String ? DateTime.tryParse(value) : null;
        if (key is String && time != null) tombstones[key] = time.toUtc();
      }
    }
    return _Progress(
      settings: settings is Map
          ? PracticeSettings.fromJson(Map<String, Object?>.from(settings))
          : const PracticeSettings(),
      cards: cards,
      tombstones: tombstones,
    );
  }

  /// [local] and [incoming] merged (see `PracticeRepository.restoreBackup`).
  factory merged(_Progress local, _Progress incoming) {
    final tombstones = {...local.tombstones};
    for (final MapEntry(:key, :value) in incoming.tombstones.entries) {
      final mine = tombstones[key];
      if (mine == null || value.isAfter(mine)) tombstones[key] = value;
    }
    final cards = <String, PracticeCard>{};
    for (final id in {...local.cards.keys, ...incoming.cards.keys}) {
      final a = local.cards[id];
      final b = incoming.cards[id];
      final newer = a == null
          ? b!
          : b == null || !b.updatedAt.isAfter(a.updatedAt)
          ? a
          : b;
      final deleted = tombstones[id];
      if (deleted != null && !deleted.isBefore(newer.updatedAt)) continue;
      cards[id] = newer;
      tombstones.remove(id);
    }
    final mine = local.settings.updatedAt;
    final theirs = incoming.settings.updatedAt;
    final settings = theirs != null && (mine == null || theirs.isAfter(mine))
        ? incoming.settings
        : local.settings;
    return _Progress(settings: settings, cards: cards, tombstones: tombstones);
  }

  PracticeSettings settings;
  final Map<String, PracticeCard> cards;
  final Map<String, DateTime> tombstones;

  _Progress copy() => _Progress(
    settings: settings,
    cards: {...cards},
    tombstones: {...tombstones},
  );

  /// Drops tombstones older than [maxAge] at [now], and the oldest beyond
  /// [max].
  void prune(DateTime now, Duration maxAge, int max) {
    final cutoff = now.subtract(maxAge);
    tombstones.removeWhere((_, time) => time.isBefore(cutoff));
    if (tombstones.length <= max) return;
    final sorted = tombstones.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    tombstones
      ..clear()
      ..addEntries(sorted.take(max));
  }

  Map<String, Object?> toJson() => {
    'version': PracticeRepository.backupVersion,
    'settings': settings.toJson(),
    'cards': [for (final card in cards.values) card.toJson()],
    'tombstones': {
      for (final MapEntry(:key, :value) in tombstones.entries)
        key: value.toUtc().toIso8601String(),
    },
  };
}
