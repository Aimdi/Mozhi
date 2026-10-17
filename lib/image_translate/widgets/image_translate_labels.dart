import 'package:material_ui/material_ui.dart';
import 'package:mozhi/image_translate/cubit/image_translate_cubit.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:translation_repository/translation_repository.dart';

/// Display name of [method], e.g. "AI vision · Claude".
String imageMethodLabel(AppLocalizations l10n, ImageTranslateMethod method) =>
    switch (method.kind) {
      ImageTranslateMethodKind.mozhiLens => l10n.imageTranslateMethodMozhi,
      ImageTranslateMethodKind.aiVision => l10n.imageTranslateMethodAi(
        method.engine?.name ?? '',
      ),
      ImageTranslateMethodKind.onDevice => l10n.imageTranslateMethodOnDevice,
    };

/// One-line explanation of a method [kind].
String imageMethodDescription(
  AppLocalizations l10n,
  ImageTranslateMethodKind kind,
) => switch (kind) {
  ImageTranslateMethodKind.mozhiLens =>
    l10n.imageTranslateMethodMozhiDescription,
  ImageTranslateMethodKind.aiVision => l10n.imageTranslateMethodAiDescription,
  ImageTranslateMethodKind.onDevice =>
    l10n.imageTranslateMethodOnDeviceDescription,
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
      ImageTranslatePhase.uploading => l10n.imageTranslatePhaseMozhi,
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
/// [ImageTranslateException]s are described like translator errors.
TranslateErrorInfo describeImageTranslateError(
  AppLocalizations l10n,
  Object? error,
) => switch (error) {
  ImageTranslateException(:final kind) => TranslateErrorInfo(switch (kind) {
    ImageTranslateErrorKind.tooLarge => l10n.imageTranslateErrorTooLarge,
    ImageTranslateErrorKind.unsupported => l10n.imageTranslateErrorUnsupported,
    ImageTranslateErrorKind.invalidImage =>
      l10n.imageTranslateErrorInvalidImage,
    ImageTranslateErrorKind.noText => l10n.imageTranslateErrorNoText,
    ImageTranslateErrorKind.permissionDenied =>
      l10n.imageTranslateErrorPermission,
    ImageTranslateErrorKind.pickFailed => l10n.imageTranslateErrorPick,
    ImageTranslateErrorKind.noEngine => l10n.imageTranslateErrorNoEngine,
    ImageTranslateErrorKind.unsupportedLanguage =>
      l10n.imageTranslateErrorLanguage,
    ImageTranslateErrorKind.recognitionFailed =>
      l10n.imageTranslateErrorRecognition,
    ImageTranslateErrorKind.recognitionLanguageUnsupported =>
      l10n.imageTranslateErrorRecognitionLanguage,
    ImageTranslateErrorKind.timeout => l10n.imageTranslateErrorTimeout,
  }),
  _ => describeTranslateError(l10n, error),
};
