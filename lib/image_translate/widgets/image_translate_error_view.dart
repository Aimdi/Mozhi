import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/image_translate/widgets/image_translate_labels.dart';
import 'package:mozhi/image_translate/widgets/image_translate_links.dart';
import 'package:mozhi/image_translate/widgets/ocr_language_offer.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:translation_repository/translation_repository.dart'
    show ConsentRequiredException;

/// Error message with a retry button and, when useful, a shortcut to the
/// settings page that fixes it. A `ConsentRequiredException` is shown as
/// the consent prompt instead, and missing text recognition data
/// ([OcrDataMissingException]) as the offer to download it, when
/// [textRecognitionData] is given ([onRetry] runs once it is installed).
class ImageTranslateErrorView extends StatelessWidget {
  const new({
    required this.error,
    this.onRetry,
    this.textRecognitionData,
    super.key,
  });

  final Object? error;
  final VoidCallback? onRetry;

  /// The recognizer's downloadable language data, if it has any.
  final TextRecognitionLanguageData? textRecognitionData;

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
    final info = describeImageTranslateError(l10n, error);
    final (fixLabel, fixRoute) = switch (info.fix) {
      TranslateErrorFix.instances => (
        l10n.translateManageInstances,
        ImageTranslateLinks.instances,
      ),
      TranslateErrorFix.providers => (
        l10n.translateProvidersAction,
        ImageTranslateLinks.providers,
      ),
      TranslateErrorFix.none => (null, null),
    };
    // Flat: an error-tinted hairline outline, no fill.
    return DecoratedBox(
      key: const Key('image_translate_error'),
      decoration: BoxDecoration(
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.5),
        ),
        borderRadius: BorderRadius.circular(16),
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
                    child: Text(info.message, style: theme.textTheme.bodyLarge),
                  ),
                ),
              ],
            ),
            if (onRetry != null || fixRoute != null) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (onRetry != null)
                    FilledButton.icon(
                      key: const Key('image_translate_retry_button'),
                      style: FilledButton.styleFrom(
                        shape: const StadiumBorder(),
                        textStyle: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh),
                      label: Text(l10n.commonRetry),
                    ),
                  if (fixRoute != null && fixLabel != null)
                    TextButton(
                      onPressed: () => context.go(fixRoute),
                      child: Text(fixLabel),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
