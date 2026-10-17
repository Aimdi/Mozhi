import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:bloc/bloc.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:mozhi/web_translate/core/block_batcher.dart';
import 'package:mozhi/web_translate/core/readable_extractor.dart';
import 'package:mozhi/web_translate/core/web_url.dart';
import 'package:mozhi/web_translate/cubit/web_translate_state.dart';
import 'package:mozhi/web_translate/data/page_extraction.dart';
import 'package:mozhi/web_translate/data/web_page_fetcher.dart';
import 'package:translation_repository/translation_repository.dart';

export 'web_translate_state.dart';

/// Extracts the readable content of a downloaded page (possibly in a
/// background isolate).
typedef ReadablePageExtractor = Future<ReadablePage> Function(
  FetchedWebPage page,
);

/// Drives the web page translator (Kagi-style "translate this URL").
///
/// [load] validates the address ([normalizeWebUrl]), downloads it with the
/// [WebPageFetcher], extracts the readable blocks and, given a selection,
/// translates them: blocks are packed into batches ([BlockBatcher]) that
/// are translated through [TranslationRepository.translate] (only final
/// results are used) with `concurrency` requests in flight. A batch whose
/// result cannot be split back into its blocks is translated block by
/// block. Progress is emitted per batch; [cancel] stops loading or
/// translating (keeping what is translated) and [resume] continues.
///
/// With a `usageTracker`, every answered request (each batch and each
/// block translated on its own) to a bring-your-own-key provider (engines
/// with a `providerId`) is counted once. Results served from the
/// translation cache and failed or cancelled requests are not counted.
///
/// The cubit owns the `fetcher` and closes it on [close].
class WebTranslateCubit extends Cubit<WebTranslateState> {
  new({
    required this._repository,
    required this._fetcher,
    ReadablePageExtractor? extract,
    this._batcher = const BlockBatcher(),
    int concurrency = 2,
    String initialUrl = '',
    this._usageTracker,
  }) : _extract = extract ?? _extractInline,
       _concurrency = math.max(1, concurrency),
       super(WebTranslateState(url: initialUrl));

  static Future<ReadablePage> _extractInline(FetchedWebPage page) async =>
      extractFetchedPage(page);

  /// Id of the page title among the translation items.
  static const _titleId = -1;

  final TranslationRepository _repository;
  final WebPageFetcher _fetcher;
  final ReadablePageExtractor _extract;
  final BlockBatcher _batcher;
  final int _concurrency;

  /// Counts what answered requests send to and receive from a
  /// bring-your-own-key provider; optional.
  final UsageTracker? _usageTracker;

  int _loadRequest = 0;
  Completer<void>? _abortFetch;

  /// Whether the privacy settings keep everything on the device.
  bool get _offlineOnly {
    try {
      return _repository.privacyMode == PrivacyMode.offlineOnly;
    } on Object {
      // A repository test double without privacy settings.
      return false;
    }
  }

  _TranslationJob? _job;

  /// Updates the address field.
  void setUrl(String url) {
    if (url == state.url && !state.urlInvalid) return;
    emit(state.copyWith(url: url, urlInvalid: false));
  }

  void setMode(ReaderMode mode) {
    if (mode != state.mode) emit(state.copyWith(mode: mode));
  }

  /// Loads the address in the field and, with a [selection], translates it.
  /// An invalid address only sets `urlInvalid`.
  ///
  /// In offline-only mode (`TranslationRepository.privacyMode`) the page is
  /// not fetched: the state fails with a `ConsentRequiredException` of
  /// [ConsentKind.offlineOnly].
  Future<void> load({WebTranslateSelection? selection}) async {
    final uri = normalizeWebUrl(state.url);
    if (uri == null) {
      emit(state.copyWith(urlInvalid: true));
      return;
    }
    if (_offlineOnly) {
      emit(
        WebTranslateState(
          url: uri.toString(),
          status: WebTranslateStatus.failure,
          selection: selection,
          mode: state.mode,
          error: ConsentRequiredException(
            kind: ConsentKind.offlineOnly,
            destination: PublicInstanceDestination(uri.host),
            engineId: selection?.engine.id ?? '',
          ),
        ),
      );
      return;
    }
    final request = ++_loadRequest;
    _abortCurrentFetch();
    _cancelJob();
    final abort = _abortFetch = Completer<void>();
    emit(
      WebTranslateState(
        url: uri.toString(),
        status: WebTranslateStatus.loading,
        selection: selection,
        mode: state.mode,
      ),
    );

    final FetchedWebPage fetched;
    final ReadablePage page;
    try {
      fetched = await _fetcher.fetch(uri, abortTrigger: abort.future);
      if (!_isCurrentLoad(request)) return;
      page = await _extract(fetched);
      if (!_isCurrentLoad(request)) return;
    } on Object catch (error) {
      if (!_isCurrentLoad(request)) return;
      emit(
        state.copyWith(status: WebTranslateStatus.failure, error: () => error),
      );
      return;
    } finally {
      if (identical(_abortFetch, abort)) _abortFetch = null;
    }

    if (page.isEmpty) {
      emit(
        state.copyWith(
          status: WebTranslateStatus.failure,
          pageUri: () => fetched.url,
          error: () =>
              WebPageException(WebPageError.noContent, uri: fetched.url),
        ),
      );
      return;
    }
    emit(
      state.copyWith(
        status: WebTranslateStatus.loaded,
        page: () => page,
        pageUri: () => fetched.url,
        truncated: fetched.truncated,
        unsupportedCharset: () => fetched.unsupportedCharset,
        translations: List<String?>.filled(page.blocks.length, null),
      ),
    );
    if (selection != null) await translate(selection);
  }

  /// Translates the loaded page from scratch with [selection] (e.g. after
  /// the target language changed). Does nothing without a page.
  Future<void> translate(WebTranslateSelection selection) async {
    final page = state.page;
    if (page == null || state.status == WebTranslateStatus.loading) return;
    _cancelJob();
    emit(
      state.copyWith(
        status: WebTranslateStatus.translating,
        selection: () => selection,
        translations: List<String?>.filled(page.blocks.length, null),
        translatedTitle: () => null,
        detectedSource: () => null,
        error: () => null,
      ),
    );
    await _run(selection);
  }

  /// Continues a stopped or failed translation with the same selection,
  /// translating only what is still missing.
  Future<void> resume() async {
    final selection = state.selection;
    if (!state.hasPage || selection == null || state.isBusy) return;
    _cancelJob();
    emit(
      state.copyWith(status: WebTranslateStatus.translating, error: () => null),
    );
    await _run(selection);
  }

  /// Stops loading (back to idle) or translating (keeping the blocks
  /// translated so far).
  Future<void> cancel() async {
    switch (state.status) {
      case WebTranslateStatus.loading:
        _loadRequest++;
        _abortCurrentFetch();
        emit(state.copyWith(status: WebTranslateStatus.idle));
      case WebTranslateStatus.translating:
        _cancelJob();
        emit(state.copyWith(status: WebTranslateStatus.stopped));
      case WebTranslateStatus.idle ||
          WebTranslateStatus.loaded ||
          WebTranslateStatus.translated ||
          WebTranslateStatus.stopped ||
          WebTranslateStatus.failure:
        return;
    }
  }

  bool _isCurrentLoad(int request) => !isClosed && request == _loadRequest;

  void _abortCurrentFetch() {
    final abort = _abortFetch;
    _abortFetch = null;
    if (abort != null && !abort.isCompleted) abort.complete();
  }

  void _cancelJob() {
    _job?.cancel();
    _job = null;
  }

  Future<void> _run(WebTranslateSelection selection) async {
    final page = state.page!;
    final job = _job = _TranslationJob();
    final items = <TranslationItem>[
      if (state.translatedTitle == null && page.title.trim().isNotEmpty)
        TranslationItem(_titleId, page.title),
      for (var i = 0; i < page.blocks.length; i++)
        if (page.blocks[i].isTranslatable && state.translationAt(i) == null)
          TranslationItem(i, page.blocks[i].text),
    ];
    final queue = Queue.of(_batcher.batch(items));

    Future<void> worker() async {
      while (queue.isNotEmpty && !job.cancelled) {
        final batch = queue.removeFirst();
        final texts = await _translateBatch(job, batch, selection);
        if (job.cancelled) return;
        _apply(job, batch, texts);
      }
    }

    try {
      await Future.wait([
        for (var i = 0; i < _concurrency; i++) worker(),
      ], eagerError: true);
    } on _Cancelled {
      return;
    } on Object catch (error) {
      if (job.cancelled) return;
      job.cancel();
      if (identical(_job, job)) _job = null;
      if (isClosed) return;
      emit(
        state.copyWith(status: WebTranslateStatus.failure, error: () => error),
      );
      return;
    }
    if (job.cancelled || isClosed) return;
    _job = null;
    emit(state.copyWith(status: WebTranslateStatus.translated));
  }

  Future<List<String>> _translateBatch(
    _TranslationJob job,
    List<TranslationItem> batch,
    WebTranslateSelection selection,
  ) async {
    if (batch.length > 1) {
      final result = await _translateText(
        job,
        BlockBatcher.join(batch),
        selection,
      );
      final parts = result == null
          ? null
          : BlockBatcher.split(result.text, batch.length);
      if (parts != null) return parts;
    }
    // One block, or the translator merged/split paragraphs: one by one.
    final texts = <String>[];
    for (final item in batch) {
      final result = await _translateText(job, item.text, selection);
      final text = result?.text.trim() ?? '';
      texts.add(text.isEmpty ? item.text : text);
    }
    return texts;
  }

  /// Translates [text] and completes with the final result (null when the
  /// stream completed without one).
  Future<TranslationResult?> _translateText(
    _TranslationJob job,
    String text,
    WebTranslateSelection selection,
  ) {
    final completer = Completer<TranslationResult?>();
    TranslationResult? last;
    final request = TranslationRequest(
      text: text,
      source: selection.source,
      target: selection.target,
      options: selection.options.copyWith(preserveFormatting: true),
    );
    late final StreamSubscription<TranslationResult> subscription;
    subscription = _repository
        .translate(selection.engine, request)
        .listen(
          (result) => last = result,
          onError: (Object error, StackTrace stackTrace) {
            job.untrack(subscription);
            if (!completer.isCompleted) {
              completer.completeError(error, stackTrace);
            }
          },
          onDone: () {
            job.untrack(subscription);
            final result = last;
            if (result != null && !job.cancelled) {
              _recordUsage(selection.engine, input: text, result: result);
            }
            if (result?.detectedSource != null) {
              job.detectedSource ??= result!.detectedSource;
            }
            if (!completer.isCompleted) completer.complete(result);
          },
          cancelOnError: true,
        );
    job.track(subscription, completer);
    return completer.future;
  }

  /// Counts the answered request for [input] to [engine]'s provider (engines
  /// with a `providerId`) when a usage tracker is set, unless [result] is
  /// incomplete or came from the cache. Never throws; tracker errors are
  /// ignored.
  void _recordUsage(
    TranslationEngine engine, {
    required String input,
    required TranslationResult result,
  }) {
    final tracker = _usageTracker;
    final providerId = engine.providerId;
    if (tracker == null || providerId == null || providerId.isEmpty) return;
    if (!result.isComplete || result.fromCache) return;
    try {
      unawaited(
        tracker
            .recordText(providerId, input: input, output: result.text)
            .then((_) {}, onError: (Object _) {}),
      );
    } on Object {
      // Usage counting must never break page translation.
    }
  }

  void _apply(
    _TranslationJob job,
    List<TranslationItem> batch,
    List<String> texts,
  ) {
    if (isClosed) return;
    final translations = List<String?>.of(state.translations);
    var title = state.translatedTitle;
    for (var i = 0; i < batch.length; i++) {
      final id = batch[i].id;
      if (id == _titleId) {
        title = texts[i];
      } else if (id < translations.length) {
        translations[id] = texts[i];
      }
    }
    emit(
      state.copyWith(
        translations: translations,
        translatedTitle: () => title,
        detectedSource: () => state.detectedSource ?? job.detectedSource,
      ),
    );
  }

  @override
  Future<void> close() {
    _loadRequest++;
    _abortCurrentFetch();
    _cancelJob();
    _fetcher.close();
    return super.close();
  }
}

/// Thrown into pending translations of a cancelled job.
class _Cancelled implements Exception {
  const new();
}

/// The in-flight requests of one translation run.
class _TranslationJob {
  bool cancelled = false;
  String? detectedSource;
  final _active = <StreamSubscription<Object?>, Completer<Object?>>{};

  void track(
    StreamSubscription<Object?> subscription,
    Completer<Object?> completer,
  ) {
    // coverage:ignore-start
    if (cancelled) {
      // Defensive: requests are only started while the job is running.
      unawaited(subscription.cancel());
      if (!completer.isCompleted) completer.completeError(const _Cancelled());
      return;
    }
    // coverage:ignore-end
    if (!completer.isCompleted) _active[subscription] = completer;
  }

  void untrack(StreamSubscription<Object?> subscription) =>
      _active.remove(subscription);

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    for (final MapEntry(key: subscription, value: completer)
        in _active.entries.toList()) {
      unawaited(subscription.cancel());
      if (!completer.isCompleted) completer.completeError(const _Cancelled());
    }
    _active.clear();
  }
}
