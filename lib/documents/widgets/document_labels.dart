import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/cubit/document_translate_cubit.dart';
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
    };

/// Icon for [format].
IconData documentFormatIcon(DocumentFormat? format) => switch (format) {
  DocumentFormat.plainText => Icons.article_outlined,
  DocumentFormat.markdown => Icons.text_snippet_outlined,
  DocumentFormat.srt || DocumentFormat.vtt => Icons.subtitles_outlined,
  DocumentFormat.json => Icons.data_object,
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

/// Message for a load error.
String documentErrorLabel(
  BuildContext context,
  DocumentError error, {
  required int maxBytes,
}) {
  final l10n = context.l10n;
  return switch (error) {
    DocumentError.unsupportedFormat => l10n.documentsErrorUnsupported,
    DocumentError.tooLarge => l10n.documentsErrorTooLarge(
      documentSizeLabel(context, maxBytes),
    ),
    DocumentError.notText => l10n.documentsErrorNotText,
    DocumentError.readFailed => l10n.documentsErrorRead,
    DocumentError.invalidJson => l10n.documentsErrorInvalidJson,
    DocumentError.nothingToTranslate => l10n.documentsErrorNothing,
  };
}

/// Display name of [language] ("Detect language" is localised).
String documentLanguageLabel(AppLocalizations l10n, Language language) =>
    language.isAuto ? l10n.documentsDetectLanguage : language.name;
