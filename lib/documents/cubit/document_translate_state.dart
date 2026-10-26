import 'package:equatable/equatable.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/core/office/office.dart';
import 'package:translation_repository/translation_repository.dart';

/// Where the document comes from.
enum DocumentInputMode { file, text }

enum DocumentStatus {
  /// No document yet (or it could not be loaded, see `error`).
  empty,

  /// A file is being picked or read.
  loading,

  /// A document is loaded and can be translated.
  ready,

  /// A translation run is in progress.
  translating,

  /// A run finished, was cancelled or partly failed; see `results` and
  /// `failures`.
  translated,
}

/// Why a document cannot be translated.
enum DocumentError {
  /// The file extension is not supported.
  unsupportedFormat,

  /// The file exceeds the size limit.
  tooLarge,

  /// The file is binary.
  notText,

  /// The file could not be read.
  readFailed,

  /// The JSON is invalid.
  invalidJson,

  /// The text is not valid in its format (other than JSON).
  invalidFormat,

  /// An office document or e-book is damaged, or not of its format.
  damagedFile,

  /// An office document or e-book is password-protected or has DRM.
  encrypted,

  /// An office document or e-book was refused to protect the device (it
  /// unpacks to far too much data, has too many parts or unsafe names).
  unsafeFile,

  /// The document holds no translatable text.
  nothingToTranslate,
}

/// One-off messages for the UI (shown as snack bars).
enum DocumentNotice {
  saved,
  saveFailed,
  shareFailed,
  shareUnsupported,
  copied,
  clipboardEmpty,
  languagesFailed,
}

class DocumentTranslateState extends Equatable {
  const new({
    this.mode = DocumentInputMode.file,
    this.status = DocumentStatus.empty,
    this.fileName,
    this.text = '',
    this.encoding = TextEncoding.utf8,
    this.sizeBytes = 0,
    this.format,
    this.document,
    this.packagedDocument,
    this.plan,
    this.error,
    this.engines = const [],
    this.engine,
    this.sourceLanguages = const [],
    this.targetLanguages = const [],
    this.source = Language.auto,
    this.target = const Language(code: 'en', name: 'English'),
    this.languagesLoading = false,
    this.options = const TranslationOptions(),
    this.results = const {},
    this.failures = const {},
    this.translations = const [],
    this.output = '',
    this.bilingual = false,
    this.notice,
    this.noticeId = 0,
  });

  final DocumentInputMode mode;
  final DocumentStatus status;

  /// Name of the picked file (null for pasted text).
  final String? fileName;

  /// The decoded source text (for office documents and e-books, the
  /// extracted text shown in the preview).
  final String text;

  /// Encoding of the picked file (used when writing the translation).
  final TextEncoding encoding;
  final int sizeBytes;
  final DocumentFormat? format;

  /// A parsed text document.
  final ParsedDocument? document;

  /// A parsed office document or e-book (instead of [document]).
  final PackagedDocument? packagedDocument;
  final ChunkPlan? plan;
  final DocumentError? error;

  final List<TranslationEngine> engines;
  final TranslationEngine? engine;
  final List<Language> sourceLanguages;
  final List<Language> targetLanguages;
  final Language source;
  final Language target;
  final bool languagesLoading;
  final TranslationOptions options;

  /// Translated chunks (chunk index -> one text per unit).
  final Map<int, List<String>> results;

  /// Chunks that failed in the last run(s).
  final Map<int, Object> failures;

  /// Per segment translation (null = not translated yet).
  final List<String?> translations;

  /// The translated document (untranslated parts keep the original); for
  /// office documents and e-books, the translated text shown in the
  /// preview (the file itself is rendered when saved).
  final String output;

  /// Subtitles only: export original and translation lines.
  final bool bilingual;

  final DocumentNotice? notice;

  /// Incremented with every [notice] so repeated notices are delivered.
  final int noticeId;

  bool get hasDocument => document != null || packagedDocument != null;

  /// Whether the input is an office document or e-book (read and written
  /// as bytes).
  bool get isBinary => packagedDocument != null || (format?.isBinary ?? false);

  /// Whether the office document holds macros or ActiveX controls, which
  /// the translated file keeps.
  bool get keepsMacros => switch (packagedDocument) {
    OfficePackage(:final hasMacros) => hasMacros,
    _ => false,
  };

  /// The segments of the document.
  List<Segment> get segments =>
      document?.segments ?? packagedDocument?.segments ?? const [];
  int get segmentCount => segments.length;
  int get chunkCount => plan?.chunks.length ?? 0;
  int get characterCount =>
      document?.characterCount ?? packagedDocument?.characterCount ?? 0;
  int get doneChunks => results.length;

  /// Chunks without a translation (failed, cancelled or not run).
  int get pendingChunks => chunkCount - doneChunks;

  double get progress => chunkCount == 0 ? 0 : doneChunks / chunkCount;
  bool get isTranslating => status == DocumentStatus.translating;
  bool get hasTranslation => results.isNotEmpty;
  bool get isComplete => chunkCount > 0 && pendingChunks == 0;
  bool get supportsBilingual => format?.supportsBilingual ?? false;
  bool get canSwap => !source.isAuto && !target.isCustom;

  bool get canTranslate =>
      hasDocument &&
      segments.isNotEmpty &&
      engine != null &&
      !languagesLoading &&
      !isTranslating &&
      status != DocumentStatus.loading;

  /// The original of segment [index] as the side-by-side view shows it.
  String segmentSource(int index) =>
      document?.segmentSource(index) ?? segmentPreview(segments[index].text);

  /// How segment [index] reads with [translation].
  String segmentOutput(int index, String translation) =>
      document?.segmentOutput(index, translation) ??
      segmentPreview(translation);

  /// Suggested name of the translated file.
  String get outputFileName => translatedFileName(
    fileName,
    format ?? DocumentFormat.plainText,
    target.code,
  );

  /// Rough duration of a translation run.
  Duration get estimate {
    if (chunkCount == 0) return Duration.zero;
    final perRequest = (engine?.isAi ?? false) ? 8 : 2;
    final rounds = (chunkCount / DocumentTranslateCubitDefaults.concurrency)
        .ceil();
    return Duration(seconds: rounds * perRequest);
  }

  DocumentTranslateState copyWith({
    DocumentInputMode? mode,
    DocumentStatus? status,
    String? Function()? fileName,
    String? text,
    TextEncoding? encoding,
    int? sizeBytes,
    DocumentFormat? Function()? format,
    ParsedDocument? Function()? document,
    PackagedDocument? Function()? packagedDocument,
    ChunkPlan? Function()? plan,
    DocumentError? Function()? error,
    List<TranslationEngine>? engines,
    TranslationEngine? Function()? engine,
    List<Language>? sourceLanguages,
    List<Language>? targetLanguages,
    Language? source,
    Language? target,
    bool? languagesLoading,
    TranslationOptions? options,
    Map<int, List<String>>? results,
    Map<int, Object>? failures,
    List<String?>? translations,
    String? output,
    bool? bilingual,
    DocumentNotice? Function()? notice,
    int? noticeId,
  }) {
    return DocumentTranslateState(
      mode: mode ?? this.mode,
      status: status ?? this.status,
      fileName: fileName != null ? fileName() : this.fileName,
      text: text ?? this.text,
      encoding: encoding ?? this.encoding,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      format: format != null ? format() : this.format,
      document: document != null ? document() : this.document,
      packagedDocument: packagedDocument != null
          ? packagedDocument()
          : this.packagedDocument,
      plan: plan != null ? plan() : this.plan,
      error: error != null ? error() : this.error,
      engines: engines ?? this.engines,
      engine: engine != null ? engine() : this.engine,
      sourceLanguages: sourceLanguages ?? this.sourceLanguages,
      targetLanguages: targetLanguages ?? this.targetLanguages,
      source: source ?? this.source,
      target: target ?? this.target,
      languagesLoading: languagesLoading ?? this.languagesLoading,
      options: options ?? this.options,
      results: results ?? this.results,
      failures: failures ?? this.failures,
      translations: translations ?? this.translations,
      output: output ?? this.output,
      bilingual: bilingual ?? this.bilingual,
      notice: notice != null ? notice() : this.notice,
      noticeId: noticeId ?? this.noticeId,
    );
  }

  @override
  List<Object?> get props => [
    mode,
    status,
    fileName,
    text,
    encoding,
    sizeBytes,
    format,
    document,
    packagedDocument,
    plan,
    error,
    engines,
    engine,
    sourceLanguages,
    targetLanguages,
    source,
    target,
    languagesLoading,
    options,
    results,
    failures,
    translations,
    output,
    bilingual,
    notice,
    noticeId,
  ];
}

/// Defaults shared by the cubit and the estimate.
abstract final class DocumentTranslateCubitDefaults {
  /// Requests in flight at once.
  static const concurrency = 2;

  /// Largest accepted text file.
  static const int maxBytes = 2 * 1024 * 1024;

  /// Largest accepted office document or e-book (images and other entries
  /// are copied, only the text parts are read).
  static const int maxPackageBytes = 25 * 1024 * 1024;

  /// Office documents and e-books from this size on (text documents from
  /// this many characters on) are read and written off the UI isolate. The
  /// parsers take linear time, so smaller ones are read right away.
  static const int backgroundBytes = 64 * 1024;
}
