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
import 'package:mozhi/platform/device_conditions.dart';
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
    this.maskedPersonalData = 0,
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

  /// Items of personal data the personal data shield kept on the device in
  /// this run's requests ([DocumentProgress.maskedPersonalData] of its
  /// pages).
  final int maskedPersonalData;

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
    maskedPersonalData,
  ];
}

/// Translates PDFs on the device, page by page: reads a page
/// ([PdfPageReader]: its text layer on Android 15 and later when it has
/// one, else Tesseract with its layout), translates its paragraphs
/// with the document's engine through the [DocumentTranslator] (the same
/// options, chunking, retries, privacy routing and, for on-device AI, the
/// pause while the phone is hot as other documents), and writes the
/// translated PDF ([PdfPages.write]).
///
/// A PDF whose pages have a text layer needs no recognition data: [plan]
/// is then ready without any (no codes) and only a page without one asks
/// for the data ([OcrDataMissingException]). While the phone is hot
/// ([ThermalStatus.isHot] of [DeviceConditions]), text recognition waits
/// before each page ([PdfStage.cooling]), checking again every
/// [coolingCheck], then goes on; reading a text layer never waits.
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
    this._conditions,
    this.coolingCheck = const Duration(seconds: 30),
  }) : _reader = PdfPageReader(
         pages: _pages,
         recognizer: textRecognitionPixelsOf(_recognizer),
         minConfidence: minConfidence,
       );

  /// The app's: the platform's pages ([defaultPdfPages]), its Tesseract
  /// recognizer ([defaultTextRecognitionService], in every Android build),
  /// the phone's heat ([DeviceConditions.instance]) and [translator].
  factory platform({
    required DocumentTranslator translator,
    Chunker chunker = const Chunker(),
  }) => PdfTranslator(
    pages: defaultPdfPages(),
    recognizer: defaultTextRecognitionService(),
    translator: translator,
    scratch: defaultPdfScratch(),
    chunker: chunker,
    conditions: DeviceConditions.instance,
  );

  final PdfPages _pages;
  final TextRecognitionService _recognizer;
  final DocumentTranslator _translator;
  final PdfScratch _scratch;
  final Chunker _chunker;
  final PdfPageReader _reader;

  /// The phone's heat (null: recognition never waits).
  final DeviceConditions? _conditions;

  /// How often a recognition waiting for the phone to cool down checks
  /// again (it also goes on as soon as a change says it cooled down).
  final Duration coolingCheck;

  /// Pages probed for a text layer by [plan].
  static const textLayerProbePages = 3;

  /// Page count of the open PDF (null: none open).
  int? _pageCount;

  /// Whether one of the open PDF's first pages has a text layer (null: not
  /// probed yet).
  bool? _hasTextLayer;

  /// The recognition plan of the last [plan] (for a page without a text
  /// layer when the plan needs no data).
  TextRecognitionPlan? _recognitionPlan;

  /// A run stops after this many pages in a row whose translation failed
  /// (an engine that answers nothing would otherwise have every page read
  /// for nothing). The rest can be translated again.
  final int maxFailedPagesInARow;

  /// Whether PDFs are opened here (the platform reads them).
  bool get isSupported => _pages.isSupported;

  /// Whether pages can be read here: text recognition works, or the open
  /// PDF has a text layer (once [plan] found one).
  bool get canRead => _canRecognize || (_hasTextLayer ?? false);

  bool get _canRecognize => _reader.canRecognize && _recognizer.isSupported;

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
    _forget();
    try {
      final info = await _pages.open(path);
      if (info.pageCount > PdfLimits.maxPages) {
        await _pages.close();
        throw const PdfOpenException(kind: PdfOpenErrorKind.tooLarge);
      }
      _pageCount = info.pageCount;
      return info;
    } finally {
      await _scratch.delete(path);
    }
  }

  void _forget() {
    _reader.forget();
    _pageCount = null;
    _hasTextLayer = null;
    _recognitionPlan = null;
  }

  /// Which recognition data reads a PDF in [source] (see
  /// [planTextRecognition]; [preferred] for "Detect language"). When that
  /// data is missing or there is none, but one of the open PDF's first
  /// [textLayerProbePages] pages has a text layer, the PDF is read from
  /// its text layers: [TextRecognitionReady] without codes.
  Future<TextRecognitionPlan> plan(
    Language source, {
    List<String> preferred = const [],
  }) async {
    final data = languageData;
    final recognition = data == null || !_canRecognize
        ? const TextRecognitionUnsupported()
        : await planTextRecognition(data, source: source, preferred: preferred);
    _recognitionPlan = recognition;
    if (recognition is TextRecognitionReady) return recognition;
    if (await _probeTextLayer()) return const TextRecognitionReady([]);
    return recognition;
  }

  Future<bool> _probeTextLayer() async {
    final known = _hasTextLayer;
    if (known != null) return known;
    final count = _pageCount;
    if (count == null) return false;
    for (var page = 0; page < count && page < textLayerProbePages; page++) {
      if (await _reader.hasTextLayer(page)) return _hasTextLayer = true;
    }
    return _hasTextLayer = false;
  }

  /// Reads page [page] (of [size] points): from its text layer when it has
  /// one, else with text recognition in [codes] ([beforeRecognition] runs
  /// first). Without [codes] (a PDF read from its text layers, see [plan])
  /// a page without one throws the missing data of the last plan
  /// ([OcrDataMissingException]), or [ImageTranslateException]
  /// (`recognitionFailed`) when none reads it. Throws as
  /// [PdfPageReader.read].
  Future<PdfPageText> read(
    int page,
    Size size,
    List<String> codes, {
    Future<void> Function()? beforeRecognition,
  }) async {
    final layer = await _reader.readTextLayer(page, size, codes: codes);
    if (layer != null) return layer;
    if (codes.isEmpty || !_canRecognize) {
      throw switch (_recognitionPlan) {
        TextRecognitionNeedsData(:final missing) when _canRecognize => missing,
        _ => const ImageTranslateException(
          ImageTranslateErrorKind.recognitionFailed,
        ),
      };
    }
    await beforeRecognition?.call();
    return await _reader.recognize(page, size, codes);
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
  Future<void> close() {
    _forget();
    return _pages.close();
  }
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

  /// Completed to stop waiting for the phone to cool down.
  Completer<void>? _wake;
  int _masked = 0;

  Stream<PdfProgress> get stream => _controller.stream;

  Future<void> _cancel() async {
    _cancelled = true;
    _wakeUp();
    await _chunks?.cancel();
  }

  void _wakeUp() {
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  /// While the phone is hot: reports page [index] as
  /// [PdfStage.cooling] and waits until a change says it cooled down (or
  /// for [PdfTranslator.coolingCheck], then looks again), then reports it
  /// as being read again. Returns at once otherwise; throws when the run
  /// was cancelled meanwhile.
  Future<void> _coolDown(int index) async {
    final conditions = _owner._conditions;
    if (conditions == null || !conditions.latest.thermal.isHot) return;
    _report(page: index, stage: PdfStage.cooling);
    while (!_cancelled && conditions.latest.thermal.isHot) {
      final wake = _wake = Completer<void>();
      final changes = conditions.changes.listen((snapshot) {
        if (!snapshot.thermal.isHot) _wakeUp();
      });
      final timer = Timer(_owner.coolingCheck, _wakeUp);
      try {
        await wake.future;
      } finally {
        timer.cancel();
        await changes.cancel();
        _wake = null;
      }
    }
    // Cancelled: the page is not recognised ([_pageText] ignores this).
    if (_cancelled) throw const _Cancelled();
    _report(page: index, stage: PdfStage.reading);
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
          maskedPersonalData: _masked,
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
      _masked += progress.maskedPersonalData;
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
      final page = await _owner.read(
        index,
        pageSizes[index],
        codes,
        beforeRecognition: () => _coolDown(index),
      );
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

/// A run was cancelled while its page waited.
class _Cancelled implements Exception {
  const new();
}
