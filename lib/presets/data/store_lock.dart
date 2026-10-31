import 'dart:async';

import 'package:mozhi/core/key_value_store.dart';

/// Runs the changes to one key of a [KeyValueStore] one at a time, across
/// every repository over that store.
///
/// The app's presets and glossaries repositories and those of the backup
/// sections (which sync merges through) are separate instances over the
/// same store: with this lock a merge always reads what the app wrote
/// last, and an app change waits for a merge that is being written.
abstract final class StoreLock {
  static final _locks = Expando<Map<String, _Lock>>();

  /// Runs [action] after the actions on [key] of [store] that came before
  /// it, and returns its result. With none running, [action] starts right
  /// away.
  static Future<T> run<T>(
    KeyValueStore store,
    String key,
    Future<T> Function() action,
  ) {
    final lock = (_locks[store] ??= {})[key] ??= _Lock();
    final waitFor = lock.running > 0 ? lock.last : null;
    lock.running++;
    Future<T> guarded() async {
      try {
        return await action();
      } finally {
        lock.running--;
      }
    }

    final result = waitFor == null ? guarded() : waitFor.then((_) => guarded());
    lock.last = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

class _Lock {
  /// Actions started and not finished.
  int running = 0;

  /// Completes when the last action started has finished.
  Future<void> last = Future.value();
}
