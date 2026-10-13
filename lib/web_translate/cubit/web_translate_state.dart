import 'package:equatable/equatable.dart';
import 'package:mozhi/web_translate/core/readable_extractor.dart';
import 'package:translation_repository/translation_repository.dart';

enum WebTranslateStatus {
  /// Nothing loaded yet.
  idle,

  /// Downloading and extracting the page.
  loading,

  /// Page loaded, not translated (no engine available yet).
  loaded,

  /// Translating the blocks.
  translating,

  /// Every block is translated.
  translated,

  /// The user stopped the translation; some blocks may be translated.
  stopped,

  /// Loading or translating failed ([WebTranslateState.error]).
  failure,
}

/// How the reader shows the page.
enum ReaderMode { translated, original, sideBySide }

/// The engine and languages a page is translated with (taken from the
/// text translator's current selection).
class WebTranslateSelection extends Equatable {
  const new({
    required this.engine,
    required this.source,
    required this.target,
    this.options = const TranslationOptions(),
  });

  final TranslationEngine engine;
  final Language source;
  final Language target;
  final TranslationOptions options;

  @override
  List<Object?> get props => [engine, source, target, options];
}

class WebTranslateState extends Equatable {
  const new({
    this.url = '',
    this.urlInvalid = false,
    this.status = WebTranslateStatus.idle,
    this.pageUri,
    this.page,
    this.truncated = false,
    this.unsupportedCharset,
    this.translations = const [],
    this.translatedTitle,
    this.selection,
    this.detectedSource,
    this.error,
    this.mode = ReaderMode.translated,
  });

  /// Text of the address field.
  final String url;

  /// The last load was attempted with an address that is not valid.
  final bool urlInvalid;
  final WebTranslateStatus status;

  /// Final address of the loaded page (after redirects).
  final Uri? pageUri;
  final ReadablePage? page;

  /// Only the start of a very large page was loaded.
  final bool truncated;

  /// Declared page encoding that could not be decoded.
  final String? unsupportedCharset;

  /// Translation of each of `page.blocks` (null = not translated yet; code
  /// blocks are never translated).
  final List<String?> translations;
  final String? translatedTitle;

  /// Engine and languages of the current/last translation.
  final WebTranslateSelection? selection;

  /// Source language detected by the engine (auto source only).
  final String? detectedSource;

  /// `WebPageException` or a translation error.
  final Object? error;
  final ReaderMode mode;

  bool get hasPage => page != null;

  bool get isBusy =>
      status == WebTranslateStatus.loading ||
      status == WebTranslateStatus.translating;

  /// Title and blocks that need translating.
  int get totalItems {
    final page = this.page;
    if (page == null) return 0;
    final blocks = page.blocks.where((block) => block.isTranslatable).length;
    return blocks + (page.title.trim().isEmpty ? 0 : 1);
  }

  /// Title and blocks translated so far.
  int get doneItems {
    final page = this.page;
    if (page == null) return 0;
    var done = translatedTitle == null ? 0 : 1;
    for (var i = 0; i < page.blocks.length && i < translations.length; i++) {
      if (page.blocks[i].isTranslatable && translations[i] != null) done++;
    }
    return done;
  }

  /// 0-1.
  double get progress => totalItems == 0 ? 0 : doneItems / totalItems;

  /// Whether some translatable content is still untranslated.
  bool get hasUntranslated => hasPage && doneItems < totalItems;

  /// The translation of block [index], or null.
  String? translationAt(int index) =>
      index < translations.length ? translations[index] : null;

  /// The page title in the translation (falls back to the original).
  String get displayTitle => translatedTitle ?? page?.title ?? '';

  /// Plain text of the page for copying and sharing: the translation
  /// (untranslated blocks in the original) or, with [translated] false, the
  /// original. Headings, list bullets/numbers and quotes are kept readable.
  String plainText({bool translated = true}) {
    final page = this.page;
    if (page == null) return '';
    final title = translated ? displayTitle : page.title;
    final lines = <String>[if (title.trim().isNotEmpty) title];
    for (var i = 0; i < page.blocks.length; i++) {
      final block = page.blocks[i];
      final text = (translated ? translationAt(i) : null) ?? block.text;
      final indent = '  ' * block.depth;
      lines.add(switch (block.kind) {
        ReadableBlockKind.listItem when block.number != null =>
          '$indent${block.number}. $text',
        ReadableBlockKind.listItem => '$indent• $text',
        ReadableBlockKind.quote => '> ${text.replaceAll('\n', '\n> ')}',
        ReadableBlockKind.image => '[$text]',
        _ => text,
      });
    }
    return lines.join('\n\n');
  }

  WebTranslateState copyWith({
    String? url,
    bool? urlInvalid,
    WebTranslateStatus? status,
    Uri? Function()? pageUri,
    ReadablePage? Function()? page,
    bool? truncated,
    String? Function()? unsupportedCharset,
    List<String?>? translations,
    String? Function()? translatedTitle,
    WebTranslateSelection? Function()? selection,
    String? Function()? detectedSource,
    Object? Function()? error,
    ReaderMode? mode,
  }) {
    return WebTranslateState(
      url: url ?? this.url,
      urlInvalid: urlInvalid ?? this.urlInvalid,
      status: status ?? this.status,
      pageUri: pageUri != null ? pageUri() : this.pageUri,
      page: page != null ? page() : this.page,
      truncated: truncated ?? this.truncated,
      unsupportedCharset: unsupportedCharset != null
          ? unsupportedCharset()
          : this.unsupportedCharset,
      translations: translations ?? this.translations,
      translatedTitle: translatedTitle != null
          ? translatedTitle()
          : this.translatedTitle,
      selection: selection != null ? selection() : this.selection,
      detectedSource: detectedSource != null
          ? detectedSource()
          : this.detectedSource,
      error: error != null ? error() : this.error,
      mode: mode ?? this.mode,
    );
  }

  @override
  List<Object?> get props => [
    url,
    urlInvalid,
    status,
    pageUri,
    page,
    truncated,
    unsupportedCharset,
    translations,
    translatedTitle,
    selection,
    detectedSource,
    error,
    mode,
  ];
}
