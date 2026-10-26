import 'dart:async';
import 'dart:ui' show Size;

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:mozhi/documents/core/chunker.dart';
import 'package:mozhi/documents/core/document_format.dart';
import 'package:mozhi/documents/core/document_translator.dart';
import 'package:mozhi/documents/pdf/method_channel_pdf_pages.dart';
import 'package:mozhi/documents/pdf/pdf_document.dart';
import 'package:mozhi/documents/pdf/pdf_page_reader.dart';
import 'package:mozhi/documents/pdf/pdf_pages.dart';
import 'package:mozhi/documents/pdf/pdf_scratch.dart';
import 'package:mozhi/documents/pdf/unsupported_pdf_pages.dart';
import 'package:mozhi/image_translate/data/text_recognition_plan.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/platform/text_recognition.dart';
import 'package:translation_repository/translation_repository.dart';

/// The platform's [PdfPages]: the Android plugin, or [UnsupportedPdfPages]
/// on the web and elsewhere.
PdfPages defaultPdfPages() =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android
    ? MethodChannelPdfPages()
    : const UnsupportedPdfPages();

/// Snapshot of a PDF translation ([PdfTranslator.translate]).
@immutable
class PdfProgress extends Equatable {
  const new({
    required this.total,
    this.pages = const {},
    this.results = const {},
    this.partial = const {},
    this.failures = const {},
    this.page,
    this.stage,
    this.isComplete = false,
  });

  /// Pages of the PDF.
  final int total;

  /// The pages read so far (including those the run started with).
  final Map<int, PdfPageText> pages;

  /// Finished pages: page index -> one translation per paragraph (none for
  /// a page without text).
  final Map<int, List<String>> results;

  /// Pages that failed half-way: page index -> their finished chunks.
  final Map<int, Map<int, List<String>>> partial;

  /// Pages that failed: page index -> the (first) error.
  final Map<int, Object> failures;

  /// The page being read or translated.
  final int? page;
  final PdfStage? stage;

  /// True on the last event of a run.
  final bool isComplete;

  int get done => results.length;

  @override
  List<Object?> get props => [
    total,
    pages,
    results,
    partial,
    failures,
    page,
    stage,
    isComplete,
  ];
}

/// Translates PDFs on the device, page by page: renders a page, reads it
/// ([PdfPageReader]: Tesseract with its layout), translates its paragraphs
/// with the document's engine through the [DocumentTranslator] (the same
/// options, chunking, retries, privacy routing and, for on-device AI, the
/// pause while the phone is hot as other documents), and writes the
/// translated PDF ([PdfPages.write]).
///
/// The PDF is copied to the app's private cache only for the platform to
/// open it ([PdfScratch]; the copy is deleted once it is open), the
/// rendered pages stay in memory only while they are read, and the
/// translated PDF is written to the cache only until its bytes are read
/// back.
class PdfTranslator {
  new({
    required this._pages,
    required this._recognizer,
    required this._translator,
    required this._scratch,
    this._chunker = const Chunker(),
    int minConfidence = 40,
    this.maxFailedPagesInARow = 3,
  }) : _reader = switch (textRecognitionPixelsOf(_recognizer)) {
         final pixels? => PdfPageReader(
           pages: _pages,
           recognizer: pixels,
           minConfidence: minConfidence,
         ),
         null => null,
       };

  /// The app's: the platform's pages ([defaultPdfPages]), its Tesseract
  /// recognizer ([defaultTextRecognitionService], in every Android build)
  /// and [translator].
  factory platform({
    required DocumentTranslator translator,
    Chunker chunker = const Chunker(),
  }) => PdfTranslator(
    pages: defaultPdfPages(),
    recognizer: defaultTextRecognitionService(),
    translator: translator,
    scratch: defaultPdfScratch(),
    chunker: chunker,
  );

  final PdfPages _pages;
  final TextRecognitionService _recognizer;
  final DocumentTranslator _translator;
  final PdfScratch _scratch;
  final Chunker _chunker;
  final PdfPageReader? _reader;

  /// A run stops after this many pages in a row whose translation failed
  /// (an engine that answers nothing would otherwise have every page read
  /// for nothing). The rest can be translated again.
  final int maxFailedPagesInARow;

  /// Whether PDFs are opened here (the platform reads them).
  bool get isSupported => _pages.isSupported;

  /// Whether pages can be read here (text recognition works).
  bool get canRead => _reader != null && _recognizer.isSupported;

  /// The recognizer's downloadable language data (for the offer to get
  /// the data of a language), when it has some.
  TextRecognitionLanguageData? get languageData =>
      textRecognitionLanguageDataOf(_recognizer);

  /// Opens [bytes] as the PDF (closing the one open before). Throws
  /// [PdfOpenException]: [PdfOpenErrorKind.tooLarge] over
  /// [PdfLimits.maxBytes] or [PdfLimits.maxPages],
  /// [PdfOpenErrorKind.damaged] without a PDF header.
  Future<PdfInfo> open(Uint8List bytes) async {
    if (!isSupported) {
      throw const PdfOpenException(kind: PdfOpenErrorKind.unsupported);
    }
    if (bytes.length > PdfLimits.maxBytes) {
      throw const PdfOpenException(kind: PdfOpenErrorKind.tooLarge);
    }
    if (!DocumentFormat.isPdfBytes(bytes)) {
      throw const PdfOpenException(kind: PdfOpenErrorKind.damaged);
    }
    final path = await _scratch.write(bytes);
    try {
      final info = await _pages.open(path);
      if (info.pageCount > PdfLimits.maxPages) {
        await _pages.close();
        throw const PdfOpenException(kind: PdfOpenErrorKind.tooLarge);
      }
      return info;
    } finally {
      await _scratch.delete(path);
    }
  }

  /// Which recognition data reads a PDF in [source] (see
  /// [planTextRecognition]; [preferred] for "Detect language").
  Future<TextRecognitionPlan> plan(
    Language source, {
    List<String> preferred = const [],
  }) async {
    final data = languageData;
    if (data == null || !canRead) return const TextRecognitionUnsupported();
    return await planTextRecognition(
      data,
      source: source,
      preferred: preferred,
    );
  }

  /// Reads page [page] (of [size] points) with [codes]. Throws as
  /// [PdfPageReader.read].
  Future<PdfPageText> read(int page, Size size, List<String> codes) {
    final reader = _reader;
    if (reader == null) {
      return Future.error(
        const ImageTranslateException(
          ImageTranslateErrorKind.recognitionFailed,
        ),
      );
    }
    return reader.read(page, size, codes);
  }

  /// Translates the pages of a PDF of [pageSizes] that are not in
  /// [completed] (or only [only], when given), one page at a time: each is
  /// taken from [known] when it was read with [codes], read otherwise,
  /// and its paragraphs are translated (a page that failed half-way
  /// resumes from [partial]). Emits a [PdfProgress] at the start, when a
  /// page is read or translated and when it is done, and a last one with
  /// `isComplete: true`.
  ///
  /// A page whose reading or translation fails is reported in
  /// [PdfProgress.failures] and the run goes on, except when recognition
  /// data is missing, the privacy settings stop a request (the user is
  /// asked first: no further page is read) or [maxFailedPagesInARow]
  /// pages failed in a row. Cancelling the subscription stops the run and
  /// its requests.
  Stream<PdfProgress> translate({
    required List<Size> pageSizes,
    required List<String> codes,
    required TranslationEngine engine,
    required Language source,
    required Language target,
    TranslationOptions options = const TranslationOptions(),
    Map<int, PdfPageText> known = const {},
    Map<int, List<String>> completed = const {},
    Map<int, Map<int, List<String>>> partial = const {},
    Iterable<int>? only,
  }) => _PdfRun(
    this,
    pageSizes: pageSizes,
    codes: codes,
    engine: engine,
    source: source,
    target: target,
    options: options,
    known: known,
    completed: completed,
    partial: partial,
    only: only,
  ).stream;

  /// Writes the translated PDF of [pages] and returns its bytes. Throws
  /// [PdfWriteException].
  Future<Uint8List> write(List<PdfOutputPage> pages) async {
    final path = await _scratch.newPath();
    try {
      await _pages.write(path, pages);
      return await _scratch.take(path);
    } on PdfWriteException {
      rethrow;
    } on Object catch (error) {
      throw PdfWriteException(cause: error);
    } finally {
      await _scratch.delete(path);
    }
  }

  /// Closes the open PDF.
  Future<void> close() => _pages.close();
}

/// One [PdfTranslator.translate] run.
class _PdfRun {
  new(
    this._owner, {
    required this.pageSizes,
    required this.codes,
    required this.engine,
    required this.source,
    required this.target,
    required this.options,
    required Map<int, PdfPageText> known,
    required Map<int, List<String>> completed,
    required Map<int, Map<int, List<String>>> partial,
    required Iterable<int>? only,
  }) : _pages = Map.of(known),
       _results = Map.of(completed),
       _partial = Map.of(partial),
       _queue = [
         for (final index in only ?? Iterable<int>.generate(pageSizes.length))
           if (index >= 0 &&
               index < pageSizes.length &&
               !completed.containsKey(index))
             index,
       ] {
    _controller = StreamController<PdfProgress>(
      onListen: () => unawaited(_run()),
      onCancel: _cancel,
    );
  }

  final PdfTranslator _owner;
  final List<Size> pageSizes;
  final List<String> codes;
  final TranslationEngine engine;
  final Language source;
  final Language target;
  final TranslationOptions options;
  final Map<int, PdfPageText> _pages;
  final Map<int, List<String>> _results;
  final Map<int, Map<int, List<String>>> _partial;
  final _failures = <int, Object>{};
  final List<int> _queue;
  late final StreamController<PdfProgress> _controller;
  StreamSubscription<DocumentProgress>? _chunks;
  bool _cancelled = false;

  Stream<PdfProgress> get stream => _controller.stream;

  Future<void> _cancel() async {
    _cancelled = true;
    await _chunks?.cancel();
  }

  void _report({int? page, PdfStage? stage, bool complete = false}) =>
      _controller.add(
        PdfProgress(
          total: pageSizes.length,
          pages: Map.unmodifiable(_pages),
          results: Map.unmodifiable(_results),
          partial: Map.unmodifiable(_partial),
          failures: Map.unmodifiable(_failures),
          page: page,
          stage: stage,
          isComplete: complete,
        ),
      );

  Future<void> _run() async {
    if (_queue.isNotEmpty) {
      _report();
      await _translatePages();
      if (_cancelled) return;
    }
    _report(complete: true);
    await _controller.close();
  }

  Future<void> _translatePages() async {
    var failedInARow = 0;
    for (final index in _queue) {
      if (_cancelled) return;
      final page = await _pageText(index);
      if (_cancelled) return;
      if (page == null) {
        // Missing recognition data: every page needs it, the user is
        // offered it first. Any other failure is this page's.
        if (_failures[index] is OcrDataMissingException) return;
        continue;
      }
      if (page.isEmpty) {
        _results[index] = const [];
        _report();
        continue;
      }
      _report(page: index, stage: PdfStage.translating);
      final plan = _owner._chunker.planSegments(
        page.segments,
        Chunker.encodingFor(DocumentFormat.pdf),
      );
      final progress = await _translatePage(plan, _partial[index] ?? const {});
      _chunks = null;
      if (_cancelled || progress == null) return;
      if (progress.failures.isEmpty) {
        _results[index] = [
          for (final text in plan.assemble(progress.results)) text ?? '',
        ];
        _partial.remove(index);
        failedInARow = 0;
        _report();
        continue;
      }
      _partial[index] = progress.results;
      _failures[index] = progress.failures.values.first;
      _report();
      final consent = progress.failures.values.any(
        (error) => error is ConsentRequiredException,
      );
      if (consent || ++failedInARow >= _owner.maxFailedPagesInARow) return;
    }
  }

  /// Page [index] as read with [codes] (read now when it was not); null
  /// when reading failed (the error is in [_failures]) or the run was
  /// cancelled.
  Future<PdfPageText?> _pageText(int index) async {
    final known = _pages[index];
    if (known != null && known.readWith(codes)) return known;
    _report(page: index, stage: PdfStage.reading);
    try {
      final page = await _owner.read(index, pageSizes[index], codes);
      if (_cancelled) return null;
      _pages[index] = page;
      // Read with other data: chunks of the earlier text do not fit it.
      _partial.remove(index);
      return page;
    } on OcrDataMissingException catch (error) {
      _failures[index] = error;
      return null;
    } on Object catch (error) {
      if (_cancelled) return null;
      _failures[index] = error;
      _report();
      return null;
    }
  }

  /// The last progress of translating [plan] (null when it was cancelled).
  Future<DocumentProgress?> _translatePage(
    ChunkPlan plan,
    Map<int, List<String>> done,
  ) {
    final finished = Completer<DocumentProgress?>();
    DocumentProgress? last;
    _chunks = _owner._translator
        .translate(
          plan,
          engine: engine,
          source: source,
          target: target,
          options: options,
          completed: done,
        )
        .listen(
          (progress) => last = progress,
          // The translator reports failures as progress, never as errors.
          onError: (Object _) {}, // coverage:ignore-line
          onDone: () => finished.complete(last),
        );
    return finished.future;
  }
}
