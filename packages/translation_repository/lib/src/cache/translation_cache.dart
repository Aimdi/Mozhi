import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';
import 'package:translation_repository/src/models/models.dart';

/// An in-memory LRU cache of final translations, with a time-to-live.
///
/// Entries are keyed by the engine id, the source and target language
/// (`code` + `isCustom`), the full [TranslationOptions] (style, formality,
/// reading level, genders, context, formatting, glossary and the one-off
/// `instructions`, since all of them change the output) and the exact input
/// text. Only complete, non-empty results are stored: partial streaming
/// snapshots and failures never are.
///
/// Reads refresh an entry's recency (but not its age); once [maxEntries] is
/// exceeded the least recently used entry is evicted. Entries older than
/// [ttl] are dropped when they are next looked up.
///
/// Typical use wraps an uncached translation stream with [cachedTranslate]:
///
/// ```dart
/// final cache = TranslationCache();
/// final stream = cache.cachedTranslate(
///   engine,
///   request,
///   () => fetchTranslation(engine, request),
/// );
/// ```
class TranslationCache {
  /// Creates a cache holding at most [maxEntries] results (0 disables
  /// caching) for at most [ttl] each. [clock] defaults to [DateTime.now].
  new({
    this.maxEntries = defaultMaxEntries,
    this.ttl = defaultTtl,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    RangeError.checkNotNegative(maxEntries, 'maxEntries');
  }

  /// Default value of [maxEntries].
  static const defaultMaxEntries = 200;

  /// Default value of [ttl].
  static const defaultTtl = Duration(hours: 24);

  /// Maximum number of stored results; 0 disables caching.
  final int maxEntries;

  /// How long a stored result stays valid.
  final Duration ttl;

  final DateTime Function() _clock;

  /// Insertion order doubles as recency order: the first entry is the least
  /// recently used one.
  final LinkedHashMap<_CacheKey, _CacheEntry> _entries = LinkedHashMap();

  /// Number of stored entries, including expired ones not yet looked up.
  int get length => _entries.length;

  bool get isEmpty => _entries.isEmpty;

  /// The cached final result for [request] on [engine], or null when there is
  /// none or it has expired (expired entries are removed). A hit becomes the
  /// most recently used entry.
  TranslationResult? lookup(
    TranslationEngine engine,
    TranslationRequest request,
  ) => _lookup(_CacheKey.of(engine, request));

  /// Whether a valid (unexpired) result is cached for [request] on [engine].
  /// Unlike [lookup], this does not change the entry's recency.
  bool contains(TranslationEngine engine, TranslationRequest request) {
    final key = _CacheKey.of(engine, request);
    final entry = _entries[key];
    if (entry == null) return false;
    if (_isExpired(entry)) {
      _entries.remove(key);
      return false;
    }
    return true;
  }

  /// Stores [result] for [request] on [engine] and returns whether it was
  /// stored. Partial (`isComplete: false`) and blank results are ignored, as
  /// is everything when [maxEntries] is 0.
  bool store(
    TranslationEngine engine,
    TranslationRequest request,
    TranslationResult result,
  ) => _store(_CacheKey.of(engine, request), result);

  /// Removes the entry for [request] on [engine]; returns whether one existed.
  bool remove(TranslationEngine engine, TranslationRequest request) =>
      _entries.remove(_CacheKey.of(engine, request)) != null;

  /// Removes every entry produced by the engine with id [engineId] (e.g.
  /// after its provider's model or settings changed) and returns how many
  /// were removed.
  int invalidateEngine(String engineId) {
    final before = _entries.length;
    _entries.removeWhere((key, _) => key.engineId == engineId);
    return before - _entries.length;
  }

  /// Removes every entry.
  void clear() => _entries.clear();

  /// Serves [request] on [engine] from the cache when possible.
  ///
  /// The lookup happens when the returned stream is listened to. On a hit the
  /// stream emits the cached result and closes, and [fetch] is never called.
  /// On a miss it calls [fetch] and forwards its events, errors and
  /// completion unchanged (pause, resume and cancel are forwarded too, so
  /// cancelling still cancels the underlying request). Every complete result
  /// is stored as soon as it arrives; if the fetched stream later reports an
  /// error, the result stored by this call is removed again and nothing more
  /// is stored, so failures are never cached. Errors thrown synchronously by
  /// [fetch] are emitted as stream errors.
  ///
  /// The returned stream is single-subscription.
  Stream<TranslationResult> cachedTranslate(
    TranslationEngine engine,
    TranslationRequest request,
    Stream<TranslationResult> Function() fetch,
  ) {
    late final StreamController<TranslationResult> controller;
    StreamSubscription<TranslationResult>? subscription;

    void onListen() {
      final key = _CacheKey.of(engine, request);
      final hit = _lookup(key);
      if (hit != null) {
        controller.add(hit);
        unawaited(controller.close());
        return;
      }
      final Stream<TranslationResult> source;
      try {
        source = fetch();
      } on Object catch (error, stackTrace) {
        controller.addError(error, stackTrace);
        unawaited(controller.close());
        return;
      }
      var failed = false;
      _CacheEntry? stored;
      subscription = source.listen(
        (result) {
          if (!failed && _store(key, result)) stored = _entries[key];
          controller.add(result);
        },
        onError: (Object error, StackTrace stackTrace) {
          failed = true;
          if (stored != null && identical(_entries[key], stored)) {
            _entries.remove(key);
          }
          stored = null;
          controller.addError(error, stackTrace);
        },
        onDone: controller.close,
      );
    }

    controller = StreamController<TranslationResult>(
      onListen: onListen,
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () => subscription?.cancel(),
    );
    return controller.stream;
  }

  TranslationResult? _lookup(_CacheKey key) {
    final entry = _entries.remove(key);
    if (entry == null || _isExpired(entry)) return null;
    _entries[key] = entry;
    return entry.result;
  }

  bool _store(_CacheKey key, TranslationResult result) {
    if (maxEntries == 0 || !_isCacheable(result)) return false;
    _entries
      ..remove(key)
      ..[key] = _CacheEntry(result, _clock());
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return true;
  }

  /// A clock that moved backwards also expires the entry, to be safe.
  bool _isExpired(_CacheEntry entry) {
    final age = _clock().difference(entry.storedAt);
    return age >= ttl || age.isNegative;
  }

  static bool _isCacheable(TranslationResult result) =>
      result.isComplete && result.text.trim().isNotEmpty;
}

@immutable
class _CacheEntry {
  const new(this.result, this.storedAt);

  final TranslationResult result;
  final DateTime storedAt;
}

@immutable
class _CacheKey {
  const new({
    required this.engineId,
    required this.sourceCode,
    required this.sourceIsCustom,
    required this.targetCode,
    required this.targetIsCustom,
    required this.options,
    required this.text,
  });

  /// Copies the glossary so later mutation of the caller's map cannot change
  /// a stored key.
  factory of(TranslationEngine engine, TranslationRequest request) {
    final options = request.options;
    return _CacheKey(
      engineId: engine.id,
      sourceCode: request.source.code,
      sourceIsCustom: request.source.isCustom,
      targetCode: request.target.code,
      targetIsCustom: request.target.isCustom,
      options: options.glossary.isEmpty
          ? options
          : options.copyWith(
              glossary: Map<String, String>.unmodifiable(options.glossary),
            ),
      text: request.text,
    );
  }

  final String engineId;
  final String sourceCode;
  final bool sourceIsCustom;
  final String targetCode;
  final bool targetIsCustom;
  final TranslationOptions options;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is _CacheKey &&
      other.engineId == engineId &&
      other.sourceCode == sourceCode &&
      other.sourceIsCustom == sourceIsCustom &&
      other.targetCode == targetCode &&
      other.targetIsCustom == targetIsCustom &&
      other.options == options &&
      other.text == text;

  @override
  int get hashCode => Object.hash(
    engineId,
    sourceCode,
    sourceIsCustom,
    targetCode,
    targetIsCustom,
    options,
    text,
  );
}
