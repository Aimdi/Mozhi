import 'dart:developer';

import 'package:mozhi/core/key_value_store.dart';

/// Uses [primary] (secure storage) until it throws once, then switches to
/// [fallback] for the rest of the session.
///
/// Secure storage is unavailable on some setups (Linux without a keyring,
/// web outside a secure context, unsigned macOS builds); API keys then live
/// in memory instead of crashing the app.
class FallbackKeyValueStore implements KeyValueStore {
  new(this.primary, {KeyValueStore? fallback})
    : fallback = fallback ?? MemoryStore();

  final KeyValueStore primary;
  final KeyValueStore fallback;
  bool _failed = false;

  /// Whether [primary] failed and [fallback] is in use.
  bool get usingFallback => _failed;

  /// Probes [primary] with a read (bounded by [timeout]) so that an
  /// unusable store is detected before the settings are loaded.
  Future<void> probe({Duration timeout = const Duration(seconds: 5)}) async {
    if (_failed) return;
    try {
      await primary.read('mozhi.probe').timeout(timeout);
    } on Object catch (error, stackTrace) {
      _fail(error, stackTrace);
    }
  }

  void _fail(Object error, StackTrace stackTrace) {
    _failed = true;
    log(
      'Secure storage unavailable, keeping secrets in memory',
      name: 'mozhi',
      error: error,
      stackTrace: stackTrace,
    );
  }

  Future<T> _run<T>(Future<T> Function(KeyValueStore store) action) async {
    if (!_failed) {
      try {
        return await action(primary);
      } on Object catch (error, stackTrace) {
        _fail(error, stackTrace);
      }
    }
    return await action(fallback);
  }

  @override
  Future<String?> read(String key) => _run((store) => store.read(key));

  @override
  Future<void> write(String key, String value) =>
      _run((store) => store.write(key, value));

  @override
  Future<void> delete(String key) => _run((store) => store.delete(key));
}
