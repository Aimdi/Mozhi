import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/cubit/document_translate_cubit.dart';
import 'package:mozhi/documents/pdf/pdf_pages.dart' show PdfLimits;
import 'package:mozhi/l10n/l10n.dart';
import 'package:translation_repository/translation_repository.dart';

/// Localised name of [format].
String documentFormatLabel(AppLocalizations l10n, DocumentFormat format) =>
    switch (format) {
      DocumentFormat.plainText => l10n.documentsFormatPlainText,
      DocumentFormat.markdown => l10n.documentsFormatMarkdown,
      DocumentFormat.srt => l10n.documentsFormatSrt,
      DocumentFormat.vtt => l10n.documentsFormatVtt,
      DocumentFormat.json => l10n.documentsFormatJson,
      DocumentFormat.html => l10n.documentsFormatHtml,
      DocumentFormat.xliff => l10n.documentsFormatXliff,
      DocumentFormat.androidStrings => l10n.documentsFormatAndroidStrings,
      DocumentFormat.po => l10n.documentsFormatPo,
      DocumentFormat.csv => l10n.documentsFormatCsv,
      DocumentFormat.tsv => l10n.documentsFormatTsv,
      DocumentFormat.appleStrings => l10n.documentsFormatAppleStrings,
      DocumentFormat.xcstrings => l10n.documentsFormatXcstrings,
      DocumentFormat.docx => l10n.documentsFormatDocx,
      DocumentFormat.pptx => l10n.documentsFormatPptx,
      DocumentFormat.xlsx => l10n.documentsFormatXlsx,
      DocumentFormat.odt => l10n.documentsFormatOdt,
      DocumentFormat.odp => l10n.documentsFormatOdp,
      DocumentFormat.ods => l10n.documentsFormatOds,
      DocumentFormat.epub => l10n.documentsFormatEpub,
      DocumentFormat.pdf => l10n.documentsFormatPdf,
    };

/// Icon for [format].
IconData documentFormatIcon(DocumentFormat? format) => switch (format) {
  DocumentFormat.plainText => Icons.article_outlined,
  DocumentFormat.markdown => Icons.text_snippet_outlined,
  DocumentFormat.srt || DocumentFormat.vtt => Icons.subtitles_outlined,
  DocumentFormat.json => Icons.data_object,
  DocumentFormat.html => Icons.code,
  DocumentFormat.xliff ||
  DocumentFormat.androidStrings ||
  DocumentFormat.po ||
  DocumentFormat.appleStrings ||
  DocumentFormat.xcstrings => Icons.translate,
  DocumentFormat.csv ||
  DocumentFormat.tsv ||
  DocumentFormat.xlsx ||
  DocumentFormat.ods => Icons.table_chart_outlined,
  DocumentFormat.docx || DocumentFormat.odt => Icons.description_outlined,
  DocumentFormat.pptx || DocumentFormat.odp => Icons.slideshow_outlined,
  DocumentFormat.epub => Icons.menu_book_outlined,
  DocumentFormat.pdf => Icons.picture_as_pdf_outlined,
  null => Icons.insert_drive_file_outlined,
};

/// `512 B`, `12.3 KB`, `1.5 MB` in the current locale.
String documentSizeLabel(BuildContext context, int bytes) {
  final l10n = context.l10n;
  final locale = Localizations.localeOf(context).toLanguageTag();
  final number = NumberFormat('0.#', locale);
  if (bytes < 1024) return l10n.documentsSizeBytes('$bytes');
  if (bytes < 1024 * 1024) {
    return l10n.documentsSizeKilobytes(number.format(bytes / 1024));
  }
  return l10n.documentsSizeMegabytes(number.format(bytes / (1024 * 1024)));
}

/// "Under a minute" / "About 3 minutes".
String documentEstimateLabel(AppLocalizations l10n, Duration estimate) {
  if (estimate < const Duration(minutes: 1)) {
    return l10n.documentsEstimateUnderMinute;
  }
  return l10n.documentsEstimateMinutes((estimate.inSeconds / 60).round());
}

/// Message for a load error of a file in [format] (when known).
String documentErrorLabel(
  BuildContext context,
  DocumentError error, {
  required int maxBytes,
  DocumentFormat? format,
}) {
  final l10n = context.l10n;
  final formatName = format == null
      ? l10n.documentsFormatPlainText
      : documentFormatLabel(l10n, format);
  final pdf = format == DocumentFormat.pdf;
  return switch (error) {
    DocumentError.unsupportedFormat => l10n.documentsErrorUnsupportedFile,
    DocumentError.tooLarge when pdf => l10n.documentsErrorPdfTooLarge(
      PdfLimits.maxPages,
      documentSizeLabel(context, PdfLimits.maxBytes),
    ),
    DocumentError.tooLarge => l10n.documentsErrorTooLarge(
      documentSizeLabel(context, maxBytes),
    ),
    DocumentError.notText => l10n.documentsErrorNotText,
    DocumentError.readFailed => l10n.documentsErrorRead,
    DocumentError.invalidJson => l10n.documentsErrorInvalidJson,
    DocumentError.invalidFormat => l10n.documentsErrorInvalidFormat(formatName),
    DocumentError.damagedFile => l10n.documentsErrorDamaged(formatName),
    DocumentError.encrypted when pdf => l10n.documentsErrorPdfEncrypted,
    DocumentError.encrypted => l10n.documentsErrorEncrypted,
    DocumentError.unsafeFile => l10n.documentsErrorUnsafe,
    DocumentError.nothingToTranslate => l10n.documentsErrorNothing,
    DocumentError.pdfNeedsApp => l10n.documentsErrorPdfNeedsApp,
    DocumentError.pdfNoText => l10n.documentsErrorPdfNoText,
  };
}

/// Display name of [language] in the UI language ([languageDisplayName];
/// "Detect language" is localised).
String documentLanguageLabel(AppLocalizations l10n, Language language) =>
    language.isAuto
    ? l10n.documentsDetectLanguage
    : languageDisplayName(language, l10n.localeName);
