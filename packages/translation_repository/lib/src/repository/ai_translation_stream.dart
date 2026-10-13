import 'dart:async';

import 'package:translation_repository/src/models/models.dart';
import 'package:translation_repository/src/prompts/response_parsers.dart';
import 'package:translation_repository/src/repository/mappers.dart';

/// Turns a stream of LLM text deltas into translation snapshots.
///
/// * Nothing is emitted while the accumulated text could still turn into a
///   `[[lang:xx]]` marker; afterwards the marker is parsed into
///   `detectedSource` (only when the source is auto) and never shown. A
///   marker the model puts at the end is held back too: intermediate
///   snapshots drop a trailing partial marker (`Hallo\n[[lang:`).
/// * With `parseMarker: false` (translation-specialised models, which are
///   never asked for a marker) the text is passed through as is and
///   [detectedSource], when given, is reported on every result instead.
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
  bool parseMarker = true,
  String? detectedSource,
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
    detectedSource:
        detectedSource ??
        (request.source.isAuto ? normalizeDetected(split.language) : null),
    elapsed: elapsed.elapsed,
  );

  ({String? language, String text}) split(String text) => parseMarker
      ? ResponseParsers.splitLanguageMarker(text)
      : (language: null, text: text);

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
    if (parseMarker && ResponseParsers.isMarkerPending(accumulated)) return;
    var snapshot = split(accumulated);
    if (parseMarker) {
      snapshot = (
        language: snapshot.language,
        text: stripPartialTrailingMarker(snapshot.text),
      );
    }
    if (snapshot == lastSnapshot) return;
    lastSnapshot = snapshot;
    pending = result(snapshot, isComplete: false);
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
    controller.add(result(split(buffer.toString()), isComplete: true));
    unawaited(controller.close());
  }

  // Parser failures must not escape as uncaught errors.
  void guarded(void Function() body) {
    try {
      body();
    } on Object catch (error, stackTrace) {
      unawaited(subscription?.cancel());
      fail(error, stackTrace);
    }
  }

  controller = StreamController<TranslationResult>(
    onListen: () => guarded(() {
      elapsed.start();
      subscription = open().listen(
        (delta) => guarded(() => onDelta(delta)),
        onError: fail,
        onDone: () => guarded(onDone),
        cancelOnError: true,
      );
    }),
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

/// [text] without a trailing partial `[[lang:xx]]` marker (one that could
/// still be completed by the next deltas, e.g. `Hallo\n[[lang:` or
/// `Hallo [[la`), with the whitespace before it. Complete markers are left
/// to `ResponseParsers.splitLanguageMarker`.
String stripPartialTrailingMarker(String text) {
  // A partial marker is short; only look at the last few characters.
  final from = text.length > _maxPartialMarker
      ? text.length - _maxPartialMarker
      : 0;
  for (var i = text.indexOf('[', from); i != -1; i = text.indexOf('[', i + 1)) {
    final tail = text.substring(i);
    if (_isPartialMarker(tail)) return text.substring(0, i).trimRight();
  }
  return text;
}

const _maxPartialMarker = 40;

final _completeTrailingMarker = RegExp(
  r'^\[\[\s*lang(?:uage)?\s*[:=]\s*[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{1,8})*\s*\]\]$',
  caseSensitive: false,
);

/// Completions that turn every proper prefix of a trailing marker into a
/// whole one.
final _completions = <String>[
  for (final keyword in const [
    '[lang',
    'lang',
    'ang',
    'ng',
    'g',
    'uage',
    'age',
    'ge',
    'e',
    '',
  ])
    '$keyword:fr]]',
  'fr]]',
  'x]]',
  ']]',
  ']',
];

bool _isPartialMarker(String tail) {
  if (tail.contains('\n')) return false;
  final trimmed = tail.trimRight();
  if (_completeTrailingMarker.hasMatch(trimmed)) return false;
  return _completions.any(
    (completion) => _completeTrailingMarker.hasMatch('$trimmed$completion'),
  );
}
