import 'dart:async';
import 'dart:developer';

import 'package:mozhi/core/key_value_store.dart';

/// Uses [primary] (secure storage), unless the startup [probe] finds it
/// unusable: then [fallback], an in-memory store, for the rest of the
/// session.
///
/// Secure storage is unavailable on some setups (Linux without a keyring,
/// web outside a secure context, unsigned macOS builds); API keys then live
/// in memory instead of crashing the app.
///
/// Only the probe switches stores. Once [primary] passed it, a failing
/// operation is tried once more after [retryDelay] and then throws: a
/// transient Keystore error must not silently turn the keys saved later
/// into session-only ones.
///
/// A probe that runs out of time is not a verdict: the Keystore can be slow
/// on its first use (creating its key). Until it answers, [fallback] is
/// used; when it answers after all, the store switches back to [primary]
/// and copies what was written to [fallback] meanwhile.
class FallbackKeyValueStore implements KeyValueStore {
  new(
    this.primary, {
    KeyValueStore? fallback,
    this.retryDelay = const Duration(milliseconds: 100),
  }) : fallback = fallback ?? MemoryStore();

  final KeyValueStore primary;
  final KeyValueStore fallback;

  /// How long a failed operation waits before its one retry.
  final Duration retryDelay;

  /// The key [probe] reads.
  static const probeKey = 'mozhi.probe';

  /// How long [probe] waits for [primary] by default. A healthy store
  /// answers in milliseconds; one that takes longer at startup would hold
  /// up the first frame.
  static const probeTimeout = Duration(milliseconds: 1500);

  bool _failed = false;
  Future<void>? _probing;

  /// While [primary] can still answer a probe that ran out of time: the
  /// keys written to or deleted from [fallback] since.
  Set<String>? _changedInFallback;

  /// Set while what was written to [fallback] moves to [primary].
  Future<void>? _recovering;

  /// Whether [fallback] is in use: the [probe] failed, or ran out of time
  /// and [primary] has not answered since.
  bool get usingFallback => _failed;

  /// Probes [primary] with a read, bounded by [timeout], so that an
  /// unusable store is detected before the secrets are loaded. Operations
  /// started meanwhile wait for it, so it can run alongside other startup
  /// work. Only the first call probes; later ones return its future.
  Future<void> probe({Duration timeout = probeTimeout}) =>
      _probing ??= _probe(timeout);

  Future<void> _probe(Duration timeout) async {
    final read = Future.sync(() => primary.read(probeKey));
    try {
      await read.timeout(timeout);
    } on TimeoutException catch (error, stackTrace) {
      _useFallback(error, stackTrace);
      _changedInFallback = {};
      unawaited(_recoverWhenAnswered(read));
    } on Object catch (error, stackTrace) {
      _useFallback(error, stackTrace);
    }
  }

  void _useFallback(Object error, StackTrace stackTrace) {
    _failed = true;
    log(
      'Secure storage unavailable, keeping secrets in memory',
      name: 'mozhi',
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// Switches back to [primary] once the probe's [read] succeeds.
  Future<void> _recoverWhenAnswered(Future<String?> read) async {
    try {
      await read;
    } on Object {
      _changedInFallback = null;
      return;
    }
    await (_recovering = _moveToPrimary());
    _recovering = null;
  }

  Future<void> _moveToPrimary() async {
    final changed = {...?_changedInFallback};
    try {
      for (final key in changed) {
        final value = await fallback.read(key);
        if (value == null) {
          await primary.delete(key);
        } else {
          await primary.write(key, value);
        }
      }
    } on Object catch (error, stackTrace) {
      _changedInFallback = null;
      log(
        'Secure storage answered late but failed, keeping secrets in memory',
        name: 'mozhi',
        error: error,
        stackTrace: stackTrace,
      );
      return;
    }
    _changedInFallback = null;
    _failed = false;
  }

  Future<T> _run<T>(
    Future<T> Function(KeyValueStore store) action, {
    String? changes,
  }) async {
    if (_probing case final probing?) await probing;
    if (_recovering case final recovering?) await recovering;
    if (_failed) {
      if (changes != null) _changedInFallback?.add(changes);
      return await action(fallback);
    }
    try {
      return await action(primary);
    } on Object catch (error, stackTrace) {
      log(
        'Secure storage failed, trying once more',
        name: 'mozhi',
        error: error,
        stackTrace: stackTrace,
      );
    }
    await Future<void>.delayed(retryDelay);
    return await action(primary);
  }

  @override
  Future<String?> read(String key) => _run((store) => store.read(key));

  @override
  Future<void> write(String key, String value) =>
      _run((store) => store.write(key, value), changes: key);

  @override
  Future<void> delete(String key) =>
      _run((store) => store.delete(key), changes: key);
}
