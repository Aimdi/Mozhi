import 'dart:async';
import 'dart:collection';

import 'package:equatable/equatable.dart';
import 'package:mozhi/documents/core/batch_codec.dart';
import 'package:mozhi/documents/core/chunker.dart';
import 'package:mozhi/documents/core/parsed_document.dart';
import 'package:translation_repository/translation_repository.dart';

/// Thrown when an engine returns an empty translation for non-empty text.
class EmptyTranslationException implements Exception {
  const new();

  @override
  String toString() => 'EmptyTranslationException';
}

/// Snapshot of a document translation.
class DocumentProgress extends Equatable {
  const new({
    required this.total,
    this.results = const {},
    this.failures = const {},
    this.isComplete = false,
  });

  /// Number of chunks in the plan.
  final int total;

  /// Translated chunks: chunk index -> one translation per unit.
  final Map<int, List<String>> results;

  /// Chunks that failed (after retries): chunk index -> error.
  final Map<int, Object> failures;

  /// True on the last event of a run.
  final bool isComplete;

  int get done => results.length;
  int get failed => failures.length;

  /// Share of translated chunks (0..1).
  double get fraction => total == 0 ? 1 : done / total;

  @override
  List<Object?> get props => [total, results, failures, isComplete];
}

/// Decides whether a failed request is worth repeating.
typedef RetryPolicy = bool Function(Object error);

/// Translates a [ChunkPlan] chunk by chunk through
/// [TranslationRepository.translate], keeping [concurrency] requests in
/// flight.
///
/// * The final result of each translation stream is used (AI engines
///   stream snapshots).
/// * Batched chunks whose markers/paragraphs come back misaligned are
///   translated again unit by unit.
/// * Failed chunks are retried up to [maxAttempts] times in total (with
///   [retryDelay] × attempt between tries) when [shouldRetry] allows it;
///   chunks that still fail are reported in [DocumentProgress.failures]
///   and the run continues.
/// * Cancelling the subscription of [translate] stops scheduling and
///   cancels in-flight requests.
class DocumentTranslator {
  new({
    required this._repository,
    this.concurrency = 2,
    this.maxAttempts = 3,
    this.retryDelay = const Duration(seconds: 1),
    RetryPolicy? shouldRetry,
  }) : assert(concurrency >= 1, 'concurrency must be positive'),
       assert(maxAttempts >= 1, 'maxAttempts must be positive'),
       shouldRetry = shouldRetry ?? isRetryableError;

  final TranslationRepository _repository;
  final int concurrency;
  final int maxAttempts;
  final Duration retryDelay;
  final RetryPolicy shouldRetry;

  /// Instruction added for AI engines so that batch markers and
  /// placeholders survive.
  static const markerInstruction =
      'The text contains numbered markers like ⟦1⟧ and placeholders like '
      '⟨1⟩. Keep every one of them exactly as written and in place; each '
      '⟦n⟧ marker starts its own line. Do not add or remove markers.';

  /// Default [RetryPolicy]: retries network errors, timeouts, rate limits
  /// and server errors; not refusals, auth/not-found errors, bad requests
  /// or programming errors.
  static bool isRetryableError(Object error) => switch (error) {
    LlmRefusalException() => false,
    LlmApiException(:final statusCode?) =>
      statusCode == 429 || statusCode == 408 || statusCode >= 500,
    LlmApiException() => true,
    MozhiApiException(:final isRetryable) => isRetryable,
    ArgumentError() || StateError() || UnsupportedError() => false,
    _ => true,
  };

  /// Translates the chunks of [plan] that are not in [completed] (or only
  /// [only], when given), emitting a [DocumentProgress] at the start,
  /// after every chunk, and a final one with `isComplete: true`.
  ///
  /// Results and failures are cumulative and include [completed].
  Stream<DocumentProgress> translate(
    ChunkPlan plan, {
    required TranslationEngine engine,
    required Language source,
    required Language target,
    TranslationOptions options = const TranslationOptions(),
    Map<int, List<String>> completed = const {},
    Iterable<int>? only,
  }) {
    final results = Map<int, List<String>>.of(completed);
    final failures = <int, Object>{};
    final queue = Queue<int>.of([
      for (final index in only ?? Iterable<int>.generate(plan.chunks.length))
        if (index >= 0 &&
            index < plan.chunks.length &&
            !results.containsKey(index))
          index,
    ]);
    final cancel = _CancelToken();
    late final StreamController<DocumentProgress> controller;

    DocumentProgress snapshot({bool complete = false}) => DocumentProgress(
      total: plan.chunks.length,
      results: Map.unmodifiable(results),
      failures: Map.unmodifiable(failures),
      isComplete: complete,
    );

    Future<void> worker() async {
      while (!cancel.isCancelled && queue.isNotEmpty) {
        final index = queue.removeFirst();
        try {
          final translations = await _translateChunk(
            plan.chunks[index],
            engine: engine,
            source: source,
            target: target,
            options: options,
            cancel: cancel,
          );
          if (cancel.isCancelled) return;
          results[index] = translations;
        } on _Cancelled {
          return;
        } on Object catch (error) {
          if (cancel.isCancelled) return;
          failures[index] = error;
        }
        controller.add(snapshot());
      }
    }

    Future<void> run() async {
      controller.add(snapshot(complete: queue.isEmpty));
      if (queue.isNotEmpty) {
        final workers = concurrency < queue.length ? concurrency : queue.length;
        await Future.wait([for (var i = 0; i < workers; i++) worker()]);
        if (cancel.isCancelled) return;
        controller.add(snapshot(complete: true));
      }
      await controller.close();
    }

    controller = StreamController<DocumentProgress>(
      onListen: () => unawaited(run()),
      onCancel: cancel.cancel,
    );
    return controller.stream;
  }

  Future<List<String>> _translateChunk(
    Chunk chunk, {
    required TranslationEngine engine,
    required Language source,
    required Language target,
    required TranslationOptions options,
    required _CancelToken cancel,
  }) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await _attempt(
          chunk,
          engine: engine,
          source: source,
          target: target,
          options: options,
          cancel: cancel,
        );
      } on _Cancelled {
        rethrow;
      } on Object catch (error) {
        if (attempt >= maxAttempts || !shouldRetry(error)) rethrow;
      }
      await cancel.delay(retryDelay * attempt);
    }
  }

  Future<List<String>> _attempt(
    Chunk chunk, {
    required TranslationEngine engine,
    required Language source,
    required Language target,
    required TranslationOptions options,
    required _CancelToken cancel,
  }) async {
    Future<String> translate(String text) => _translateText(
      engine,
      TranslationRequest(
        text: text,
        source: source,
        target: target,
        options: _options(engine, options, text),
      ),
      cancel,
    );

    if (chunk.units.length == 1) return [await translate(chunk.payload)];
    final split = chunk.split(await translate(chunk.payload));
    if (split != null) return split;
    // Alignment lost: translate unit by unit.
    return [for (final unit in chunk.units) await translate(unit.text)];
  }

  static TranslationOptions _options(
    TranslationEngine engine,
    TranslationOptions options,
    String text,
  ) {
    final needsInstruction =
        engine.isAi &&
        (text.contains(BatchCodec.markerOpen) ||
            text.contains(placeholderOpen));
    final instructions = options.instructions.trim();
    return options.copyWith(
      preserveFormatting: true,
      instructions: needsInstruction
          ? [
              markerInstruction,
              if (instructions.isNotEmpty) instructions,
            ].join(' ')
          : options.instructions,
    );
  }

  Future<String> _translateText(
    TranslationEngine engine,
    TranslationRequest request,
    _CancelToken cancel,
  ) {
    if (cancel.isCancelled) return Future.error(const _Cancelled());
    final completer = Completer<String>();
    TranslationResult? last;
    late final StreamSubscription<TranslationResult> subscription;
    void abort() {
      unawaited(subscription.cancel());
      if (!completer.isCompleted) completer.completeError(const _Cancelled());
    }

    subscription = _repository
        .translate(engine, request)
        .listen(
          (result) => last = result,
          onError: (Object error, StackTrace stackTrace) {
            if (!completer.isCompleted) {
              completer.completeError(error, stackTrace);
            }
          },
          onDone: () {
            if (completer.isCompleted) return;
            final text = last?.text.trim() ?? '';
            if (text.isEmpty) {
              completer.completeError(const EmptyTranslationException());
            } else {
              completer.complete(text);
            }
          },
          cancelOnError: true,
        );
    cancel.add(abort);
    return completer.future.whenComplete(() => cancel.remove(abort));
  }
}

class _Cancelled implements Exception {
  const new();
}

class _CancelToken {
  final Set<void Function()> _listeners = {};
  bool isCancelled = false;

  void add(void Function() listener) => _listeners.add(listener);
  void remove(void Function() listener) => _listeners.remove(listener);

  void cancel() {
    if (isCancelled) return;
    isCancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }

  /// Waits [duration]; throws [_Cancelled] when cancelled meanwhile.
  Future<void> delay(Duration duration) {
    if (isCancelled) return Future.error(const _Cancelled());
    final completer = Completer<void>();
    late final Timer timer;
    void abort() {
      timer.cancel();
      if (!completer.isCompleted) completer.completeError(const _Cancelled());
    }

    timer = Timer(duration, () {
      remove(abort);
      if (!completer.isCompleted) completer.complete();
    });
    add(abort);
    return completer.future;
  }
}
