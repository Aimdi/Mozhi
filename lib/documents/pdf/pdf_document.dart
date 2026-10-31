import 'dart:ui' show Color, Rect, Size, TextDirection;

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart' show Bidi;
import 'package:mozhi/documents/core/parsed_document.dart' show Segment;
import 'package:mozhi/documents/pdf/pdf_pages.dart';
import 'package:mozhi/image_translate/models/models.dart'
    show OcrDataMissingException;
import 'package:translation_repository/translation_repository.dart'
    show Language;

/// A paragraph read on a PDF page, where it is (in points) and how it
/// looks.
@immutable
class PdfParagraph extends Equatable {
  const new({
    required this.text,
    required this.rect,
    required this.background,
    required this.foreground,
    this.align = PdfTextAlign.start,
    this.fontSize = 12,
  });

  /// The text as read (its lines joined), what is translated.
  final String text;

  /// Where it is, in points from the page's top left.
  final Rect rect;
  final Color background;
  final Color foreground;

  /// Its alignment, relative to the direction of the text that replaces
  /// it.
  final PdfTextAlign align;

  /// Its line pitch in points: the largest size its translation is drawn
  /// at.
  final double fontSize;

  @override
  List<Object?> get props => [
    text,
    rect,
    background,
    foreground,
    align,
    fontSize,
  ];
}

/// What was read on page [page] (0-based) of [size] points with the text
/// recognition data [codes], or taken from the page's text layer
/// ([fromTextLayer]).
@immutable
class PdfPageText extends Equatable {
  const new({
    required this.page,
    required this.size,
    required this.codes,
    this.paragraphs = const [],
    this.fromTextLayer = false,
  });

  final int page;
  final Size size;

  /// The recognition languages it was read with (read again with others).
  final List<String> codes;

  /// The text is the file's own (its text layer, [PdfPages.readText]), not
  /// recognised: the same whatever the recognition data.
  final bool fromTextLayer;

  /// In reading order; none on a page without text.
  final List<PdfParagraph> paragraphs;

  bool get isEmpty => paragraphs.isEmpty;

  /// What is translated: one segment per paragraph.
  List<Segment> get segments => [
    for (final paragraph in paragraphs) Segment(paragraph.text),
  ];

  /// Whether this page was read with [codes] (a page taken from its text
  /// layer reads the same with any).
  bool readWith(List<String> codes) =>
      fromTextLayer || listEquals(this.codes, codes);

  @override
  List<Object?> get props => [page, size, codes, paragraphs, fromTextLayer];
}

/// What happens to the page [PdfSource.currentPage].
enum PdfStage {
  reading,
  translating,

  /// The phone is hot: text recognition waits before it reads the page,
  /// then goes on.
  cooling,
}

/// Why the pages of a PDF cannot be read now.
enum PdfReadIssue {
  /// No text recognition data reads the source language.
  languageUnsupported,

  /// Text recognition does not work on this device.
  recognitionUnavailable,

  /// Reading the first page failed.
  readFailed,
}

/// An opened PDF in the documents screen: its pages' sizes, the pages read
/// so far (kept in memory while the screen is open, so a retry or another
/// engine does not read them again) and what is being done.
@immutable
class PdfSource extends Equatable {
  const new({
    required this.pageSizes,
    this.pages = const {},
    this.partial = const {},
    this.previewing = false,
    this.missingData,
    this.issue,
    this.currentPage,
    this.stage,
    this.writing = false,
  });

  /// Every page's size in points.
  final List<Size> pageSizes;

  /// The pages read so far, by page index.
  final Map<int, PdfPageText> pages;

  /// Pages whose translation stopped half-way: page index -> its finished
  /// chunks (chunk index -> one translation per unit), so a retry sends
  /// only the rest.
  final Map<int, Map<int, List<String>>> partial;

  /// The first page is being read for the preview.
  final bool previewing;

  /// The text recognition data the source language needs and lacks
  /// (offered for download).
  final OcrDataMissingException? missingData;
  final PdfReadIssue? issue;

  /// The page being read or translated, with [stage].
  final int? currentPage;
  final PdfStage? stage;

  /// The translated PDF is being written.
  final bool writing;

  int get pageCount => pageSizes.length;

  /// The page read first (the preview), if read.
  PdfPageText? get firstPage => pages[0];

  /// The read pages in page order.
  List<PdfPageText> get readPages => [
    for (var i = 0; i < pageCount; i++) ?pages[i],
  ];

  PdfSource copyWith({
    Map<int, PdfPageText>? pages,
    Map<int, Map<int, List<String>>>? partial,
    bool? previewing,
    OcrDataMissingException? Function()? missingData,
    PdfReadIssue? Function()? issue,
    int? Function()? currentPage,
    PdfStage? Function()? stage,
    bool? writing,
  }) => PdfSource(
    pageSizes: pageSizes,
    pages: pages ?? this.pages,
    partial: partial ?? this.partial,
    previewing: previewing ?? this.previewing,
    missingData: missingData != null ? missingData() : this.missingData,
    issue: issue != null ? issue() : this.issue,
    currentPage: currentPage != null ? currentPage() : this.currentPage,
    stage: stage != null ? stage() : this.stage,
    writing: writing ?? this.writing,
  );

  /// This PDF without anything of a translation (the pages read stay).
  PdfSource withoutTranslation() => copyWith(
    partial: const {},
    currentPage: () => null,
    stage: () => null,
    writing: false,
  );

  @override
  List<Object?> get props => [
    pageSizes,
    pages,
    partial,
    previewing,
    missingData,
    issue,
    currentPage,
    stage,
    writing,
  ];
}

/// The text of [source]'s read pages in page order: each page's
/// translation where [results] has it (page index -> one text per
/// paragraph; an empty one keeps the original), otherwise its text as read.
/// Paragraphs are separated by blank lines, pages by two; with [heading],
/// every page starts with `heading(page number)`.
String pdfText(
  PdfSource source,
  Map<int, List<String>> results, {
  bool translated = true,
  String Function(int number)? heading,
}) {
  final pages = <String>[];
  for (final page in source.readPages) {
    final translations = translated ? results[page.page] : null;
    final paragraphs = [
      for (var i = 0; i < page.paragraphs.length; i++)
        if (translations != null &&
            i < translations.length &&
            translations[i].trim().isNotEmpty)
          translations[i].trim()
        else
          page.paragraphs[i].text,
    ];
    if (heading == null && paragraphs.isEmpty) continue;
    pages.add([?heading?.call(page.page + 1), ...paragraphs].join('\n\n'));
  }
  return pages.join('\n\n\n');
}

/// The pages of the translated PDF: every page of [source], each with the
/// translations [results] has for it (page index -> one text per
/// paragraph) as blocks over its paragraphs. A page without a translation
/// (no text, or not translated) is kept as it is; an empty translation
/// leaves its paragraph as it is. [direction] gives a translation's
/// direction.
List<PdfOutputPage> pdfOutputPages(
  PdfSource source,
  Map<int, List<String>> results, {
  required TextDirection Function(String text) direction,
}) => [
  for (var index = 0; index < source.pageCount; index++)
    PdfOutputPage(
      sourcePage: index,
      size: source.pageSizes[index],
      blocks: [
        if ((source.pages[index], results[index]) case (
          final page?,
          final translations?,
        ))
          for (var i = 0; i < page.paragraphs.length; i++)
            if (i < translations.length && translations[i].trim().isNotEmpty)
              _block(page.paragraphs[i], translations[i].trim(), direction),
      ],
    ),
];

PdfTextBlock _block(
  PdfParagraph paragraph,
  String text,
  TextDirection Function(String text) direction,
) => PdfTextBlock(
  rect: paragraph.rect,
  text: text,
  color: paragraph.foreground,
  background: paragraph.background,
  direction: direction(text),
  align: paragraph.align,
  fontSize: paragraph.fontSize,
);

/// The direction a translation [text] into [target] is written in: the
/// target language's, or for "Detect language" and custom AI "languages"
/// the direction of [text]'s characters.
TextDirection pdfTextDirection(Language target, String text) {
  if (!target.isAuto && !target.isCustom) {
    return Bidi.isRtlLanguage(target.code)
        ? TextDirection.rtl
        : TextDirection.ltr;
  }
  return Bidi.detectRtlDirectionality(text)
      ? TextDirection.rtl
      : TextDirection.ltr;
}
