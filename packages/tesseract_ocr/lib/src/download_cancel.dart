import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

/// A download of language data was stopped with
/// `TessdataManager.cancelInstall` before it finished. Nothing was
/// installed by it (what was received may be kept for resuming).
final class TessdataDownloadCancelledException implements Exception {
  const new(this.language);

  /// The Tesseract code, e.g. `deu`.
  final String language;

  @override
  String toString() => 'TessdataDownloadCancelledException($language)';
}

/// Stops a download of [language] once [cancel] is called: requests sent
/// with [future] as their abort trigger are aborted, [guard]ed response
/// streams end with a [TessdataDownloadCancelledException], [race]d
/// futures fail with it and [check] throws it.
@internal
final class DownloadCancel {
  new(this.language);

  /// The Tesseract code of the download.
  final String language;

  final _stopped = Completer<void>();

  /// Whether [cancel] was called.
  bool get isCancelled => _stopped.isCompleted;

  /// Completes when [cancel] is called (never with an error).
  Future<void> get future => _stopped.future;

  void cancel() {
    if (!_stopped.isCompleted) _stopped.complete();
  }

  TessdataDownloadCancelledException get _error =>
      TessdataDownloadCancelledException(language);

  /// Throws a [TessdataDownloadCancelledException] once cancelled.
  void check() {
    if (isCancelled) throw _error;
  }

  /// [work], or a [TessdataDownloadCancelledException] as soon as [cancel]
  /// is called (for clients that do not abort a request by its trigger); a
  /// result of [work] that comes after that goes to [onLate] (e.g. to close
  /// a response).
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
        if (!result.isCompleted) result.completeError(_error);
      }),
    );
    return result.future;
  }

  /// [stream] until [cancel] is called: then its subscription is cancelled
  /// (which closes the HTTP response) and the stream ends with a
  /// [TessdataDownloadCancelledException], without waiting for the next
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
      controller.addError(_error);
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

/// Whether [response] (a `206 Partial Content`) holds the rest of a file
/// of [size] bytes from byte [start] on: its `Content-Range` says so
/// (`bytes <start>-<size - 1>/<size>`, or `/*` for an unknown size) and
/// its length, when given, agrees. False for numbers too large for an
/// `int`: the caller then asks for the whole file.
@internal
bool resumesAt(http.BaseResponse response, int start, int size) {
  final range = _contentRange.firstMatch(
    response.headers['content-range'] ?? '',
  );
  if (range == null) return false;
  final total = range.group(3)!;
  final length = response.contentLength;
  return int.tryParse(range.group(1)!) == start &&
      int.tryParse(range.group(2)!) == size - 1 &&
      (total == '*' || int.tryParse(total) == size) &&
      (length == null || length == size - start);
}

final _contentRange = RegExp(
  r'^\s*bytes\s+(\d+)-(\d+)/(\d+|\*)\s*$',
  caseSensitive: false,
);
