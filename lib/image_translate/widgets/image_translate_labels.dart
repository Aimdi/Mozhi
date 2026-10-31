import 'package:material_ui/material_ui.dart';
import 'package:mozhi/image_translate/cubit/image_translate_cubit.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:translation_repository/translation_repository.dart';

/// Display name of [method], e.g. "AI vision · Claude".
String imageMethodLabel(AppLocalizations l10n, ImageTranslateMethod method) =>
    switch (method.kind) {
      ImageTranslateMethodKind.mozhiLens =>
        l10n.imageTranslateMethodMozhiGoogle,
      ImageTranslateMethodKind.aiVision => l10n.imageTranslateMethodAi(
        method.engine?.name ?? '',
      ),
      ImageTranslateMethodKind.onDevice => l10n.imageTranslateMethodOnDevice,
    };

/// One-line explanation of a method [kind]: on-device recognition is the
/// recommended one, Mozhi via Google Translate is experimental.
String imageMethodDescription(
  AppLocalizations l10n,
  ImageTranslateMethodKind kind,
) => switch (kind) {
  ImageTranslateMethodKind.mozhiLens =>
    l10n.imageTranslateMethodMozhiGoogleDescription,
  ImageTranslateMethodKind.aiVision => l10n.imageTranslateMethodAiDescription,
  ImageTranslateMethodKind.onDevice =>
    l10n.imageTranslateMethodOnDeviceRecommended,
};

IconData imageMethodIcon(ImageTranslateMethodKind kind) => switch (kind) {
  ImageTranslateMethodKind.mozhiLens => Icons.image_search,
  ImageTranslateMethodKind.aiVision => Icons.auto_awesome_outlined,
  ImageTranslateMethodKind.onDevice => Icons.document_scanner_outlined,
};

/// What the progress indicator says during [state]'s phase.
String imagePhaseMessage(AppLocalizations l10n, ImageTranslateState state) =>
    switch (state.phase) {
      ImageTranslatePhase.preparing => l10n.imageTranslatePhasePreparing,
      ImageTranslatePhase.uploading
          when state.method?.kind == ImageTranslateMethodKind.aiVision =>
        l10n.imageTranslatePhaseAi(state.method?.engine?.name ?? ''),
      ImageTranslatePhase.uploading => l10n.imageTranslatePhaseMozhiGoogle(
        TranslationRepository.mozhiImageTimeout.inSeconds,
      ),
      ImageTranslatePhase.recognizing => l10n.imageTranslatePhaseRecognizing,
      ImageTranslatePhase.translatingText =>
        l10n.imageTranslatePhaseTranslatingText,
    };

/// Display name of [language] (localized "Detect language" for auto).
String imageLanguageLabel(AppLocalizations l10n, Language language) =>
    language.isAuto ? l10n.translateDetectLanguage : language.name;

/// Name of the language with [code] from [languages] or the catalogue.
String imageLanguageNameFor(String code, List<Language> languages) {
  final normalized = LanguageMatcher.normalize(code);
  for (final language in languages) {
    if (LanguageMatcher.normalize(language.code) == normalized) {
      return language.name;
    }
  }
  return LanguageCatalog.byCode(code)?.name ?? code;
}

/// Friendly description of an image translation error. Errors that are not
/// [ImageTranslateException]s are described like translator errors; image
/// errors with a cause get its sanitized message as details.
///
/// [method] is the method that failed: a Mozhi timeout names the time
/// Google Translate had (`TranslationRepository.mozhiImageTimeout`).
TranslateErrorInfo describeImageTranslateError(
  AppLocalizations l10n,
  Object? error, {
  ImageTranslateMethodKind? method,
}) => switch (error) {
  ImageTranslateException(:final kind, :final cause) => TranslateErrorInfo(
    _imageErrorMessage(l10n, kind, method),
    fix: kind == ImageTranslateErrorKind.serviceRefused
        ? TranslateErrorFix.instances
        : TranslateErrorFix.none,
    details: sanitizeErrorDetails(cause),
  ),
  _ => describeTranslateError(l10n, error),
};

String _imageErrorMessage(
  AppLocalizations l10n,
  ImageTranslateErrorKind kind,
  ImageTranslateMethodKind? method,
) => switch (kind) {
  ImageTranslateErrorKind.tooLarge => l10n.imageTranslateErrorTooLarge,
  ImageTranslateErrorKind.unsupported => l10n.imageTranslateErrorUnsupported,
  ImageTranslateErrorKind.invalidImage => l10n.imageTranslateErrorInvalidImage,
  ImageTranslateErrorKind.noText => l10n.imageTranslateErrorNoText,
  ImageTranslateErrorKind.permissionDenied =>
    l10n.imageTranslateErrorPermission,
  ImageTranslateErrorKind.pickFailed => l10n.imageTranslateErrorPick,
  ImageTranslateErrorKind.noCameraApp => l10n.imageTranslateErrorNoCameraApp,
  ImageTranslateErrorKind.noEngine => l10n.imageTranslateErrorNoEngine,
  ImageTranslateErrorKind.unsupportedLanguage =>
    l10n.imageTranslateErrorLanguage,
  ImageTranslateErrorKind.recognitionFailed =>
    l10n.imageTranslateErrorRecognition,
  ImageTranslateErrorKind.recognitionLanguageUnsupported =>
    l10n.imageTranslateErrorRecognitionLanguage,
  ImageTranslateErrorKind.timeout
      when method == ImageTranslateMethodKind.mozhiLens =>
    l10n.imageTranslateErrorTimeoutMozhi(
      TranslationRepository.mozhiImageTimeout.inSeconds,
    ),
  ImageTranslateErrorKind.timeout => l10n.imageTranslateErrorTimeoutGeneric,
  ImageTranslateErrorKind.serviceRefused =>
    l10n.imageTranslateErrorServiceRefused,
};
