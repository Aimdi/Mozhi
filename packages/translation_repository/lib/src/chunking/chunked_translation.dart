import 'dart:async';

import 'package:translation_repository/src/chunking/paragraph_chunker.dart';
import 'package:translation_repository/src/models/models.dart';

/// Translates a long [request] in [chunks] (from [ParagraphChunker.split]
/// of its text) with [translate], which returns the stream of one chunk
/// request (growing snapshots and a final result, like a streaming AI
/// translation).
///
/// * Chunks are translated in order, at most [concurrency] (at least 1) at
///   a time. When the source is auto, the first chunk is translated alone
///   and the language it detected becomes the source of the others.
/// * Every chunk after the first gets the end (about [contextChars]
///   characters) of the previous chunk's text as context, after the user's
///   own `TranslationOptions.context` (see [precedingTextContext]).
/// * Snapshots combine the chunks started so far (finished and in
///   progress, in order, joined with the original separators) and are
///   `isComplete` only once every chunk is done; `detectedSource` is that of
///   the first chunk (of a later one when the first reported none).
/// * An error of any chunk cancels the others and is emitted, closing the
///   stream. Cancelling, pausing and resuming the returned stream are
///   forwarded to the chunks in flight.
Stream<TranslationResult> chunkedTranslation({
  required TranslationEngine engine,
  required TranslationRequest request,
  required List<TextChunk> chunks,
  required Stream<TranslationResult> Function(TranslationRequest chunk)
  translate,
  required Language Function(String code) languageFor,
  int concurrency = 2,
  int contextChars = 400,
}) {
  if (chunks.isEmpty) return const Stream.empty();
  final count = chunks.length;
  final parallel = concurrency < 1 ? 1 : concurrency;
  final texts = List<String>.filled(count, '');
  final detected = List<String?>.filled(count, null);
  final done = List<bool>.filled(count, false);
  final running = <int, StreamSubscription<TranslationResult>>{};
  final elapsed = Stopwatch();
  late final StreamController<TranslationResult> controller;
  var source = request.source;
  var started = 0;
  var finished = 0;
  var stopped = false;
  ({String text, String? detected})? last;

  TranslationRequest requestFor(int index) => request.copyWith(
    text: chunks[index].text,
    source: source,
    options: index == 0
        ? request.options
        : request.options.copyWith(
            context: precedingTextContext(
              request.options.context,
              chunks[index - 1].text,
              maxChars: contextChars,
            ),
          ),
  );

  String? detectedSource() {
    for (final code in detected) {
      if (code != null) return code;
    }
    return null;
  }

  void stop(Object error, StackTrace stackTrace) {
    if (stopped) return;
    stopped = true;
    final subscriptions = running.values.toList();
    running.clear();
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
    controller.addError(error, stackTrace);
    unawaited(controller.close());
  }

  void emit() {
    if (stopped) return;
    final complete = finished == count;
    // Chunks start in order, so the started ones are a prefix; in-progress
    // chunks at its end that have no text yet are left out.
    var end = started;
    while (end > 1 && !done[end - 1] && texts[end - 1].isEmpty) {
      end--;
    }
    final buffer = StringBuffer();
    for (var i = 0; i < end; i++) {
      if (i > 0) buffer.write(chunks[i - 1].separator);
      buffer.write(texts[i]);
    }
    final snapshot = (text: buffer.toString(), detected: detectedSource());
    if (!complete && snapshot == last) return;
    last = snapshot;
    controller.add(
      TranslationResult(
        engineId: engine.id,
        engineName: engine.name,
        text: snapshot.text,
        isComplete: complete,
        detectedSource: snapshot.detected,
        elapsed: elapsed.elapsed,
      ),
    );
    if (complete) {
      stopped = true;
      unawaited(controller.close());
    }
  }

  late final void Function() startMore;

  void start(int index) {
    final Stream<TranslationResult> stream;
    try {
      stream = translate(requestFor(index));
    } on Object catch (error, stackTrace) {
      stop(error, stackTrace);
      return;
    }
    running[index] = stream.listen(
      (result) {
        texts[index] = result.text;
        if (result.detectedSource case final code?) detected[index] = code;
        emit();
      },
      onError: (Object error, StackTrace stackTrace) {
        running.remove(index);
        stop(error, stackTrace);
      },
      onDone: () {
        running.remove(index);
        if (stopped) return;
        done[index] = true;
        finished++;
        if (index == 0 && source.isAuto && detected[0] != null) {
          source = languageFor(detected[0]!);
        }
        startMore();
        emit();
      },
      cancelOnError: true,
    );
  }

  startMore = () {
    while (!stopped && started < count) {
      // An auto source is pinned by the first chunk before the others run.
      final limit = request.source.isAuto && !done[0] ? 1 : parallel;
      if (running.length >= limit) return;
      start(started++);
    }
  };

  controller = StreamController<TranslationResult>(
    onListen: () {
      elapsed.start();
      startMore();
    },
    onPause: () {
      for (final subscription in running.values) {
        subscription.pause();
      }
    },
    onResume: () {
      for (final subscription in running.values) {
        subscription.resume();
      }
    },
    onCancel: () async {
      stopped = true;
      final subscriptions = running.values.toList();
      running.clear();
      await Future.wait([
        for (final subscription in subscriptions) subscription.cancel(),
      ]);
    },
  );
  return controller.stream;
}

/// The `TranslationOptions.context` for a chunk that follows [preceding]:
/// the user's own [context] (if any), then the end of [preceding] (at most
/// about [maxChars] characters, starting at a word boundary), labelled as
/// text that is translated separately and must not be translated again.
String precedingTextContext(
  String context,
  String preceding, {
  int maxChars = 400,
}) {
  final note =
      'The text to translate continues a longer text that is translated in '
      'parts. The end of the preceding part follows for reference only (for '
      'consistent terms, tone and references). It is translated separately: '
      'do not translate it and do not include it in your reply.\n'
      'Preceding text: ${_tail(preceding.trim(), maxChars)}';
  final own = context.trim();
  return own.isEmpty ? note : '$own\n\n$note';
}

String _tail(String text, int maxChars) {
  if (text.length <= maxChars) return text;
  if (maxChars < 1) return '';
  var start = text.length - maxChars;
  // Start at the next word when the cut falls inside one (unless the word
  // is very long, as in text without spaces).
  final previous = text.codeUnitAt(start - 1);
  if (!_isSpace(previous) && !_isSpace(text.codeUnitAt(start))) {
    final space = text.indexOf(RegExp(r'\s'), start);
    if (space >= 0 && space - start < maxChars ~/ 4) start = space + 1;
  }
  final unit = text.codeUnitAt(start);
  if (unit >= 0xDC00 && unit <= 0xDFFF) start++;
  return '…${text.substring(start).trimLeft()}';
}

bool _isSpace(int unit) =>
    unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D;
