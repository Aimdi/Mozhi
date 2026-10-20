import 'dart:async';
import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/data/history_cipher.dart';
import 'package:mozhi/history/models/history_entry.dart';

export 'history_cipher.dart';

/// The stored history exists but cannot be decrypted: its key is missing
/// ([keyMissing], e.g. the app's secure storage was reset, or the history
/// came from another phone) or does not fit (the data is damaged).
///
/// The history is left untouched: [HistoryRepository.load] tries again
/// (the key may come back) and [HistoryRepository.discardUnreadable] sets
/// it aside to start a new one. Until then every change is refused with
/// this exception, so nothing overwrites it.
class HistoryUnreadableException implements Exception {
  const new({required this.keyMissing});

  /// Whether the key is missing (rather than not fitting the data).
  final bool keyMissing;

  @override
  String toString() =>
      'HistoryUnreadableException('
      '${keyMissing ? 'key missing' : 'bad key or data'})';
}

/// The history key could not be stored durably (it did not read back), so
/// nothing is encrypted with it.
class HistoryKeyUnavailableException implements Exception {
  const new();

  @override
  String toString() => 'HistoryKeyUnavailableException';
}

/// Outcome of [HistoryRepository.importJson].
class HistoryImport extends Equatable {
  const new({
    required this.entries,
    required this.added,
    required this.expired,
  });

  /// The history after the import, newest first.
  final List<HistoryEntry> entries;

  /// How many imported entries were added to the history (entries whose id
  /// was already there, and those evicted by the size limits, are not).
  final int added;

  /// How many new imported entries were left out for being older than the
  /// retention `maxAge` (history auto-delete).
  final int expired;

  @override
  List<Object?> get props => [entries, added, expired];
}

/// Local-only history of translations and dictionary look-ups
/// ([HistoryEntry.kind]), newest first, encrypted at rest.
///
/// Storage: the history JSON list is encrypted with AES-256-GCM
/// ([HistoryCipher]) and stored under [storageKey] in [store]. The random
/// 256-bit key is kept in [keyStore] under [keyStorageKey] (base64) and
/// created on the first write. Plaintext JSON stored by older versions under
/// the same key is read once and rewritten encrypted (on [load], or by the
/// first change), keeping its entries.
///
/// [keyStore] must be durable: the history is unreadable without the key.
/// It defaults to [platformKeyStore]: the Android Keystore-backed secure
/// storage, and on the web the browser storage of [store] itself, since the
/// web app's secure storage only lasts for the tab. There the key sits next
/// to the data, so the encryption only keeps the history from being read in
/// plain text out of the browser profile; scripts of the same origin and
/// anyone with access to the profile can still decrypt it.
///
/// When encrypted history is stored but its key is missing or does not fit,
/// [load] (and every change) throws [HistoryUnreadableException] and leaves
/// the data alone: [load] may be retried, [discardUnreadable] moves the data
/// aside (to [unreadableStorageKey]) and starts a new history. A failing
/// [keyStore] is reported as is; the history is then neither read (when
/// encrypted) nor written, never stored unencrypted.
///
/// Size limits (favourites are never evicted):
/// * at most [maxEntries] non-favourite entries (translations and
///   dictionary look-ups together);
/// * the stored JSON stays within [maxStoredLength] UTF-16 code units by
///   evicting the oldest non-favourites (preferences share one quota with
///   the settings, e.g. browser `localStorage` on the web);
/// * `text` and `translation` longer than [maxTextLength] are truncated
///   (ending with `…`) when added.
///
/// When the store reports a full quota on a write, older non-favourites
/// are evicted and the write is retried.
///
/// [add] merges a translation with the newest entry instead of duplicating
/// it when that is a translation too, both have the same source, target and
/// engine and either
/// * the trimmed texts are equal, unless the newest entry is a favourite
///   with a different translation (a starred translation is never
///   overwritten), or
/// * the newest entry is not a favourite, was created within
///   [refinementWindow] and one trimmed text is a prefix of the other
///   (typing refinements of instant translate).
///
/// Dictionary look-ups ([HistoryEntry.isDictionary]) are never merged with
/// translations. A look-up of a word already in the history with the same
/// languages ([HistoryEntry.isSameLookUp], wherever it is in the list)
/// replaces that entry: the new look-up becomes the newest entry, keeping
/// the existing id and favourite, so repeated look-ups update one entry.
/// [restore] merges a look-up with one of the same word the same way.
///
/// Entries kept only as favourites ([HistoryEntry.favoriteOnly], starred
/// while history was paused) are deleted by [toggleFavorite] instead of
/// being kept as ordinary entries. An entry merged with an ordinary one is
/// ordinary.
///
/// Retention (history auto-delete): [load], [add] and [importJson] take an
/// optional `maxAge` and then also drop non-favourite entries created more
/// than `maxAge` ago; [prune] applies a (new) `maxAge` right away.
/// Favourites are always kept. [load] writes the pruned history back when
/// it dropped expired entries.
///
/// [toggleFavorite], [delete], [clear], [restore] and [restoreFavorite]
/// apply no caps (and no retention), so an un-starred or restored entry
/// survives until the next [add] / [load].
///
/// [store] defaults to [PreferencesStore], [cipher] to [HistoryCipher] and
/// `clock` (the current time for retention) to [DateTime.now]. Operations
/// are serialised and every mutation is written through; the returned lists
/// are unmodifiable. Invalid stored entries are skipped, unreadable
/// (decrypted or legacy) JSON loads as empty.
class HistoryRepository {
  new({
    KeyValueStore? store,
    this._keyStore,
    HistoryCipher? cipher,
    this.maxEntries = 1000,
    this.maxStoredLength = 1000000,
    this.maxTextLength = 20000,
    this.refinementWindow = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : assert(maxTextLength > 0, 'maxTextLength must be positive'),
       store = store ?? PreferencesStore(),
       cipher = cipher ?? const HistoryCipher(),
       _clock = clock ?? DateTime.now;

  /// Key of the encrypted history in [store] (plaintext JSON when written
  /// by an older version).
  static const storageKey = 'history.v1';

  /// Key in [store] that unreadable history is moved to by
  /// [discardUnreadable].
  static const unreadableStorageKey = 'history.v1.unreadable';

  /// Key of the history encryption key in [keyStore].
  static const keyStorageKey = 'history.key';

  /// Where the history key is kept by default: secure storage (Android
  /// Keystore), or on the web [preferences] (the browser storage the
  /// history is in; see the class docs).
  static KeyValueStore platformKeyStore(KeyValueStore preferences) =>
      kIsWeb ? preferences : SecureStore();

  /// How often a write that failed for a full quota is retried (each time
  /// with the older half of the non-favourites evicted).
  static const _quotaRetries = 4;

  final KeyValueStore store;

  /// Where the encryption key is kept (see the class docs).
  late final KeyValueStore keyStore = _keyStore ?? platformKeyStore(store);
  final KeyValueStore? _keyStore;
  final HistoryCipher cipher;
  final int maxEntries;

  /// Maximum length (UTF-16 code units) of the history JSON before it is
  /// encrypted (the stored value is about 4/3 of its UTF-8 size); only
  /// favourites may exceed it.
  final int maxStoredLength;

  /// Maximum stored length of an entry's `text` and `translation` each.
  final int maxTextLength;

  /// How far apart in time an entry may be from the newest one to be
  /// treated as a typing refinement of it (see [add]).
  final Duration refinementWindow;

  final DateTime Function() _clock;

  List<HistoryEntry>? _entries;
  Future<void> _lock = Future.value();

  /// The key, once read or created.
  Uint8List? _key;

  /// Encoded JSON per entry (entries are immutable).
  final Expando<String> _encoded = Expando();

  /// Reads the history from [store] (refreshing the in-memory copy).
  ///
  /// With [maxAge], non-favourites created more than [maxAge] ago are
  /// dropped and, if there were any, the result is written back. Plaintext
  /// history of older versions is written back encrypted. A failing write
  /// is ignored: the next mutation writes again.
  ///
  /// Throws [HistoryUnreadableException] when the stored history cannot
  /// be decrypted (see the class docs), and storage errors as they are.
  Future<List<HistoryEntry>> load({Duration? maxAge}) =>
      _synchronized(() async {
        _entries = null;
        final (entries, :legacy) = await _readStored();
        final kept = _withoutExpired(entries, maxAge);
        var next = _capped(kept);
        if (legacy || kept.length != entries.length) {
          try {
            next = await _write(next);
          } on Object {
            // Keep the list in memory; the next mutation writes it.
          }
        }
        return _entries = next;
      });

  /// Moves the stored history that cannot be decrypted aside (to
  /// [unreadableStorageKey], replacing what an earlier call put there)
  /// and starts a new, empty history. Does nothing to a readable history
  /// (it returns it).
  Future<List<HistoryEntry>> discardUnreadable() => _synchronized(() async {
    try {
      return await _current();
    } on HistoryUnreadableException {
      final raw = await store.read(storageKey);
      if (raw != null) {
        await store.write(unreadableStorageKey, raw);
        await store.delete(storageKey);
      }
      return _entries = const [];
    }
  });

  /// Whether a history that could not be decrypted was set aside by
  /// [discardUnreadable] (and not deleted since).
  Future<bool> hasUnreadableCopy() async =>
      await store.read(unreadableStorageKey) != null;

  /// Deletes everything this repository stores: the history, the copy set
  /// aside by [discardUnreadable] and the encryption key.
  Future<void> deleteAll() => _synchronized(() async {
    _entries = const [];
    _key = null;
    await store.delete(storageKey);
    await store.delete(unreadableStorageKey);
    await keyStore.delete(keyStorageKey);
  });

  /// How much the history takes in [store]: the length (UTF-16 code
  /// units) of the stored values, including a copy set aside by
  /// [discardUnreadable].
  Future<int> storedLength() async {
    final values = [
      await store.read(storageKey),
      await store.read(unreadableStorageKey),
    ];
    return values.fold<int>(0, (sum, value) => sum + (value?.length ?? 0));
  }

  /// Deletes non-favourite entries created more than [maxAge] ago (none
  /// when [maxAge] is null) and returns the history. Writes only when
  /// something was deleted.
  Future<List<HistoryEntry>> prune(Duration? maxAge) => _synchronized(() async {
    final entries = await _current();
    final kept = _withoutExpired(entries, maxAge);
    if (kept.length == entries.length) return entries;
    return _entries = await _write(List.unmodifiable(kept));
  });

  /// Inserts [entry] as the newest entry (see the class docs for merging
  /// with the newest entry or an earlier look-up of the same word,
  /// truncation, caps and [maxAge]). An existing entry with the same id is
  /// removed.
  Future<List<HistoryEntry>> add(HistoryEntry entry, {Duration? maxAge}) {
    final added = _limited(entry);
    return _mutate(maxAge: maxAge, (entries) {
      if (added.isDictionary) {
        final previous = entries.where(added.isSameLookUp).firstOrNull;
        return [
          if (previous == null)
            added
          else
            _merged(added, previous, id: previous.id),
          ...entries.where((e) => e.id != added.id && !identical(e, previous)),
        ];
      }
      final newest = entries.firstOrNull;
      if (newest != null && _replaces(newest, added)) {
        return [
          _merged(added, newest),
          ...entries.skip(1).where((e) => e.id != added.id),
        ];
      }
      return [added, ...entries.where((e) => e.id != added.id)];
    });
  }

  /// Puts [entry] back, e.g. to undo [delete]: it is inserted at the
  /// position of its [HistoryEntry.createdAt] (before the first older
  /// entry) and replaces only an entry with the same id. Unlike [add] it
  /// never merges with the newest entry and applies no caps.
  ///
  /// A dictionary look-up of a word the history has a look-up of again
  /// (with another id, e.g. looked up anew after the delete) is merged with
  /// it instead of being added beside it: the newer of the two stays, a
  /// favourite if either is.
  Future<List<HistoryEntry>> restore(HistoryEntry entry) {
    final restored = _limited(entry);
    return _mutate((entries) => _restored(entries, restored), cap: false);
  }

  /// Undoes taking [entry] out of the favourites ([toggleFavorite]): the
  /// entry with its id is a favourite again, with what it holds now (a new
  /// look-up of the word may have updated it since). Without one (deleted,
  /// or it was kept only as a favourite) [entry] is put back as a
  /// favourite, like [restore] does.
  Future<List<HistoryEntry>> restoreFavorite(HistoryEntry entry) {
    final restored = _limited(entry).copyWith(isFavorite: true);
    return _mutate((entries) {
      final index = entries.indexWhere((e) => e.id == restored.id);
      if (index == -1) return _restored(entries, restored);
      return entries..[index] = entries[index].copyWith(isFavorite: true);
    }, cap: false);
  }

  /// Stars or un-stars the entry [id]. Un-starring an entry kept only as a
  /// favourite ([HistoryEntry.favoriteOnly]) deletes it.
  Future<List<HistoryEntry>> toggleFavorite(String id) => _mutate(
    (entries) => [
      for (final entry in entries)
        if (entry.id != id)
          entry
        else if (!entry.isFavorite)
          entry.copyWith(isFavorite: true)
        else if (!entry.favoriteOnly)
          entry.copyWith(isFavorite: false),
    ],
    cap: false,
  );

  Future<List<HistoryEntry>> delete(String id) =>
      _mutate((entries) => entries..removeWhere((e) => e.id == id), cap: false);

  /// Removes everything, or only non-favourites when [keepFavorites].
  Future<List<HistoryEntry>> clear({bool keepFavorites = false}) => _mutate(
    (entries) =>
        keepFavorites ? entries.where((e) => e.isFavorite).toList() : [],
    cap: false,
  );

  /// Pretty JSON array of all entries.
  Future<String> exportJson() => _synchronized(() async {
    final entries = await _current();
    return const JsonEncoder.withIndent('  ')
        .convert([for (final entry in entries) entry.toJson()]);
  });

  /// Merges entries from [json] (dedupe by id) and reports the new list
  /// and what happened to the imported entries ([HistoryImport]). Throws
  /// [FormatException] on invalid input.
  ///
  /// Existing entries win over imported ones with the same id, and over
  /// imported dictionary look-ups of the same word and languages
  /// ([HistoryEntry.isSameLookUp]; the existing look-up becomes a favourite
  /// when the imported one is). The merged list is sorted newest first,
  /// truncated and capped like [add] (with [maxAge], expired non-favourites
  /// are dropped too and counted as [HistoryImport.expired]). Invalid
  /// elements are skipped as long as the input is a JSON array with at
  /// least one valid entry (or is empty). JSON written before entries had
  /// a kind imports as translations.
  Future<HistoryImport> importJson(String json, {Duration? maxAge}) async {
    final imported = _decodeStrict(json).map(_limited).toList();
    var fresh = const <HistoryEntry>[];
    var expired = 0;
    final entries = await _mutate(maxAge: maxAge, (entries) {
      final ids = {for (final entry in entries) entry.id};
      final merged = [...entries];
      final added = <HistoryEntry>[];
      for (final entry in imported) {
        if (!ids.add(entry.id)) continue;
        if (entry.isDictionary) {
          final index = merged.indexWhere(entry.isSameLookUp);
          if (index >= 0) {
            final existing = merged[index];
            if (entry.isFavorite && !existing.isFavorite) {
              merged[index] = existing.copyWith(isFavorite: true);
            }
            continue;
          }
          final earlier = added.indexWhere(entry.isSameLookUp);
          if (earlier >= 0) {
            // Two look-ups of the same word in the import: keep the newer.
            final other = added[earlier];
            final newer = entry.createdAt.isAfter(other.createdAt)
                ? entry
                : other;
            added[earlier] = _merged(
              newer,
              identical(newer, entry) ? other : entry,
            );
            continue;
          }
        }
        added.add(entry);
      }
      fresh = _withoutExpired(added, maxAge);
      expired = added.length - fresh.length;
      return [...merged, ...fresh]
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    });
    final kept = {for (final entry in entries) entry.id};
    return HistoryImport(
      entries: entries,
      added: fresh.where((e) => kept.contains(e.id)).length,
      expired: expired,
    );
  }

  /// Whether the translation [entry] should replace [newest] instead of
  /// being inserted.
  bool _replaces(HistoryEntry newest, HistoryEntry entry) {
    if (newest.kind != entry.kind ||
        newest.engineId != entry.engineId ||
        newest.source != entry.source ||
        newest.target != entry.target) {
      return false;
    }
    final previous = newest.text.trim();
    final text = entry.text.trim();
    if (previous == text) {
      return !newest.isFavorite ||
          newest.translation.trim() == entry.translation.trim();
    }
    return !newest.isFavorite &&
        previous.isNotEmpty &&
        text.isNotEmpty &&
        (text.startsWith(previous) || previous.startsWith(text)) &&
        entry.createdAt.difference(newest.createdAt).abs() <= refinementWindow;
  }

  /// [entries] with [restored] at the position of its createdAt, replacing
  /// the entry with its id (see [restore]).
  static List<HistoryEntry> _restored(
    List<HistoryEntry> entries,
    HistoryEntry restored,
  ) {
    final others = entries.where((e) => e.id != restored.id).toList();
    var entry = restored;
    if (restored.isDictionary) {
      final same = others.indexWhere(restored.isSameLookUp);
      if (same != -1) {
        final existing = others[same];
        if (!restored.createdAt.isAfter(existing.createdAt)) {
          // The look-up made since is newer: it stays where it is.
          return others..[same] = _merged(existing, restored);
        }
        others.removeAt(same);
        entry = _merged(restored, existing);
      }
    }
    final index = others.indexWhere(
      (e) => e.createdAt.isBefore(entry.createdAt),
    );
    return others..insert(index == -1 ? others.length : index, entry);
  }

  /// [kept] taking the place of [other], the same look-up or translation:
  /// with [kept]'s content and [id] (default: [kept]'s), a favourite if
  /// either is, and kept only as a favourite only if both are.
  static HistoryEntry _merged(
    HistoryEntry kept,
    HistoryEntry other, {
    String? id,
  }) => kept.copyWith(
    id: id,
    isFavorite: kept.isFavorite || other.isFavorite,
    favoriteOnly: kept.favoriteOnly && other.favoriteOnly,
  );

  /// [entry] with `text` and `translation` truncated to [maxTextLength].
  HistoryEntry _limited(HistoryEntry entry) {
    final text = _truncated(entry.text);
    final translation = _truncated(entry.translation);
    if (identical(text, entry.text) &&
        identical(translation, entry.translation)) {
      return entry;
    }
    return entry.copyWith(text: text, translation: translation);
  }

  String _truncated(String value) {
    if (value.length <= maxTextLength) return value;
    var end = maxTextLength - 1;
    // Do not split a surrogate pair.
    if (end > 0 && _isHighSurrogate(value.codeUnitAt(end - 1))) end--;
    return '${value.substring(0, end)}…';
  }

  static bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

  /// [entries] without the non-favourites created more than [maxAge] ago.
  List<HistoryEntry> _withoutExpired(
    List<HistoryEntry> entries,
    Duration? maxAge,
  ) {
    if (maxAge == null) return entries;
    final cutoff = _clock().subtract(maxAge);
    return [
      for (final entry in entries)
        if (entry.isFavorite || !entry.createdAt.isBefore(cutoff)) entry,
    ];
  }

  /// Keeps every favourite and the newest non-favourites within
  /// [maxEntries] and [maxStoredLength].
  List<HistoryEntry> _capped(List<HistoryEntry> entries) {
    // The JSON array: brackets plus (at most) one separator per entry.
    var left = maxStoredLength - 2;
    for (final entry in entries) {
      if (entry.isFavorite) left -= _json(entry).length + 1;
    }
    var others = 0;
    var full = false;
    final kept = <HistoryEntry>[];
    for (final entry in entries) {
      if (entry.isFavorite) {
        kept.add(entry);
        continue;
      }
      if (full || others >= maxEntries) continue;
      final length = _json(entry).length + 1;
      if (length > left) {
        // Evict this entry and every older non-favourite.
        full = true;
        continue;
      }
      left -= length;
      others++;
      kept.add(entry);
    }
    return List.unmodifiable(kept);
  }

  /// [entries] without the older half of the non-favourites (rounded up,
  /// so a single one is evicted too).
  static List<HistoryEntry> _withoutOlderHalf(List<HistoryEntry> entries) {
    var keep = entries.where((e) => !e.isFavorite).length ~/ 2;
    return List.unmodifiable(entries.where((e) => e.isFavorite || keep-- > 0));
  }

  String _json(HistoryEntry entry) =>
      _encoded[entry] ??= jsonEncode(entry.toJson());

  /// Same output as `jsonEncode` of the entries' JSON list.
  String _encode(List<HistoryEntry> entries) =>
      '[${entries.map(_json).join(',')}]';

  Future<List<HistoryEntry>> _current() async {
    if (_entries case final entries?) return entries;
    final (entries, legacy: _) = await _readStored();
    return _entries = _capped(entries);
  }

  /// The stored entries, and whether they were stored unencrypted
  /// (`legacy`).
  Future<(List<HistoryEntry>, {bool legacy})> _readStored() async {
    final raw = await store.read(storageKey);
    if (raw == null) return (<HistoryEntry>[], legacy: false);
    if (!cipher.isEncrypted(raw)) return (_decodeLenient(raw), legacy: true);
    final key = _key ?? await _readKey();
    if (key == null) throw const HistoryUnreadableException(keyMissing: true);
    final String json;
    try {
      json = await cipher.decrypt(raw, key);
    } on HistoryCipherException {
      throw const HistoryUnreadableException(keyMissing: false);
    }
    _key = key;
    return (_decodeLenient(json), legacy: false);
  }

  /// The stored key, or null when none (or an invalid one) is stored.
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

  /// The key to encrypt with: the stored one, or a new one that is stored
  /// first (and must read back, see [HistoryKeyUnavailableException]).
  ///
  /// Only called once the stored history was read: never replaces the key
  /// of history that could not be decrypted.
  Future<Uint8List> _writeKey() async {
    if (_key case final key?) return key;
    if (await _readKey() case final key?) return _key = key;
    final key = await cipher.newKey();
    final encoded = base64Encode(key);
    await keyStore.write(keyStorageKey, encoded);
    if (await keyStore.read(keyStorageKey) != encoded) {
      throw const HistoryKeyUnavailableException();
    }
    return _key = key;
  }

  Future<List<HistoryEntry>> _mutate(
    List<HistoryEntry> Function(List<HistoryEntry> entries) change, {
    bool cap = true,
    Duration? maxAge,
  }) => _synchronized(() async {
    final changed = change([...await _current()]);
    final next = cap
        ? _capped(_withoutExpired(changed, maxAge))
        : List<HistoryEntry>.unmodifiable(changed);
    return _entries = await _write(next);
  });

  /// Writes [entries] and returns what was written: on a full quota, older
  /// non-favourites are evicted and the write is retried.
  Future<List<HistoryEntry>> _write(List<HistoryEntry> entries) async {
    final key = await _writeKey();
    var next = entries;
    for (var attempt = 0; ; attempt++) {
      final encoded = await cipher.encrypt(_encode(next), key);
      try {
        await store.write(storageKey, encoded);
        return next;
      } on Object catch (error) {
        if (attempt >= _quotaRetries || !_isQuotaError(error)) rethrow;
        final smaller = _withoutOlderHalf(next);
        if (smaller.length == next.length) rethrow;
        next = smaller;
      }
    }
  }

  /// Whether [error] reports a full storage quota (e.g. the browser's
  /// `QuotaExceededError` from `localStorage`).
  static bool _isQuotaError(Object error) {
    try {
      return error.toString().toLowerCase().contains('quota');
    } on Object {
      return false;
    }
  }

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  static List<HistoryEntry> _decodeLenient(String raw) {
    try {
      final json = jsonDecode(raw);
      return json is List ? _parseEntries(json) : [];
    } on FormatException {
      return [];
    }
  }

  static List<HistoryEntry> _decodeStrict(String raw) {
    final json = jsonDecode(raw);
    if (json is! List) {
      throw const FormatException('Expected a JSON array of history entries');
    }
    final entries = _parseEntries(json);
    if (entries.isEmpty && json.isNotEmpty) {
      throw const FormatException('No valid history entries found');
    }
    return entries;
  }

  static List<HistoryEntry> _parseEntries(List<dynamic> json) => [
    for (final element in json)
      if (element is Map) ?_tryParse(element),
  ];

  static HistoryEntry? _tryParse(Map<dynamic, dynamic> json) {
    try {
      return HistoryEntry.fromJson(Map<String, dynamic>.from(json));
    } on Object {
      return null;
    }
  }
}
