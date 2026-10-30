import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:translation_repository/translation_repository.dart'
    show OfflineDownloadCancelledException;

/// Stops a model download once [cancel] is called: requests sent with
/// [future] as their abort trigger are aborted, [guard]ed response streams
/// end with an [OfflineDownloadCancelledException], and [check] throws it.
@internal
final class DownloadCancel {
  final _stopped = Completer<void>();

  /// Whether [cancel] was called.
  bool get isCancelled => _stopped.isCompleted;

  /// Completes when [cancel] is called (never with an error).
  Future<void> get future => _stopped.future;

  void cancel() {
    if (!_stopped.isCompleted) _stopped.complete();
  }

  /// Throws an [OfflineDownloadCancelledException] once cancelled.
  void check() {
    if (isCancelled) throw const OfflineDownloadCancelledException();
  }

  /// [work], or an [OfflineDownloadCancelledException] as soon as
  /// [cancel] is called (for clients that do not abort a request by its
  /// trigger); a result of [work] that comes after that goes to [onLate]
  /// (e.g. to close a response).
  Future<T> race<T>(Future<T> work, {void Function(T value)? onLate}) {
    final result = Completer<T>();
    unawaited(
      work.then(
        (value) {
          if (result.isCompleted) {
            onLate?.call(value);
          } else {
            result.complete(value);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!result.isCompleted) result.completeError(error, stackTrace);
        },
      ),
    );
    unawaited(
      future.then((_) {
        if (!result.isCompleted) {
          result.completeError(const OfflineDownloadCancelledException());
        }
      }),
    );
    return result.future;
  }

  /// [stream] until [cancel] is called: then its subscription is cancelled
  /// (which closes the HTTP response) and the stream ends with an
  /// [OfflineDownloadCancelledException], without waiting for the next
  /// chunk.
  Stream<T> guard<T>(Stream<T> stream) {
    final controller = StreamController<T>();
    // Cancelled by stop() or onCancel.
    // ignore: cancel_subscriptions
    StreamSubscription<T>? subscription;
    void stop() {
      if (controller.isClosed) return;
      final source = subscription;
      subscription = null;
      if (source != null) unawaited(source.cancel());
      controller.addError(const OfflineDownloadCancelledException());
      unawaited(controller.close());
    }

    controller
      ..onListen = () {
        if (isCancelled) {
          // Never read: close it.
          unawaited(stream.listen(null, onError: (Object _) {}).cancel());
          return stop();
        }
        subscription = stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: () {
            subscription = null;
            unawaited(controller.close());
          },
        );
        unawaited(future.then((_) => stop()));
      }
      ..onPause = (() => subscription?.pause())
      ..onResume = (() => subscription?.resume())
      ..onCancel = () {
        final source = subscription;
        subscription = null;
        return source?.cancel();
      };
    return controller.stream;
  }
}

/// Installs that several callers share (one download per model): each
/// caller may stop waiting with its own abort, and the shared work is
/// cancelled ([DownloadCancel]) once every caller has stopped waiting.
/// A call after that starts the install again, once the cancelled one has
/// wound down (so two never write the same files).
@internal
final class SharedInstalls<T> {
  final Map<String, _Shared<T>> _running = {};

  /// The install running under [key], if any.
  Future<T>? running(String key) => _running[key]?.result;

  /// The result of the install under [key]: the one running, or a new one
  /// from [start]. Once [abort] completes, this call fails with an
  /// [OfflineDownloadCancelledException]: at once while other callers
  /// still wait for the install, else once the cancelled install has
  /// stopped (with its own result when it was done first). Without an
  /// [abort] the caller waits until the install ends.
  Future<T> run(
    String key,
    Future<T> Function(DownloadCancel cancel) start, {
    Future<void>? abort,
  }) {
    var shared = _running[key];
    if (shared == null || shared.cancel.isCancelled) {
      final created = shared = _Shared(start, after: shared?.settled);
      _running[key] = created;
      unawaited(
        created.settled.then((_) {
          if (identical(_running[key], created)) _running.remove(key);
        }),
      );
    }
    final current = shared;
    current.waiting++;
    if (abort == null) return current.result;
    final caller = Completer<T>();
    // Whether this caller's abort came before the result.
    var aborted = false;
    unawaited(
      current.result.then(
        (value) {
          if (!caller.isCompleted) caller.complete(value);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (caller.isCompleted) return;
          if (aborted) {
            // However the cancelled work ended, the caller cancelled it.
            caller.completeError(const OfflineDownloadCancelledException());
          } else {
            caller.completeError(error, stackTrace);
          }
        },
      ),
    );
    unawaited(
      abort.then((_) {
        if (caller.isCompleted) return;
        aborted = true;
        if (--current.waiting == 0) {
          // Ends once the work has stopped (with its result when it was
          // done first).
          current.cancel.cancel();
        } else {
          caller.completeError(const OfflineDownloadCancelledException());
        }
      }, onError: (Object _) {}),
    );
    return caller.future;
  }
}

final class _Shared<T> {
  new(Future<T> Function(DownloadCancel cancel) start, {Future<void>? after}) {
    result = after == null
        ? Future.sync(() => start(cancel))
        : after.then((_) => start(cancel));
    settled = result.then<void>((_) {}, onError: (Object _) {});
  }

  final cancel = DownloadCancel();
  late final Future<T> result;

  /// Completes (never with an error) when [result] does.
  late final Future<void> settled;

  /// Callers still waiting for [result].
  int waiting = 0;
}

/// Whether [response] (a `206 Partial Content`) holds the rest of a file
/// of [size] bytes from byte [start] on: its `Content-Range` says so
/// (`bytes <start>-<size - 1>/<size>`, or `/*` for an unknown size) and
/// its length, when given, agrees.
@internal
bool resumesAt(http.BaseResponse response, int start, int size) {
  final range = _contentRange.firstMatch(
    response.headers['content-range'] ?? '',
  );
  if (range == null) return false;
  final total = range.group(3)!;
  final length = response.contentLength;
  return int.parse(range.group(1)!) == start &&
      int.parse(range.group(2)!) == size - 1 &&
      (total == '*' || int.parse(total) == size) &&
      (length == null || length == size - start);
}

final _contentRange = RegExp(
  r'^\s*bytes\s+(\d+)-(\d+)/(\d+|\*)\s*$',
  caseSensitive: false,
);
