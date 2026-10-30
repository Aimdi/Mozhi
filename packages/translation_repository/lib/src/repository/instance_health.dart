import 'dart:async';

import 'package:translation_repository/src/models/mozhi_instance.dart';

/// Keeps the failures [InstanceHealth] remembers across launches, e.g. in
/// the app's preferences.
///
/// Implementations may throw; [InstanceHealth] ignores their failures (the
/// data only decides which server is asked first).
abstract interface class InstanceHealthStore {
  /// The stored failures: server address -> when a request last failed
  /// there. Empty when nothing is stored.
  Future<Map<String, DateTime>> load();

  /// Replaces the stored failures with [failures] (empty: nothing to keep).
  Future<void> save(Map<String, DateTime> failures);
}

/// An [InstanceHealthStore] kept in memory (tests, or no persistence).
class MemoryInstanceHealthStore implements InstanceHealthStore {
  /// Starts with a copy of [initial].
  new([Map<String, DateTime>? initial]) : failures = {...?initial};

  /// The stored failures.
  Map<String, DateTime> failures;

  /// How often [save] was called.
  int saves = 0;

  @override
  Future<Map<String, DateTime>> load() async => {...failures};

  @override
  Future<void> save(Map<String, DateTime> failures) async {
    saves++;
    this.failures = {...failures};
  }
}

/// Which Mozhi servers failed recently, so that requests start at one that
/// worked.
///
/// A server where a request failed in a way another server might not
/// repeat (it is down, overloaded, its engine broke upstream; see
/// `MozhiPool.canFailOver`) "cools down" for [coolDown]: [order] moves it
/// behind the others until then, or until a request there works again
/// ([markWorked]). Nothing is ever sent just to check a server: only the
/// outcome of requests the app makes anyway counts.
///
/// What is remembered is the server's address (without any user name or
/// password) and the time of its last failure, kept on the device through
/// the [InstanceHealthStore] (at most [maxEntries], none older than
/// [coolDown]). The store loads in the background; until it has, [order]
/// uses what this session saw.
class InstanceHealth {
  /// [clock] defaults to [DateTime.now].
  new({
    this._store,
    DateTime Function()? clock,
    this.coolDown = const Duration(hours: 12),
  }) : _clock = clock ?? DateTime.now {
    final store = _store;
    _ready = store == null ? Future.value() : _load(store);
  }

  /// Most servers remembered (the most recent failures are kept).
  static const maxEntries = 64;

  /// How long a failed server stays behind the others.
  final Duration coolDown;

  final InstanceHealthStore? _store;
  final DateTime Function() _clock;
  final Map<String, DateTime> _failures = {};

  /// Servers marked (or forgotten) before the store answered: what was
  /// stored for them is older.
  final Set<String> _touched = {};
  bool _clearedAll = false;
  late final Future<void> _ready;
  Future<void> _saving = Future.value();

  /// Completes once the stored failures are loaded (also when loading
  /// failed).
  Future<void> get ready => _ready;

  /// Completes once every change so far is saved (also when saving failed).
  Future<void> get saved => _saving;

  Future<void> _load(InstanceHealthStore store) async {
    final Map<String, DateTime> stored;
    try {
      stored = await store.load();
    } on Object {
      return;
    }
    if (_clearedAll) return;
    final now = _clock();
    for (final MapEntry(:key, :value) in stored.entries) {
      final url = keyOf(key);
      if (url.isEmpty || _touched.contains(url)) continue;
      if (_isRecent(value, now)) _failures[url] = value;
    }
  }

  /// A request failed at [url] in a way another server might not repeat.
  void markFailed(String url) {
    final key = keyOf(url);
    if (key.isEmpty) return;
    _touched.add(key);
    _failures[key] = _clock();
    _save();
  }

  /// A request worked at [url]: it no longer cools down.
  void markWorked(String url) => forget(url);

  /// Forgets the failure of [url] (e.g. the user put that server first),
  /// or of every server when [url] is null.
  void forget([String? url]) {
    if (url == null) {
      _clearedAll = true;
      final had = _failures.isNotEmpty;
      _failures.clear();
      // Also when nothing is in memory yet: the store may still hold some.
      if (had || _store != null) _save();
      return;
    }
    final key = keyOf(url);
    _touched.add(key);
    if (_failures.remove(key) != null) _save();
  }

  /// When a request last failed at [url], while it cools down; else null.
  DateTime? failedAt(String url) {
    final failed = _failures[keyOf(url)];
    return failed != null && _isRecent(failed, _clock()) ? failed : null;
  }

  /// Whether [url] is cooling down (a request failed there within
  /// [coolDown]).
  bool isCoolingDown(String url) => failedAt(url) != null;

  /// [instances] with the servers still cooling down moved to the back,
  /// otherwise in the user's order.
  List<MozhiInstance> order(List<MozhiInstance> instances) {
    if (_failures.isEmpty) return [...instances];
    final healthy = <MozhiInstance>[];
    final coolingDown = <MozhiInstance>[];
    for (final instance in instances) {
      (isCoolingDown(instance.url) ? coolingDown : healthy).add(instance);
    }
    return [...healthy, ...coolingDown];
  }

  /// A failure at [failedAt] still counts at [now]. One after [now] (the
  /// clock was set back) counts for at most [coolDown] ahead.
  bool _isRecent(DateTime failedAt, DateTime now) {
    final age = now.difference(failedAt);
    return age < coolDown && -age < coolDown;
  }

  void _save() {
    final store = _store;
    if (store == null) return;
    _saving = _saving.then((_) async {
      await _ready;
      try {
        await store.save(_snapshot());
      } on Object {
        // Only decides which server is asked first.
      }
    });
  }

  /// The failures worth keeping: recent ones, at most [maxEntries], the
  /// latest first.
  Map<String, DateTime> _snapshot() {
    final now = _clock();
    _failures.removeWhere((_, failedAt) => !_isRecent(failedAt, now));
    final entries = _failures.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return {
      for (final entry in entries.take(maxEntries)) entry.key: entry.value,
    };
  }

  /// The server address [url] as remembered: parsed and printed again, with
  /// no user name or password, query or fragment (an address with
  /// credentials is the same server). Empty when [url] is no address.
  static String keyOf(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return '';
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    ).toString();
  }
}
