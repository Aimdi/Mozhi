import 'dart:async';

import 'package:translation_repository/src/models/models.dart';
import 'package:translation_repository/src/prompts/response_parsers.dart';
import 'package:translation_repository/src/repository/mappers.dart';

/// Turns a stream of LLM text deltas into translation snapshots.
///
/// * Nothing is emitted while the accumulated text could still turn into a
///   `[[lang:xx]]` marker; afterwards the marker is parsed into
///   `detectedSource` (only when the source is auto) and never shown.
/// * Intermediate snapshots (`isComplete: false`) are throttled to at most
///   one per [snapshotInterval] (the latest one is delivered when the
///   interval elapses); identical consecutive snapshots are dropped.
/// * When the deltas complete, a final `isComplete: true` result with
///   `ResponseParsers.cleanTranslation` applied is emitted.
/// * Errors from [open] or the delta stream are forwarded and close the
///   stream. Cancelling, pausing and resuming the returned stream are
///   forwarded to the delta subscription (cancelling aborts the request).
Stream<TranslationResult> aiTranslationStream({
  required Stream<String> Function() open,
  required TranslationEngine engine,
  required TranslationRequest request,
  Duration snapshotInterval = const Duration(milliseconds: 50),
}) {
  late final StreamController<TranslationResult> controller;
  StreamSubscription<String>? subscription;
  Timer? throttle;
  final buffer = StringBuffer();
  final elapsed = Stopwatch();
  final sinceEmit = Stopwatch();
  TranslationResult? pending;
  ({String? language, String text})? lastSnapshot;

  TranslationResult result(
    ({String? language, String text}) split, {
    required bool isComplete,
  }) => TranslationResult(
    engineId: engine.id,
    engineName: engine.name,
    text: isComplete
        ? ResponseParsers.cleanTranslation(split.text, source: request.text)
        : split.text,
    isComplete: isComplete,
    detectedSource: request.source.isAuto
        ? normalizeDetected(split.language)
        : null,
    elapsed: elapsed.elapsed,
  );

  void flush() {
    throttle?.cancel();
    throttle = null;
    final snapshot = pending;
    pending = null;
    if (snapshot == null || controller.isClosed) return;
    controller.add(snapshot);
    sinceEmit
      ..reset()
      ..start();
  }

  void fail(Object error, StackTrace stackTrace) {
    throttle?.cancel();
    pending = null;
    if (controller.isClosed) return;
    controller.addError(error, stackTrace);
    unawaited(controller.close());
  }

  void onDelta(String delta) {
    buffer.write(delta);
    final accumulated = buffer.toString();
    if (ResponseParsers.isMarkerPending(accumulated)) return;
    final split = ResponseParsers.splitLanguageMarker(accumulated);
    if (split == lastSnapshot) return;
    lastSnapshot = split;
    pending = result(split, isComplete: false);
    final sinceLast = sinceEmit.elapsed;
    if (!sinceEmit.isRunning || sinceLast >= snapshotInterval) {
      flush();
    } else {
      throttle ??= Timer(snapshotInterval - sinceLast, flush);
    }
  }

  void onDone() {
    throttle?.cancel();
    pending = null;
    if (controller.isClosed) return;
    final split = ResponseParsers.splitLanguageMarker(buffer.toString());
    controller.add(result(split, isComplete: true));
    unawaited(controller.close());
  }

  controller = StreamController<TranslationResult>(
    onListen: () {
      elapsed.start();
      try {
        subscription = open().listen(
          (delta) {
            try {
              onDelta(delta);
            } on Object catch (error, stackTrace) {
              unawaited(subscription?.cancel());
              fail(error, stackTrace);
            }
          },
          onError: fail,
          onDone: () {
            try {
              onDone();
            } on Object catch (error, stackTrace) {
              fail(error, stackTrace);
            }
          },
          cancelOnError: true,
        );
      } on Object catch (error, stackTrace) {
        fail(error, stackTrace);
      }
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: () {
      throttle?.cancel();
      pending = null;
      return subscription?.cancel();
    },
  );
  return controller.stream;
}
