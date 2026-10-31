import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:bloc/bloc.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/core/office/office.dart';
import 'package:mozhi/documents/cubit/document_translate_state.dart';
import 'package:mozhi/documents/data/document_file_service.dart';
import 'package:mozhi/documents/data/document_worker.dart';
import 'package:mozhi/documents/pdf/pdf.dart';
import 'package:mozhi/image_translate/data/text_recognition_plan.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart'
    show TextRecognitionLanguageData;
import 'package:mozhi/image_translate/models/models.dart'
    show OcrDataMissingException;
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

export '../data/document_worker.dart' show TextDocumentParser;
export 'document_translate_state.dart';

/// Drives the document translation screen.
///
/// * Engine, languages and options start from the main translate screen
///   (see [syncEngines]) and follow it until the user changes them here.
/// * A document comes from a picked file ([pickFile] / [loadFile]) or
///   pasted text ([setText]); it is parsed into segments and planned into
///   chunks right away (format, size, counts and an estimate are shown).
/// * Office documents and e-books ([DocumentFormat.isBinary]) are read as
///   bytes ([parsePackagedDocument]); large ones are parsed and written off
///   the UI isolate. They are never pasted, and they are saved in their own
///   format with their formatting.
/// * Formats that record the target language
///   ([DocumentFormat.usesTargetLanguage], office documents) are parsed for
///   the current target, and again when it changes.
/// * PDFs (Android) are opened by the [PdfTranslator] (the first page is
///   read for the preview) and read, translated and saved page by page:
///   for them [DocumentTranslateState.results] and `failures` are by page,
///   and [saveText] saves the translated text.
/// * [translate] runs the [DocumentTranslator]; progress, partial output
///   and failed chunks update live. [cancel] stops the run (keeping what
///   is done); [retryFailed]/[retryChunk] translate what is missing.
/// * Parts the privacy settings stopped are translated once the user
///   allowed them ([consentGranted]); what a one-time approval for them
///   did not use is withdrawn (`TranslationRepository.revokeOnce`) when
///   that run ends (done, failed, cancelled or replaced) and when the
///   screen closes, so it can't let anything else through.
/// * Changing the document, engine or languages discards translations.
class DocumentTranslateCubit extends Cubit<DocumentTranslateState> {
  new({
    required TranslationRepository repository,
    required this._files,
    DocumentTranslator? translator,
    this._chunker = const Chunker(),
    this.maxBytes = DocumentTranslateCubitDefaults.maxBytes,
    this.maxPackageBytes = DocumentTranslateCubitDefaults.maxPackageBytes,
    this.backgroundBytes = DocumentTranslateCubitDefaults.backgroundBytes,
    this._parser = parseDocument,
    List<TranslationEngine> engines = const [],
    TranslationEngine? engine,
    List<Language> sourceLanguages = const [],
    List<Language> targetLanguages = const [],
    Language source = Language.auto,
    Language target = _english,
    TranslationOptions options = const TranslationOptions(),
    UsageTracker? usageTracker,
    this._pdfTranslator,
    this._ocrPreferred = const [],
  }) : _repository = repository,
       _translator =
           translator ??
           DocumentTranslator(
             repository: repository,
             onTranslated: _usageRecorder(usageTracker),
           ),
       super(
         DocumentTranslateState(
           engines: engines,
           engine: engine,
           sourceLanguages: sourceLanguages,
           targetLanguages: targetLanguages,
           source: source,
           target: target,
           options: options,
         ),
       );

  static const _english = Language(code: 'en', name: 'English');

  /// Counts each answered chunk request of a bring-your-own-key provider.
  static TranslatedCallback? _usageRecorder(UsageTracker? tracker) {
    if (tracker == null) return null;
    return (engine, request, result) {
      final providerId = engine.providerId;
      if (providerId == null || providerId.isEmpty) return;
      unawaited(
        tracker
            .recordText(providerId, input: request.text, output: result.text)
            .then((_) {}, onError: (Object _) {}),
      );
    };
  }

  final TranslationRepository _repository;
  final DocumentFileService _files;
  final Chunker _chunker;
  final DocumentTranslator _translator;

  final TextDocumentParser _parser;

  /// Translates PDFs (created on first use: [PdfTranslator.platform]).
  PdfTranslator? _pdfTranslator;
  PdfTranslator get _pdf => _pdfTranslator ??= PdfTranslator.platform(
    translator: _translator,
    chunker: _chunker,
  );

  /// App codes of the languages a PDF in "Detect language" is most likely
  /// in (recent source languages, the app's language): read with their
  /// recognition data first.
  final List<String> _ocrPreferred;

  /// Whether a PDF may be open on the platform side (closed with the
  /// document).
  bool _pdfOpen = false;
  StreamSubscription<PdfProgress>? _pdfSubscription;

  /// The translated PDF last written, for the results it was written from.
  ({Map<int, List<String>> results, Uint8List bytes})? _pdfOutput;
  Future<Uint8List>? _pdfWriting;

  /// The source language changed while the first page was being read.
  bool _previewAgain = false;

  /// Largest accepted text file in bytes.
  // Immutable configuration passed to the constructor, not state.
  // ignore: avoid_public_fields
  final int maxBytes;

  /// Largest accepted office document or e-book in bytes.
  // Immutable configuration passed to the constructor, not state.
  // ignore: avoid_public_fields
  final int maxPackageBytes;

  /// Office documents and e-books from this size on (and text documents
  /// from this many characters on) are parsed and rendered in a background
  /// isolate.
  // Immutable configuration passed to the constructor, not state.
  // ignore: avoid_public_fields
  final int backgroundBytes;

  /// Incremented with every file that is loaded, so that a background
  /// parse of an older one is ignored.
  int _loadRequest = 0;

  /// Incremented with every text that is parsed (a file, pasted text, a new
  /// format or target), so that a background parse of an older one is
  /// ignored.
  int _textRequest = 0;

  /// The target language the current text document was parsed for.
  String? _parsedTarget;

  /// Whether engine/languages still mirror the translate screen.
  bool _followTranslate = true;
  int _languagesRequest = 0;

  StreamSubscription<DocumentProgress>? _subscription;
  Completer<void>? _runDone;
  int _run = 0;

  /// The consents the user gave for the run that is starting or running
  /// ([consentGranted]), withdrawn when it ends.
  final _grants = <ConsentRequiredException>[];

  /// The last picked file, kept while the user looks at pasted text.
  _FileInput? _file;
  String _pastedText = '';
  DocumentFormat? _pastedFormat;

  bool get _busy => state.isTranslating || state.status == .loading;

  // ---------------------------------------------------------------------
  // Engine & languages
  // ---------------------------------------------------------------------

  /// Mirrors the translate screen's engines (and, until the user picks
  /// their own here, its engine, languages and options).
  void syncEngines({
    required List<TranslationEngine> engines,
    TranslationEngine? engine,
    List<Language> sourceLanguages = const [],
    List<Language> targetLanguages = const [],
    Language? source,
    Language? target,
    TranslationOptions? options,
  }) {
    final current = state.engine;
    final currentAvailable =
        current != null && engines.any((e) => e.id == current.id);
    // Keep the user's choice, and never discard a finished translation.
    if (state.isTranslating ||
        (currentAvailable && (!_followTranslate || state.hasTranslation))) {
      emit(state.copyWith(engines: engines));
      return;
    }
    if (!currentAvailable) _followTranslate = true;
    final changed =
        engine?.id != current?.id ||
        source != null && source != state.source ||
        target != null && target != state.target;
    emit(
      _retargeted(
        (changed ? _withoutTranslation(state) : state).copyWith(
          engines: engines,
          engine: () => engine,
          sourceLanguages: sourceLanguages,
          targetLanguages: targetLanguages,
          source: source,
          target: target,
          options: options,
          languagesLoading: false,
        ),
      ),
    );
  }

  /// Uses [engine] for this document (loading its languages).
  Future<void> selectEngine(TranslationEngine engine) async {
    if (state.isTranslating || engine.id == state.engine?.id) return;
    _followTranslate = false;
    final request = ++_languagesRequest;
    emit(
      _withoutTranslation(state)
          .copyWith(engine: () => engine, languagesLoading: true),
    );
    try {
      final lists = await Future.wait([
        _repository.getSourceLanguages(engine),
        _repository.getTargetLanguages(engine),
      ]);
      if (isClosed || request != _languagesRequest) return;
      emit(_withLanguages(engine, lists[0], lists[1]));
    } on Object {
      if (isClosed || request != _languagesRequest) return;
      _notify(
        DocumentNotice.languagesFailed,
        state.copyWith(languagesLoading: false),
      );
    }
  }

  DocumentTranslateState _withLanguages(
    TranslationEngine engine,
    List<Language> sources,
    List<Language> targets,
  ) {
    final sourceMatch = state.source.isCustom
        ? null
        : LanguageMatcher.match(state.source, sources);
    final source =
        sourceMatch ??
        (sources.isEmpty || sources.contains(Language.auto)
            ? Language.auto
            : sources.first);
    final allowCustom = engine.supportsCustomLanguages;
    final targetMatch = state.target.isCustom && !allowCustom
        ? null
        : LanguageMatcher.match(
            state.target,
            targets,
            allowCustom: allowCustom,
          );
    final target =
        targetMatch ??
        LanguageMatcher.match(_english, targets) ??
        (targets.isEmpty ? _english : targets.first);
    return _retargeted(
      state.copyWith(
        sourceLanguages: sources,
        targetLanguages: targets,
        source: source,
        target: target,
        languagesLoading: false,
      ),
    );
  }

  void setSource(Language language) {
    if (state.isTranslating || language == state.source) return;
    _followTranslate = false;
    emit(_withoutTranslation(state).copyWith(source: language));
  }

  void setTarget(Language language) {
    if (state.isTranslating ||
        language.isAuto ||
        (language == state.target && language.name == state.target.name)) {
      return;
    }
    _followTranslate = false;
    emit(_retargeted(_withoutTranslation(state).copyWith(target: language)));
  }

  /// Swaps source and target (not with "Detect language" or a custom
  /// target).
  void swapLanguages() {
    if (state.isTranslating || !state.canSwap) return;
    _followTranslate = false;
    final source =
        LanguageMatcher.match(state.target, state.sourceLanguages) ??
        state.target;
    final target =
        LanguageMatcher.match(state.source, state.targetLanguages) ??
        state.source;
    emit(
      _retargeted(
        _withoutTranslation(state).copyWith(source: source, target: target),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Input
  // ---------------------------------------------------------------------

  /// Switches between a picked file and pasted text (each keeps its own
  /// input).
  void setMode(DocumentInputMode mode) {
    if (_busy || mode == state.mode) return;
    _textRequest++;
    final base = state.copyWith(mode: mode);
    switch (mode) {
      case DocumentInputMode.file:
        final file = _file;
        if (file == null) {
          emit(_cleared(base));
        } else if (file.package case final package?) {
          emit(_retargeted(_packageState(base, file, package)));
        } else if (file.pdf case final pdf?) {
          emit(_pdfState(base, file, pdf));
          unawaited(_previewPdf());
        } else {
          _load(
            base,
            text: file.text,
            format: file.format,
            fileName: file.name,
            encoding: file.encoding,
            sizeBytes: file.sizeBytes,
          );
        }
      case DocumentInputMode.text:
        _loadPasted(base);
    }
  }

  /// Opens the file picker and loads the chosen file.
  Future<void> pickFile() async {
    if (_busy) return;
    final previous = state;
    emit(state.copyWith(status: DocumentStatus.loading));
    PickedFile? file;
    try {
      file = await _files.pickFile(extensions: DocumentFormat.allExtensions);
    } on Object {
      if (isClosed) return;
      emit(
        _cleared(previous)
            .copyWith(mode: .file, error: () => DocumentError.readFailed),
      );
      return;
    }
    if (isClosed) return;
    if (file == null) {
      emit(previous);
      return;
    }
    loadFile(file.name, file.bytes);
  }

  /// Loads a file's content (from the picker, a share intent or a drop).
  void loadFile(String name, Uint8List bytes) {
    if (state.isTranslating) return;
    _loadRequest++;
    _textRequest++;
    _closePdf();
    final base = _cleared(state).copyWith(
      mode: DocumentInputMode.file,
      fileName: () => name,
      sizeBytes: bytes.length,
    );
    // A PDF is read as one whatever its name says.
    final format = DocumentFormat.isPdfBytes(bytes)
        ? DocumentFormat.pdf
        : DocumentFormat.fromFileName(name);
    if (format == null) {
      emit(base.copyWith(error: () => DocumentError.unsupportedFormat));
      return;
    }
    if (format == DocumentFormat.pdf) {
      unawaited(_loadPdf(base, name, bytes));
      return;
    }
    if (format.isBinary) {
      _loadPackage(base, name, bytes, format);
      return;
    }
    if (bytes.length > maxBytes) {
      emit(
        base.copyWith(
          format: () => format,
          error: () => DocumentError.tooLarge,
        ),
      );
      return;
    }
    final DecodedText decoded;
    try {
      decoded = decodeText(bytes);
    } on BinaryContentException {
      emit(
        base.copyWith(format: () => format, error: () => DocumentError.notText),
      );
      return;
    }
    _file = _FileInput(
      name: name,
      text: decoded.text,
      format: format,
      encoding: decoded.encoding,
      sizeBytes: bytes.length,
    );
    _load(
      base,
      text: decoded.text,
      format: format,
      fileName: name,
      encoding: decoded.encoding,
      sizeBytes: bytes.length,
    );
  }

  /// Reads an office document or e-book: right away when it is small, in a
  /// background isolate otherwise.
  void _loadPackage(
    DocumentTranslateState base,
    String name,
    Uint8List bytes,
    DocumentFormat format,
  ) {
    final start = base.copyWith(format: () => format);
    if (bytes.length > maxPackageBytes) {
      emit(start.copyWith(error: () => DocumentError.tooLarge));
      return;
    }
    final target = _targetLanguage(base.target);
    if (bytes.length < backgroundBytes) {
      emit(
        _parsedPackage(
          start,
          name,
          bytes,
          format,
          () => parsePackagedDocument(bytes, format, targetLanguage: target),
        ),
      );
      return;
    }
    final request = _loadRequest;
    emit(start.copyWith(status: DocumentStatus.loading));
    unawaited(
      _parseInBackground(bytes, format, target).then((result) {
        if (isClosed || request != _loadRequest) return;
        final next = _parsedPackage(start, name, bytes, format, result);
        // Pasted text was opened meanwhile: the file waits in file mode.
        if (state.mode == DocumentInputMode.file) emit(next);
      }),
    );
  }

  /// Parses in an isolate; the result (or the error) is replayed by the
  /// returned function.
  static Future<PackagedDocument Function()> _parseInBackground(
    Uint8List bytes,
    DocumentFormat format,
    String? target,
  ) async {
    try {
      final document = await parsePackageInBackground(
        bytes,
        format,
        targetLanguage: target,
      );
      return () => document;
    } on Object catch (error, stackTrace) {
      return () => Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// The state for the file [name] once [parse] ran (the document, or why
  /// it cannot be read); remembers the file for the file mode.
  DocumentTranslateState _parsedPackage(
    DocumentTranslateState base,
    String name,
    Uint8List bytes,
    DocumentFormat format,
    PackagedDocument Function() parse,
  ) {
    final PackagedDocument package;
    try {
      package = parse();
    } on Object catch (error) {
      _file = null;
      return base.copyWith(
        status: DocumentStatus.empty,
        error: () => switch (error) {
          PackageParseException(problem: PackageProblem.encrypted) =>
            DocumentError.encrypted,
          PackageParseException(problem: PackageProblem.unsafe) ||
          TooManyPlaceholdersException() => DocumentError.unsafeFile,
          // Damaged, or any other failure on a damaged file.
          _ => DocumentError.damagedFile,
        },
      );
    }
    final file = _FileInput(
      name: name,
      text: '',
      format: format,
      encoding: TextEncoding.utf8,
      sizeBytes: bytes.length,
      package: package,
    );
    _file = file;
    return _packageState(base, file, package);
  }

  /// [base] showing [package] (the file [file]).
  DocumentTranslateState _packageState(
    DocumentTranslateState base,
    _FileInput file,
    PackagedDocument package,
  ) => _withoutTranslation(base).copyWith(
    status: DocumentStatus.ready,
    fileName: () => file.name,
    text: segmentsPreview(package.segments),
    encoding: TextEncoding.utf8,
    sizeBytes: file.sizeBytes,
    format: () => package.format,
    document: () => null,
    packagedDocument: () => package,
    plan: () => _chunker.planSegments(
      package.segments,
      Chunker.encodingFor(package.format),
    ),
    error: () => package.isEmpty ? DocumentError.nothingToTranslate : null,
  );

  /// [next] with its document parsed for [DocumentTranslateState.target],
  /// when its format records the target language.
  DocumentTranslateState _retargeted(DocumentTranslateState next) {
    final target = _targetLanguage(next.target);
    final package = next.packagedDocument;
    if (package is OfficePackage) {
      if (package.language?.bcp47 == LanguageTag.tryParse(target)?.bcp47) {
        return next;
      }
      final updated = package.withTargetLanguage(target);
      final file = _file;
      if (file != null && identical(file.package, package)) {
        _file = file.withPackage(updated);
      }
      return next.copyWith(packagedDocument: () => updated);
    }
    final document = next.document;
    final format = next.format;
    if (document == null ||
        format == null ||
        !format.usesTargetLanguage ||
        target == _parsedTarget) {
      return next;
    }
    // A document that can't take the target keeps its last parse.
    return _parsed(next, next.text, format, target, keepOnFailure: true);
  }

  /// [next] with [text] parsed as [format] for [target]: right away for
  /// short text; otherwise [next] is returned as loading and the parse
  /// runs in a background isolate, emitting its result when it is still
  /// current.
  DocumentTranslateState _parsed(
    DocumentTranslateState next,
    String text,
    DocumentFormat format,
    String? target, {
    bool keepOnFailure = false,
  }) {
    final request = ++_textRequest;
    if (text.length < backgroundBytes) {
      return _withText(
        next,
        () => _parser(text, format, targetLanguage: target),
        format,
        target,
        keepOnFailure: keepOnFailure,
      );
    }
    unawaited(
      _parseTextInBackground(text, format, target).then((parse) {
        if (isClosed || request != _textRequest) return;
        final parsed = _withText(
          state,
          parse,
          format,
          target,
          keepOnFailure: keepOnFailure,
        );
        // The target changed while the text was parsed.
        final current = _targetLanguage(parsed.target) == target;
        emit(current ? parsed : _retargeted(parsed));
      }),
    );
    return next.copyWith(
      status: DocumentStatus.loading,
      // A re-parse for a new target keeps showing the document meanwhile.
      document: keepOnFailure ? null : () => null,
      plan: keepOnFailure ? null : () => null,
      error: () => null,
    );
  }

  Future<ParsedDocument Function()> _parseTextInBackground(
    String text,
    DocumentFormat format,
    String? target,
  ) async {
    try {
      final document = await parseTextInBackground(
        _parser,
        text,
        format,
        targetLanguage: target,
      );
      return () => document;
    } on Object catch (error, stackTrace) {
      return () => Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// [base] with the document [parse] gives (or why it can't be read).
  DocumentTranslateState _withText(
    DocumentTranslateState base,
    ParsedDocument Function() parse,
    DocumentFormat format,
    String? target, {
    required bool keepOnFailure,
  }) {
    final ParsedDocument document;
    try {
      document = parse();
      // A parser's failure on unexpected input is reported the same way.
    } on Object catch (error) {
      if (keepOnFailure) {
        return base.copyWith(
          status: base.hasDocument ? DocumentStatus.ready : base.status,
        );
      }
      return base.copyWith(
        status: DocumentStatus.empty,
        document: () => null,
        plan: () => null,
        error: () => switch (error) {
          // Too many protected spans in a paragraph to translate it safely.
          TooManyPlaceholdersException() => DocumentError.unsafeFile,
          _ when format == DocumentFormat.json => DocumentError.invalidJson,
          _ => DocumentError.invalidFormat,
        },
      );
    }
    _parsedTarget = target;
    return base.copyWith(
      status: DocumentStatus.ready,
      document: () => document,
      plan: () => _chunker.plan(document),
      error: () => document.isEmpty ? DocumentError.nothingToTranslate : null,
      translations: base.translations,
    );
  }

  /// The BCP 47 code written into documents for [target] (none for custom
  /// AI "languages").
  static String? _targetLanguage(Language target) =>
      target.isCustom || target.isAuto ? null : target.code;

  /// Uses pasted/typed [text] as the document (format detected unless
  /// chosen with [setFormat]).
  void setText(String text) {
    if (state.isTranslating) return;
    _textRequest++;
    _pastedText = text;
    _loadPasted(state.copyWith(mode: DocumentInputMode.text));
  }

  /// Pastes the clipboard text as the document.
  Future<void> pasteText() async {
    if (state.isTranslating) return;
    String? text;
    try {
      text = await _files.pasteText();
    } on Object {
      text = null;
    }
    if (isClosed) return;
    if (text == null || text.trim().isEmpty) {
      _notify(DocumentNotice.clipboardEmpty);
      return;
    }
    setText(text);
  }

  /// Reads the current input as [format] (e.g. a `.txt` file that is
  /// really Markdown, or pasted text that was detected wrongly).
  void setFormat(DocumentFormat format) {
    // Office documents and e-books are what their file is.
    if (_busy || format == state.format || format.isBinary) return;
    if (state.mode == DocumentInputMode.text) {
      _pastedFormat = format;
      _loadPasted(state);
      return;
    }
    final file = _file;
    if (file == null || file.package != null) return;
    _file = file.withFormat(format);
    _load(
      state,
      text: file.text,
      format: format,
      fileName: file.name,
      encoding: file.encoding,
      sizeBytes: file.sizeBytes,
    );
  }

  /// Removes the current input.
  void clear() {
    _stop();
    // A file still being read is forgotten too.
    _loadRequest++;
    _textRequest++;
    if (state.mode == DocumentInputMode.file) {
      if (_file?.pdf != null || state.isPdf) _closePdf();
      _file = null;
    } else {
      _pastedText = '';
      _pastedFormat = null;
    }
    emit(_cleared(state));
  }

  void _loadPasted(DocumentTranslateState base) {
    final text = _pastedText;
    if (text.trim().isEmpty) {
      _pastedFormat = null;
      emit(_cleared(base).copyWith(text: text));
      return;
    }
    _load(
      base,
      text: text,
      format: _pastedFormat ?? DocumentFormat.sniff(text),
      fileName: null,
      encoding: TextEncoding.utf8,
      sizeBytes: utf8.encode(text).length,
    );
  }

  void _load(
    DocumentTranslateState base, {
    required String text,
    required DocumentFormat format,
    required String? fileName,
    required TextEncoding encoding,
    required int sizeBytes,
  }) {
    final next = _withoutTranslation(base).copyWith(
      fileName: () => fileName,
      text: text,
      encoding: encoding,
      sizeBytes: sizeBytes,
      format: () => format,
      packagedDocument: () => null,
      pdf: () => null,
    );
    emit(_parsed(next, text, format, _targetLanguage(base.target)));
  }

  // ---------------------------------------------------------------------
  // Translation
  // ---------------------------------------------------------------------

  /// Translates the whole document (discarding earlier results).
  Future<void> translate() => _start(fresh: true);

  /// Translates every chunk that is still missing (failed or cancelled).
  Future<void> retryFailed() => _start(fresh: false);

  /// Translates chunk [index] again.
  Future<void> retryChunk(int index) => _start(fresh: false, only: [index]);

  /// The user allowed what the privacy settings stopped (the consent
  /// prompt recorded a one-time approval of what is missing, or the pair or
  /// provider for good): translates what is missing ([retryFailed]). What
  /// a one-time approval did not use is withdrawn when that run ends; a
  /// run that is still going takes it, and withdraws it when it ends.
  Future<void> consentGranted() async {
    _grants.addAll(state.failures.values.whereType<ConsentRequiredException>());
    if (state.isTranslating) return;
    await retryFailed();
    // Nothing started (or it is over): nothing is left to use them.
    if (!state.isTranslating) _revokeGrants();
  }

  /// Withdraws what the consents the user gave let through once and was
  /// not used.
  void _revokeGrants() {
    if (_grants.isEmpty) return;
    final grants = List.of(_grants);
    _grants.clear();
    for (final consent in grants) {
      try {
        _repository.revokeOnce(consent);
      } on Object {
        // Withdrawing must never break the translation.
      }
    }
  }

  Future<void> _start({required bool fresh, List<int>? only}) {
    if (state.isPdf) return _startPdf(fresh: fresh, only: only);
    final plan = state.plan;
    final engine = state.engine;
    if (!state.canTranslate || plan == null || engine == null) {
      return Future.value();
    }
    final completed = fresh ? const <int, List<String>>{} : state.results;
    final kept = fresh
        ? const <int, Object>{}
        : {
            for (final entry in state.failures.entries)
              if (only != null && !only.contains(entry.key))
                entry.key: entry.value,
          };
    var next = state.copyWith(
      status: DocumentStatus.translating,
      results: completed,
      failures: kept,
    );
    if (fresh) next = _rendered(next.copyWith(translations: const []));
    emit(next);
    // What earlier runs of this translation kept on the device.
    final maskedBefore = fresh ? 0 : state.maskedPersonalData;

    final run = ++_run;
    final done = _runDone = Completer<void>();
    _subscription = _translator
        .translate(
          plan,
          engine: engine,
          source: state.source,
          target: state.target,
          options: state.options,
          completed: completed,
          only: only,
        )
        .listen(
          (progress) {
            if (run != _run) return;
            final translations = plan.assemble(progress.results);
            emit(
              _rendered(
                state.copyWith(
                  results: progress.results,
                  failures: {...kept, ...progress.failures},
                  translations: translations,
                  maskedPersonalData:
                      maskedBefore + progress.maskedPersonalData,
                ),
              ),
            );
          },
          // The translator reports failures as progress, never as errors.
          onError: (Object _) {}, // coverage:ignore-line
          onDone: () {
            if (run == _run) {
              _subscription = null;
              _revokeGrants();
              emit(state.copyWith(status: DocumentStatus.translated));
            }
            if (!done.isCompleted) done.complete();
          },
        );
    return done.future;
  }

  /// Stops the running translation, keeping finished chunks.
  void cancel() {
    if (!state.isTranslating) return;
    _stop();
    emit(
      state.copyWith(
        status: state.hasTranslation
            ? DocumentStatus.translated
            : DocumentStatus.ready,
      ),
    );
  }

  void _stop() {
    _run++;
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(_pdfSubscription?.cancel());
    _pdfSubscription = null;
    _revokeGrants();
    final done = _runDone;
    if (done != null && !done.isCompleted) done.complete();
  }

  /// Subtitles: also write the original lines in exports.
  void setBilingual({required bool enabled}) {
    if (enabled == state.bilingual) return;
    emit(_rendered(state.copyWith(bilingual: enabled)));
  }

  // ---------------------------------------------------------------------
  // PDF (lib/documents/pdf/)
  // ---------------------------------------------------------------------

  /// The text recognition data PDFs are read with, for the offer to get the
  /// data of a language ([PdfSource.missingData]); null when there is none
  /// to download.
  // Read-only query; it changes nothing.
  // ignore: prefer_void_public_cubit_methods
  TextRecognitionLanguageData? get pdfLanguageData => _pdf.languageData;

  /// Opens the PDF [bytes] and reads its first page for the preview.
  Future<void> _loadPdf(
    DocumentTranslateState base,
    String name,
    Uint8List bytes,
  ) async {
    final request = _loadRequest;
    final start = base.copyWith(format: () => DocumentFormat.pdf);
    final pdf = _pdf;
    if (!pdf.isSupported) {
      _file = null;
      emit(start.copyWith(error: () => DocumentError.pdfNeedsApp));
      return;
    }
    if (bytes.length > PdfLimits.maxBytes) {
      _file = null;
      emit(start.copyWith(error: () => DocumentError.tooLarge));
      return;
    }
    emit(start.copyWith(status: DocumentStatus.loading));
    final PdfInfo info;
    try {
      _pdfOpen = true;
      info = await pdf.open(bytes);
    } on Object catch (error) {
      if (isClosed || request != _loadRequest) return;
      _file = null;
      emit(
        start.copyWith(
          status: DocumentStatus.empty,
          error: () => switch (error) {
            PdfOpenException(kind: PdfOpenErrorKind.encrypted) =>
              DocumentError.encrypted,
            PdfOpenException(kind: PdfOpenErrorKind.tooLarge) =>
              DocumentError.tooLarge,
            PdfOpenException(kind: PdfOpenErrorKind.unsupported) =>
              DocumentError.pdfNeedsApp,
            PdfOpenException() => DocumentError.damagedFile,
            // The copy for the platform could not be written.
            _ => DocumentError.readFailed,
          },
        ),
      );
      return;
    }
    // Closed or replaced meanwhile: whoever did it closes the PDF.
    if (isClosed || request != _loadRequest) return;
    final source = PdfSource(pageSizes: info.pageSizes);
    final file = _FileInput(
      name: name,
      text: '',
      format: DocumentFormat.pdf,
      encoding: TextEncoding.utf8,
      sizeBytes: bytes.length,
      pdf: source,
    );
    _file = file;
    _pdfOutput = null;
    // Pasted text was opened meanwhile: the file waits in file mode.
    if (state.mode != DocumentInputMode.file) return;
    emit(_pdfState(start, file, source));
    await _previewPdf();
  }

  /// [base] showing the PDF [source] (the file [file]).
  DocumentTranslateState _pdfState(
    DocumentTranslateState base,
    _FileInput file,
    PdfSource source,
  ) => _withoutTranslation(base).copyWith(
    status: DocumentStatus.ready,
    fileName: () => file.name,
    text: pdfText(source, const {}, translated: false),
    encoding: TextEncoding.utf8,
    sizeBytes: file.sizeBytes,
    format: () => DocumentFormat.pdf,
    document: () => null,
    packagedDocument: () => null,
    // A preview that was being read when the file was left is read again.
    pdf: () => source.withoutTranslation().copyWith(previewing: false),
    plan: () => null,
    error: () => null,
  );

  /// Emits [source] as the PDF of [base] (default: the state), with its
  /// original text, and remembers it for the file mode.
  void _emitPdf(PdfSource source, [DocumentTranslateState? base]) {
    if (isClosed) return;
    final file = _file;
    if (file != null && file.pdf != null) _file = file.withPdf(source);
    emit(
      (base ?? state).copyWith(
        pdf: () => source,
        text: pdfText(source, const {}, translated: false),
      ),
    );
  }

  /// Whether the PDF of load [request] is still the one shown.
  bool _pdfCurrent(int request) =>
      !isClosed && request == _loadRequest && state.pdf != null;

  /// Reads the first page for the preview with the source language's
  /// recognition data (again when that changed); missing data is offered
  /// ([PdfSource.missingData]), never downloaded.
  Future<void> _previewPdf() async {
    final source = state.pdf;
    if (source == null || state.isTranslating) return;
    if (source.previewing) {
      _previewAgain = true;
      return;
    }
    final request = _loadRequest;
    final pdf = _pdf;
    if (!pdf.canRead) {
      _emitPdf(
        source.copyWith(issue: () => PdfReadIssue.recognitionUnavailable),
      );
      return;
    }
    _previewAgain = false;
    _emitPdf(
      source.copyWith(
        previewing: true,
        missingData: () => null,
        issue: () => null,
      ),
    );
    PdfReadIssue? issue;
    OcrDataMissingException? missing;
    PdfPageText? page;
    try {
      switch (await pdf.plan(state.source, preferred: _ocrPreferred)) {
        case TextRecognitionNeedsData(missing: final data):
          missing = data;
        case TextRecognitionUnsupported():
          issue = PdfReadIssue.languageUnsupported;
        case TextRecognitionReady(:final codes):
          final known = state.pdf?.firstPage;
          page = known != null && known.readWith(codes)
              ? known
              : await pdf.read(0, source.pageSizes.first, codes);
      }
    } on OcrDataMissingException catch (error) {
      missing = error;
    } on Object {
      issue = PdfReadIssue.readFailed;
    }
    if (!_pdfCurrent(request)) return;
    final current = state.pdf!;
    _emitPdf(
      current.copyWith(
        previewing: false,
        missingData: () => missing,
        issue: () => issue,
        pages: page == null ? null : {...current.pages, 0: page},
      ),
    );
    if (_previewAgain) await _previewPdf();
  }

  /// Text recognition data was installed for the PDF (the offer of
  /// [PdfSource.missingData]): reads the preview again, and translates the
  /// pages that stopped for want of it.
  Future<void> pdfDataInstalled() async {
    if (!state.isPdf) return;
    final waiting = state.failures.values.any(
      (error) => error is OcrDataMissingException,
    );
    await _previewPdf();
    if (waiting && !isClosed && state.canTranslate) await retryFailed();
  }

  /// Translates the PDF page by page ([PdfTranslator.translate]).
  Future<void> _startPdf({required bool fresh, List<int>? only}) async {
    final source = state.pdf;
    final engine = state.engine;
    if (!state.canTranslate || source == null || engine == null) return;
    final completed = fresh ? const <int, List<String>>{} : state.results;
    final kept = fresh
        ? const <int, Object>{}
        : {
            for (final entry in state.failures.entries)
              if (only != null && !only.contains(entry.key))
                entry.key: entry.value,
          };
    final partial = fresh
        ? const <int, Map<int, List<String>>>{}
        : source.partial;
    // What earlier runs of this translation kept on the device.
    final maskedBefore = fresh ? 0 : state.maskedPersonalData;
    final run = ++_run;
    final done = _runDone = Completer<void>();
    final started = source.copyWith(
      partial: partial,
      missingData: () => null,
      issue: () => null,
    );
    emit(
      _rendered(
        state.copyWith(
          status: DocumentStatus.translating,
          results: completed,
          failures: kept,
          pdf: () => started,
          error: () => null,
        ),
      ),
    );
    TextRecognitionPlan plan;
    try {
      plan = await _pdf.plan(state.source, preferred: _ocrPreferred);
    } on Object {
      plan = const TextRecognitionUnsupported();
    }
    // Cancelled meanwhile: cancel() settled the state and the run.
    if (isClosed || run != _run) return;
    final codes = switch (plan) {
      TextRecognitionReady(:final codes) => codes,
      _ => null,
    };
    if (codes == null) {
      _runDone = null;
      _revokeGrants();
      emit(
        state.copyWith(
          status: state.hasTranslation
              ? DocumentStatus.translated
              : DocumentStatus.ready,
          pdf: () => started.copyWith(
            missingData: () => switch (plan) {
              TextRecognitionNeedsData(:final missing) => missing,
              _ => null,
            },
            issue: () => plan is TextRecognitionUnsupported
                ? (_pdf.canRead
                      ? PdfReadIssue.languageUnsupported
                      : PdfReadIssue.recognitionUnavailable)
                : null,
          ),
        ),
      );
      done.complete();
      return;
    }
    _pdfSubscription = _pdf
        .translate(
          pageSizes: source.pageSizes,
          codes: codes,
          engine: engine,
          source: state.source,
          target: state.target,
          options: state.options,
          known: source.pages,
          completed: completed,
          partial: partial,
          only: only,
        )
        .listen(
          (progress) {
            if (run != _run) return;
            final missing = progress.failures.values
                .whereType<OcrDataMissingException>()
                .firstOrNull;
            final pdf = state.pdf!.copyWith(
              pages: progress.pages,
              partial: progress.partial,
              currentPage: () => progress.page,
              stage: () => progress.stage,
              missingData: missing == null ? null : () => missing,
            );
            _emitPdf(
              pdf,
              _rendered(
                state.copyWith(
                  results: progress.results,
                  failures: {...kept, ...progress.failures},
                  pdf: () => pdf,
                  maskedPersonalData:
                      maskedBefore + progress.maskedPersonalData,
                ),
              ),
            );
          },
          // The translator reports failures as progress, never as errors.
          onError: (Object _) {}, // coverage:ignore-line
          onDone: () {
            if (run == _run) {
              _pdfSubscription = null;
              _revokeGrants();
              final pdf = state.pdf!.copyWith(
                currentPage: () => null,
                stage: () => null,
              );
              // Every page read, none with text.
              final noText =
                  state.isComplete &&
                  state.failures.isEmpty &&
                  !state.hasTranslation;
              emit(
                state.copyWith(
                  status: noText
                      ? DocumentStatus.ready
                      : DocumentStatus.translated,
                  results: noText ? const {} : null,
                  pdf: () => pdf,
                  error: noText ? () => DocumentError.pdfNoText : null,
                ),
              );
            }
            if (!done.isCompleted) done.complete();
          },
        );
    await done.future;
  }

  /// The translated PDF's bytes: written once for the current results.
  Future<Uint8List> _pdfBytes() {
    final cached = _pdfOutput;
    if (cached != null && identical(cached.results, state.results)) {
      return Future.value(cached.bytes);
    }
    return _pdfWriting ??= _writePdf().whenComplete(() => _pdfWriting = null);
  }

  Future<Uint8List> _writePdf() async {
    final source = state.pdf!;
    final results = state.results;
    final target = state.target;
    _emitPdf(source.copyWith(writing: true));
    try {
      final bytes = await _pdf.write(
        pdfOutputPages(
          source,
          results,
          direction: (text) => pdfTextDirection(target, text),
        ),
      );
      _pdfOutput = (results: results, bytes: bytes);
      return bytes;
    } finally {
      if (state.pdf case final pdf? when !isClosed) {
        _emitPdf(pdf.copyWith(writing: false));
      }
    }
  }

  /// Saves the translated text of a PDF, page by page (each page starts
  /// with [pageHeading] of its number, when given), as plain text
  /// ([DocumentTranslateState.pdfTextFileName]).
  Future<void> saveText({String Function(int number)? pageHeading}) async {
    final source = state.pdf;
    if (source == null || !state.hasTranslation) return;
    try {
      final saved = await _files.saveFile(
        fileName: state.pdfTextFileName,
        bytes: utf8.encode(
          pdfText(source, state.results, heading: pageHeading),
        ),
        mimeType: DocumentFormat.plainText.mimeType,
      );
      if (saved) _notify(DocumentNotice.saved);
    } on Object {
      _notify(DocumentNotice.saveFailed);
    }
  }

  /// Closes the PDF on the platform side, if one may be open.
  void _closePdf() {
    _pdfOutput = null;
    if (!_pdfOpen) return;
    _pdfOpen = false;
    unawaited(_pdf.close().then((_) {}, onError: (Object _) {}));
  }

  @override
  void onChange(Change<DocumentTranslateState> change) {
    super.onChange(change);
    // A PDF is read with its source language's recognition data: read the
    // preview again when that changes.
    final next = change.nextState;
    if (next.isPdf &&
        change.currentState.isPdf &&
        change.currentState.source != next.source) {
      scheduleMicrotask(() => unawaited(_previewPdf()));
    }
  }

  // ---------------------------------------------------------------------
  // Export
  // ---------------------------------------------------------------------

  /// The translated document encoded like the original file (an office
  /// document or e-book in its own format).
  // Read-only query derived from state; it changes nothing.
  // ignore: prefer_void_public_cubit_methods
  Uint8List get outputBytes {
    final package = state.packagedDocument;
    if (package != null) return package.render(state.translations);
    return encodeText(
      state.output,
      state.mode == DocumentInputMode.file ? state.encoding : TextEncoding.utf8,
    );
  }

  /// [outputBytes], rendered off the UI isolate for large packages.
  Future<Uint8List> _exportBytes() async {
    if (state.isPdf) return await _pdfBytes();
    final package = state.packagedDocument;
    if (package == null || state.sizeBytes < backgroundBytes) {
      return outputBytes;
    }
    return await renderPackageInBackground(package, state.translations);
  }

  /// Saves the translated document (download on the web).
  Future<void> save() async {
    if (!state.hasTranslation) return;
    try {
      final saved = await _files.saveFile(
        fileName: state.outputFileName,
        bytes: await _exportBytes(),
        mimeType: (state.format ?? DocumentFormat.plainText).mimeType,
      );
      if (saved) _notify(DocumentNotice.saved);
    } on Object {
      _notify(DocumentNotice.saveFailed);
    }
  }

  /// Shares the translated document as a file.
  Future<void> share({Rect? origin}) async {
    if (!state.hasTranslation) return;
    try {
      await _files.shareFile(
        fileName: state.outputFileName,
        bytes: await _exportBytes(),
        mimeType: (state.format ?? DocumentFormat.plainText).mimeType,
        origin: origin,
      );
    } on ShareUnsupportedException {
      _notify(DocumentNotice.shareUnsupported);
    } on Object {
      _notify(DocumentNotice.shareFailed);
    }
  }

  /// Copies the translated text.
  Future<void> copy() async {
    if (!state.hasTranslation) return;
    await _files.copyText(state.output);
    _notify(DocumentNotice.copied);
  }

  /// Whether the platform can share files.
  // Read-only query derived from state; it changes nothing.
  // ignore: prefer_void_public_cubit_methods
  bool get canShareFiles => _files.canShareFiles;

  // ---------------------------------------------------------------------

  void _notify(DocumentNotice notice, [DocumentTranslateState? base]) {
    if (isClosed) return;
    final from = base ?? state;
    emit(from.copyWith(notice: () => notice, noticeId: from.noticeId + 1));
  }

  /// [base] with output re-rendered from its translations.
  DocumentTranslateState _rendered(DocumentTranslateState base) {
    if (base.pdf case final pdf?) {
      return base.copyWith(
        output: base.hasTranslation ? pdfText(pdf, base.results) : '',
      );
    }
    final package = base.packagedDocument;
    if (package != null) {
      // The file is rendered when it is saved; the preview shows the text.
      return base.copyWith(
        output: base.results.isEmpty
            ? ''
            : segmentsPreview(package.segments, base.translations),
      );
    }
    final document = base.document;
    if (document == null || base.results.isEmpty) {
      return base.copyWith(output: '');
    }
    final bilingual = base.bilingual && base.supportsBilingual;
    return base.copyWith(
      output: bilingual
          ? document.renderBilingual(base.translations)
          : document.render(base.translations),
    );
  }

  /// [base] without translation results (stopping a running translation).
  DocumentTranslateState _withoutTranslation(DocumentTranslateState base) {
    if (base.isTranslating) _stop();
    final hasInput = base.hasDocument;
    return base.copyWith(
      status: switch (base.status) {
        DocumentStatus.translating ||
        DocumentStatus.translated => hasInput ? .ready : .empty,
        final status => status,
      },
      results: const {},
      failures: const {},
      translations: const [],
      output: '',
      pdf: base.pdf == null ? null : () => base.pdf!.withoutTranslation(),
      maskedPersonalData: 0,
    );
  }

  /// [base] without any document.
  DocumentTranslateState _cleared(DocumentTranslateState base) =>
      _withoutTranslation(base).copyWith(
        status: DocumentStatus.empty,
        fileName: () => null,
        text: '',
        encoding: TextEncoding.utf8,
        sizeBytes: 0,
        format: () => null,
        document: () => null,
        packagedDocument: () => null,
        pdf: () => null,
        plan: () => null,
        error: () => null,
      );

  @override
  Future<void> close() {
    _stop();
    _closePdf();
    return super.close();
  }
}

class _FileInput {
  const new({
    required this.name,
    required this.text,
    required this.format,
    required this.encoding,
    required this.sizeBytes,
    this.package,
    this.pdf,
  });

  final String name;
  final String text;
  final DocumentFormat format;
  final TextEncoding encoding;
  final int sizeBytes;

  /// The parsed office document or e-book (null for text files).
  final PackagedDocument? package;

  /// The opened PDF (null for other files).
  final PdfSource? pdf;

  _FileInput withPdf(PdfSource pdf) => _FileInput(
    name: name,
    text: text,
    format: format,
    encoding: encoding,
    sizeBytes: sizeBytes,
    pdf: pdf,
  );

  _FileInput withFormat(DocumentFormat format) => _FileInput(
    name: name,
    text: text,
    format: format,
    encoding: encoding,
    sizeBytes: sizeBytes,
  );

  _FileInput withPackage(PackagedDocument package) => _FileInput(
    name: name,
    text: text,
    format: format,
    encoding: encoding,
    sizeBytes: sizeBytes,
    package: package,
  );
}
