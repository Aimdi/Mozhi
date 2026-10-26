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
    this.maskedPersonalData = 0,
  });

  /// Number of chunks in the plan.
  final int total;

  /// Translated chunks: chunk index -> one translation per unit.
  final Map<int, List<String>> results;

  /// Chunks that failed (after retries): chunk index -> error.
  final Map<int, Object> failures;

  /// True on the last event of a run.
  final bool isComplete;

  /// Items of personal data the personal data shield kept on the device
  /// in this run's requests (`TranslationResult.maskedPersonalData`,
  /// summed over the requests: an address in two chunks counts twice).
  final int maskedPersonalData;

  int get done => results.length;
  int get failed => failures.length;

  /// Share of translated chunks (0..1).
  double get fraction => total == 0 ? 1 : done / total;

  @override
  List<Object?> get props => [
    total,
    results,
    failures,
    isComplete,
    maskedPersonalData,
  ];
}

/// Decides whether a failed request is worth repeating.
typedef RetryPolicy = bool Function(Object error);

/// Called after each request that an engine answered (not cache hits),
/// e.g. to count what was sent to a bring-your-own-key provider.
typedef TranslatedCallback = void Function(
  TranslationEngine engine,
  TranslationRequest request,
  TranslationResult result,
);

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
/// * With "Detect language" ([Language.auto]) and an engine that needs a
///   source language (the offline engine, translation-specialised AI
///   models), the language of the document is identified once on the
///   device ([TranslationRepository.detectLanguage] with the offline
///   engine) from its first chunks, and every chunk is translated from it.
///   Other engines (or when the device cannot tell) keep detecting per
///   request. A chunk whose language cannot be told
///   ([SourceLanguageRequiredException]) is translated from the language
///   detected for earlier chunks, or else kept as it is (it is not
///   retried and does not fail).
class DocumentTranslator {
  new({
    required this._repository,
    this.concurrency = 2,
    this.maxAttempts = 3,
    this.retryDelay = const Duration(seconds: 1),
    RetryPolicy? shouldRetry,
    this.onTranslated,
  }) : assert(concurrency >= 1, 'concurrency must be positive'),
       assert(maxAttempts >= 1, 'maxAttempts must be positive'),
       shouldRetry = shouldRetry ?? isRetryableError;

  final TranslationRepository _repository;
  final int concurrency;
  final int maxAttempts;
  final Duration retryDelay;
  final RetryPolicy shouldRetry;

  /// See [TranslatedCallback]. Its errors are ignored.
  final TranslatedCallback? onTranslated;

  /// Characters of the document (its first chunks) that are looked at to
  /// tell its language: plenty for identification, cheap for long files.
  static const detectionSampleLength = 4000;

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
    SourceLanguageRequiredException() => false,
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
    final language = _RunLanguage(source);
    late final StreamController<DocumentProgress> controller;

    DocumentProgress snapshot({bool complete = false}) => DocumentProgress(
      total: plan.chunks.length,
      results: Map.unmodifiable(results),
      failures: Map.unmodifiable(failures),
      isComplete: complete,
      maskedPersonalData: language.maskedPersonalData,
    );

    Future<void> worker() async {
      while (!cancel.isCancelled && queue.isNotEmpty) {
        final index = queue.removeFirst();
        try {
          final translations = await _translateChunk(
            plan.chunks[index],
            engine: engine,
            language: language,
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
        if (source.isAuto) {
          final detected = await _detectLanguage(plan, engine);
          if (cancel.isCancelled) return;
          if (detected != null) {
            language
              ..source = _languageOf(detected)
              ..detected = detected;
          }
        }
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

  /// The language of [plan] identified on the device from its first
  /// chunks, for an [engine] that needs a source language (the offline
  /// engine and translation-specialised AI models, which identify on the
  /// device first anyway). Null for other engines, without an on-device
  /// engine, or when the device cannot tell: nothing is ever sent over the
  /// network to detect it.
  Future<String?> _detectLanguage(
    ChunkPlan plan,
    TranslationEngine engine,
  ) async {
    if (!engine.isOffline && !engine.usesMtProfile) return null;
    try {
      // Without the on-device engine, detection would ask Mozhi instead.
      if (!_repository.hasOfflineEngine) return null;
      final sample = _detectionSample(plan);
      if (sample.isEmpty) return null;
      final detected = await _repository.detectLanguage(
        sample,
        // The offline engine always answers with the on-device identifier.
        engine: engine.isOffline ? engine : TranslationEngine.offline(),
      );
      final code = detected.code.trim();
      return code.isEmpty ? null : code;
    } on Object {
      // Undetectable (or a repository without an on-device engine): every
      // request detects on its own.
      return null;
    }
  }

  /// The texts of the first chunks of [plan] (without placeholders) joined
  /// with blank lines, up to [detectionSampleLength] characters.
  static String _detectionSample(ChunkPlan plan) {
    final buffer = StringBuffer();
    outer:
    for (final chunk in plan.chunks) {
      for (final unit in chunk.units) {
        final text = unit.text
            .replaceAll(placeholderPattern, ' ')
            .replaceAll(_spaces, ' ')
            .trim();
        if (text.isEmpty) continue;
        if (buffer.isNotEmpty) buffer.write('\n\n');
        buffer.write(text);
        if (buffer.length >= detectionSampleLength) break outer;
      }
    }
    final sample = buffer.toString();
    if (sample.length <= detectionSampleLength) return sample;
    var end = detectionSampleLength;
    // Never cut a surrogate pair in half.
    final last = sample.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end--;
    return sample.substring(0, end);
  }

  static final _spaces = RegExp(r'[ \t]{2,}');

  static Language _languageOf(String code) =>
      LanguageCatalog.byCode(code) ??
      Language(code: code, name: LanguageCatalog.nameOf(code));

  Future<List<String>> _translateChunk(
    Chunk chunk, {
    required TranslationEngine engine,
    required _RunLanguage language,
    required Language target,
    required TranslationOptions options,
    required _CancelToken cancel,
  }) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await _attempt(
          chunk,
          engine: engine,
          language: language,
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
    required _RunLanguage language,
    required Language target,
    required TranslationOptions options,
    required _CancelToken cancel,
  }) async {
    Future<String> translateFrom(Language source, String text) =>
        _translateText(
          engine,
          TranslationRequest(
            text: text,
            source: source,
            target: target,
            options: _options(engine, options, text),
          ),
          cancel,
          language,
        );

    /// The translation of [text]; null when its language cannot be told
    /// and none is known from earlier chunks (it is kept as it is).
    Future<String?> translate(String text) async {
      final source = language.source;
      try {
        return await translateFrom(source, text);
      } on SourceLanguageRequiredException {
        if (!source.isAuto) rethrow;
        final known = language.detected;
        if (known == null) return null;
        return await translateFrom(_languageOf(known), text);
      }
    }

    final originals = [for (final unit in chunk.units) unit.text];
    final batch = await translate(chunk.payload);
    if (batch == null) return originals;
    if (chunk.units.length == 1) return [batch];
    final split = chunk.split(batch);
    if (split != null) return split;
    // Alignment lost: translate unit by unit.
    return [
      for (final unit in chunk.units) await translate(unit.text) ?? unit.text,
    ];
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
    _RunLanguage language,
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
            final result = last;
            final text = result?.text.trim() ?? '';
            if (result == null || text.isEmpty) {
              completer.completeError(const EmptyTranslationException());
              return;
            }
            if (result.detectedSource case final detected?
                when detected.trim().isNotEmpty) {
              language.detected ??= detected;
            }
            language.maskedPersonalData += result.maskedPersonalData;
            if (!result.fromCache) {
              try {
                onTranslated?.call(engine, request, result);
              } on Object {
                // Bookkeeping must never fail a translation.
              }
            }
            completer.complete(text);
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

/// The source language of one [DocumentTranslator.translate] run (and
/// what its requests kept on the device).
class _RunLanguage {
  new(this.source);

  /// See [DocumentProgress.maskedPersonalData].
  int maskedPersonalData = 0;

  /// The language every request uses: the requested one, or the one
  /// identified for the whole document.
  Language source;

  /// The document's language: identified for the whole document, or the
  /// first one an engine detected.
  String? detected;
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
