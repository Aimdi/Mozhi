import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:bloc/bloc.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/cubit/document_translate_state.dart';
import 'package:mozhi/documents/data/document_file_service.dart';
import 'package:translation_repository/translation_repository.dart';

export 'document_translate_state.dart';

/// Drives the document translation screen.
///
/// * Engine, languages and options start from the main translate screen
///   (see [syncEngines]) and follow it until the user changes them here.
/// * A document comes from a picked file ([pickFile] / [loadFile]) or
///   pasted text ([setText]); it is parsed into segments and planned into
///   chunks right away (format, size, counts and an estimate are shown).
/// * [translate] runs the [DocumentTranslator]; progress, partial output
///   and failed chunks update live. [cancel] stops the run (keeping what
///   is done); [retryFailed]/[retryChunk] translate what is missing.
/// * Changing the document, engine or languages discards translations.
class DocumentTranslateCubit extends Cubit<DocumentTranslateState> {
  new({
    required TranslationRepository repository,
    required this._files,
    DocumentTranslator? translator,
    this._chunker = const Chunker(),
    this.maxBytes = DocumentTranslateCubitDefaults.maxBytes,
    List<TranslationEngine> engines = const [],
    TranslationEngine? engine,
    List<Language> sourceLanguages = const [],
    List<Language> targetLanguages = const [],
    Language source = Language.auto,
    Language target = _english,
    TranslationOptions options = const TranslationOptions(),
  }) : _repository = repository,
       _translator = translator ?? DocumentTranslator(repository: repository),
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

  final TranslationRepository _repository;
  final DocumentFileService _files;
  final Chunker _chunker;
  final DocumentTranslator _translator;

  /// Largest accepted file in bytes.
  final int maxBytes;

  /// Whether engine/languages still mirror the translate screen.
  bool _followTranslate = true;
  int _languagesRequest = 0;

  StreamSubscription<DocumentProgress>? _subscription;
  Completer<void>? _runDone;
  int _run = 0;

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
    return state.copyWith(
      sourceLanguages: sources,
      targetLanguages: targets,
      source: source,
      target: target,
      languagesLoading: false,
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
    emit(_withoutTranslation(state).copyWith(target: language));
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
    emit(_withoutTranslation(state).copyWith(source: source, target: target));
  }

  // ---------------------------------------------------------------------
  // Input
  // ---------------------------------------------------------------------

  /// Switches between a picked file and pasted text (each keeps its own
  /// input).
  void setMode(DocumentInputMode mode) {
    if (_busy || mode == state.mode) return;
    final base = state.copyWith(mode: mode);
    switch (mode) {
      case DocumentInputMode.file:
        final file = _file;
        if (file == null) {
          emit(_cleared(base));
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
    final base = _cleared(state).copyWith(
      mode: DocumentInputMode.file,
      fileName: () => name,
      sizeBytes: bytes.length,
    );
    final format = DocumentFormat.fromFileName(name);
    if (format == null) {
      emit(base.copyWith(error: () => DocumentError.unsupportedFormat));
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

  /// Uses pasted/typed [text] as the document (format detected unless
  /// chosen with [setFormat]).
  void setText(String text) {
    if (state.isTranslating) return;
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
    if (_busy || format == state.format) return;
    if (state.mode == DocumentInputMode.text) {
      _pastedFormat = format;
      _loadPasted(state);
      return;
    }
    final file = _file;
    if (file == null) return;
    _file = file.copyWith(format: format);
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
    if (state.mode == DocumentInputMode.file) {
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
    );
    final ParsedDocument document;
    try {
      document = parseDocument(text, format);
    } on DocumentParseException {
      emit(
        next.copyWith(
          status: DocumentStatus.empty,
          document: () => null,
          plan: () => null,
          error: () => DocumentError.invalidJson,
        ),
      );
      return;
    }
    emit(
      next.copyWith(
        status: DocumentStatus.ready,
        document: () => document,
        plan: () => _chunker.plan(document),
        error: () => document.isEmpty ? DocumentError.nothingToTranslate : null,
      ),
    );
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

  Future<void> _start({required bool fresh, List<int>? only}) {
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
                ),
              ),
            );
          },
          onError: (Object _) {},
          onDone: () {
            if (run == _run) {
              _subscription = null;
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
    final done = _runDone;
    if (done != null && !done.isCompleted) done.complete();
  }

  /// Subtitles: also write the original lines in exports.
  void setBilingual({required bool enabled}) {
    if (enabled == state.bilingual) return;
    emit(_rendered(state.copyWith(bilingual: enabled)));
  }

  // ---------------------------------------------------------------------
  // Export
  // ---------------------------------------------------------------------

  /// The translated document encoded like the original file.
  Uint8List get outputBytes => encodeText(
    state.output,
    state.mode == DocumentInputMode.file ? state.encoding : TextEncoding.utf8,
  );

  /// Saves the translated document (download on the web).
  Future<void> save() async {
    if (!state.hasTranslation) return;
    try {
      final saved = await _files.saveFile(
        fileName: state.outputFileName,
        bytes: outputBytes,
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
        bytes: outputBytes,
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
  bool get canShareFiles => _files.canShareFiles;

  // ---------------------------------------------------------------------

  void _notify(DocumentNotice notice, [DocumentTranslateState? base]) {
    if (isClosed) return;
    final from = base ?? state;
    emit(from.copyWith(notice: () => notice, noticeId: from.noticeId + 1));
  }

  /// [base] with output re-rendered from its translations.
  DocumentTranslateState _rendered(DocumentTranslateState base) {
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
    final hasInput = base.document != null;
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
        plan: () => null,
        error: () => null,
      );

  @override
  Future<void> close() {
    _stop();
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
  });

  final String name;
  final String text;
  final DocumentFormat format;
  final TextEncoding encoding;
  final int sizeBytes;

  _FileInput copyWith({DocumentFormat? format}) => _FileInput(
    name: name,
    text: text,
    format: format ?? this.format,
    encoding: encoding,
    sizeBytes: sizeBytes,
  );
}
