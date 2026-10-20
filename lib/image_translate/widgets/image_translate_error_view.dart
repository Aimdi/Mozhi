import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/image_translate/widgets/image_translate_labels.dart';
import 'package:mozhi/image_translate/widgets/image_translate_links.dart';
import 'package:mozhi/image_translate/widgets/ocr_language_offer.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/data/bergamot_model_details.dart'
    show offlineModelDetailsOf;
import 'package:mozhi/translate/widgets/offline_offer.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:translation_repository/translation_repository.dart';

/// Error message with what helps next. A `ConsentRequiredException` is
/// shown as the consent prompt instead, and missing text recognition data
/// ([OcrDataMissingException]) as the offer to download it, when
/// [textRecognitionData] is given ([onRetry] runs once it is installed).
///
/// Otherwise, as fits the error:
///
/// * "Use on-device text recognition" ([onUseOnDevice], given when an
///   upload failed and the device can read the image itself).
/// * "Choose the language of the text" ([onChooseSourceLanguage]) when the
///   source language could not be detected, instead of Retry.
/// * Retry ([onRetry]).
/// * Missing offline models: "Download German (25 MB)" (the size when the
///   offline engine knows it), which opens the offline languages, like the
///   translator's error does.
/// * A shortcut to the instances or AI providers that fix it.
/// * An expandable "Details" section with the sanitized technical message.
///
/// [method] is the method that failed, for its wording.
class ImageTranslateErrorView extends StatelessWidget {
  const new({
    required this.error,
    this.onRetry,
    this.textRecognitionData,
    this.method,
    this.onUseOnDevice,
    this.onChooseSourceLanguage,
    super.key,
  });

  final Object? error;
  final VoidCallback? onRetry;

  /// The recognizer's downloadable language data, if it has any.
  final TextRecognitionLanguageData? textRecognitionData;

  /// The method that failed.
  final ImageTranslateMethodKind? method;

  /// Translates the image with on-device recognition instead.
  final VoidCallback? onUseOnDevice;

  /// Opens the source language picker.
  final VoidCallback? onChooseSourceLanguage;

  @override
  Widget build(BuildContext context) {
    final consent = error;
    if (consent is ConsentRequiredException) {
      // Nothing was sent: once allowed, Retry translates the image.
      return ConsentInlinePrompt(
        key: const Key('image_translate_consent'),
        consent: consent,
        onGranted: onRetry ?? () {},
      );
    }
    final data = textRecognitionData;
    if (consent is OcrDataMissingException && data != null) {
      return OcrLanguageOffer(
        key: ValueKey(consent),
        missing: consent,
        data: data,
        onInstalled: onRetry ?? () {},
      );
    }
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final info = describeImageTranslateError(l10n, error, method: method);
    final chooseSource = info.chooseSourceLanguage
        ? onChooseSourceLanguage
        : null;
    // Retrying cannot detect the language either.
    final retry = chooseSource == null ? onRetry : null;
    final (fixLabel, fixRoute, push) = switch (info.fix) {
      _ when info.offlineModels => (
        _offlineFixLabel(context, l10n) ?? l10n.translateOfflineModelsAction,
        offlineModelsRoute,
        true,
      ),
      // Settings pages sit above the translator: back returns here.
      TranslateErrorFix.instances => (
        l10n.translateManageInstances,
        ImageTranslateLinks.instances,
        true,
      ),
      TranslateErrorFix.providers => (
        l10n.translateProvidersAction,
        ImageTranslateLinks.providers,
        true,
      ),
      TranslateErrorFix.none => (null, null, false),
    };
    final details = info.details;
    final hasActions =
        onUseOnDevice != null ||
        chooseSource != null ||
        retry != null ||
        fixRoute != null;
    // Flat: an error-tinted hairline outline, no fill.
    return DecoratedBox(
      key: const Key('image_translate_error'),
      decoration: BoxDecoration(
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.5),
        ),
        borderRadius: AppRadius.cardBorderRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, color: theme.colorScheme.error),
                const SizedBox(width: 12),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      info.message,
                      key: const Key('image_translate_error_message'),
                      style: theme.textTheme.bodyLarge,
                    ),
                  ),
                ),
              ],
            ),
            if (hasActions) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (onUseOnDevice case final useOnDevice?)
                    FilledButton.icon(
                      key: const Key('image_translate_use_on_device'),
                      onPressed: useOnDevice,
                      icon: const Icon(Icons.document_scanner_outlined),
                      label: Text(l10n.imageTranslateUseOnDevice),
                    ),
                  if (chooseSource != null)
                    FilledButton.icon(
                      key: const Key('image_translate_choose_source'),
                      onPressed: chooseSource,
                      icon: const Icon(Icons.translate),
                      label: Text(l10n.imageTranslateChooseSourceLanguage),
                    ),
                  if (retry != null)
                    if (onUseOnDevice == null)
                      FilledButton.icon(
                        key: const Key('image_translate_retry_button'),
                        onPressed: retry,
                        icon: const Icon(Icons.refresh),
                        label: Text(l10n.commonRetry),
                      )
                    else
                      // On-device recognition is the better next step.
                      FilledButton.tonalIcon(
                        key: const Key('image_translate_retry_button'),
                        onPressed: retry,
                        icon: const Icon(Icons.refresh),
                        label: Text(l10n.commonRetry),
                      ),
                  if (fixRoute != null && fixLabel != null)
                    TextButton(
                      key: const Key('image_translate_error_fix'),
                      onPressed: () => push
                          ? unawaited(context.push<Object?>(fixRoute))
                          : context.go(fixRoute),
                      child: Text(fixLabel),
                    ),
                ],
              ),
            ],
            if (details != null) ...[
              const SizedBox(height: 4),
              TranslateErrorDetails(details: details),
            ],
          ],
        ),
      ),
    );
  }

  /// "Download German (25 MB)" for the languages of an
  /// [OfflineModelMissingException] (English needs no download), or null
  /// when it names none.
  String? _offlineFixLabel(BuildContext context, AppLocalizations l10n) {
    final error = this.error;
    if (error is! OfflineModelMissingException) return null;
    final codes = {
      for (final code in error.languages)
        if (offlineLanguageKey(code) != 'en') code,
    };
    if (codes.isEmpty) return null;
    final translator = maybeOfflineTranslator(context);
    final details = translator == null
        ? null
        : offlineModelDetailsOf(translator);
    return offlineDownloadLabel(l10n, [
      for (final code in codes)
        (
          code: code,
          name: LanguageCatalog.byCode(code)?.name ?? code,
          bytes: details?.downloadSize(code),
        ),
    ]);
  }
}
