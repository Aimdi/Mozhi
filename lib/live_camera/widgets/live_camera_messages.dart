import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/image_translate/widgets/image_language_picker.dart';
import 'package:mozhi/image_translate/widgets/image_translate_labels.dart';
import 'package:mozhi/image_translate/widgets/ocr_language_offer.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/live/live_engine_picker.dart';
import 'package:mozhi/live_camera/cubit/live_camera_cubit.dart';
import 'package:mozhi/live_camera/widgets/live_camera_labels.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// How many requests one "Once" in the live camera's consent prompt lets
/// through (each block translation is one; each use keeps it alive a
/// while, see `TranslationRepository.allowOnce`).
const liveCameraConsentRequests = 500;

/// Lets the user pick the language of the text ([source]) or the target
/// of the live camera (the translator's languages, else the catalogue).
Future<void> pickLiveCameraLanguage(
  BuildContext context, {
  required bool source,
}) async {
  final l10n = context.l10n;
  final cubit = context.read<LiveCameraCubit>();
  final translate = _translateState(context);
  final sources = translate?.sourceLanguages ?? const [];
  final targets = translate?.targetLanguages ?? const [];
  final languages = source
      ? (sources.length > 1 ? sources : [Language.auto, ...LanguageCatalog.all])
      : (targets.isNotEmpty ? targets : LanguageCatalog.all);
  final current = source ? cubit.state.source : cubit.state.target;
  final picked = await showImageLanguagePicker(
    context,
    languages: [
      for (final language in languages)
        if (!language.isCustom) language,
    ],
    selected: current,
    title: source
        ? l10n.translateSourceLanguage(imageLanguageLabel(l10n, current))
        : l10n.translateTargetLanguage(imageLanguageLabel(l10n, current)),
  );
  if (picked == null || cubit.isClosed) return;
  unawaited(source ? cubit.setSource(picked) : cubit.setTarget(picked));
}

TranslateState? _translateState(BuildContext context) {
  try {
    return context.read<TranslateCubit>().state;
  } on ProviderNotFoundException {
    return null;
  }
}

/// What the live camera has to say over the preview, when anything: the
/// camera permission, a camera failure, missing recognition data (the
/// offer to get it), the consent the live engine needs, its failure.
class LiveCameraMessages extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<LiveCameraCubit>().state;
    final cubit = context.read<LiveCameraCubit>();
    void chooseSource() =>
        unawaited(pickLiveCameraLanguage(context, source: true));
    final chooseSourceButton = TextButton(
      key: const Key('live_camera_choose_source'),
      onPressed: chooseSource,
      child: Text(l10n.imageTranslateChooseSourceLanguage),
    );
    final message = switch (state.status) {
      LiveCameraStatus.denied => LiveCameraMessage(
        key: const Key('live_camera_denied'),
        icon: Icons.no_photography_outlined,
        title: l10n.liveCameraPermissionTitle,
        body: l10n.liveCameraPermissionBody,
        actions: [
          FilledButton(
            key: const Key('live_camera_allow'),
            onPressed: () => unawaited(cubit.retryAccess()),
            child: Text(l10n.liveCameraPermissionAllow),
          ),
        ],
      ),
      LiveCameraStatus.blocked => LiveCameraMessage(
        key: const Key('live_camera_blocked'),
        icon: Icons.no_photography_outlined,
        title: l10n.liveCameraPermissionTitle,
        body: l10n.liveCameraBlockedBody,
        actions: [
          FilledButton(
            key: const Key('live_camera_open_settings'),
            onPressed: () => unawaited(cubit.openSettings()),
            child: Text(l10n.liveCameraOpenSettings),
          ),
          TextButton(
            key: const Key('live_camera_ask_again'),
            onPressed: () => unawaited(cubit.retryAccess()),
            child: Text(l10n.commonRetry),
          ),
        ],
      ),
      LiveCameraStatus.unsupported => LiveCameraMessage(
        key: const Key('live_camera_unsupported'),
        icon: Icons.no_photography_outlined,
        title: l10n.liveCameraUnsupportedTitle,
        body: l10n.liveCameraUnsupported,
      ),
      LiveCameraStatus.failed => LiveCameraMessage(
        key: const Key('live_camera_failed'),
        icon: Icons.error_outline,
        body: liveCameraErrorText(l10n, state.cameraError),
        actions: [
          FilledButton(
            key: const Key('live_camera_retry'),
            onPressed: () => unawaited(cubit.retryCamera()),
            child: Text(l10n.commonRetry),
          ),
        ],
      ),
      LiveCameraStatus.running ||
      LiveCameraStatus.starting ||
      LiveCameraStatus.paused => _readingMessage(
        context,
        state,
        chooseSourceButton,
      ),
      _ => null,
    };
    if (message == null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: message,
        ),
      ),
    );
  }

  Widget? _readingMessage(
    BuildContext context,
    LiveCameraState state,
    Widget chooseSource,
  ) {
    final l10n = context.l10n;
    final cubit = context.read<LiveCameraCubit>();
    final missing = state.ocrMissing;
    if (missing != null) {
      final data = _languageData(context);
      if (data == null) return null;
      return _Surface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            OcrLanguageOffer(
              key: ValueKey(missing),
              missing: missing,
              data: data,
              onInstalled: () => unawaited(cubit.ocrInstalled()),
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: chooseSource,
            ),
          ],
        ),
      );
    }
    if (state.ocrUnsupported) {
      return LiveCameraMessage(
        key: const Key('live_camera_ocr_unsupported'),
        icon: Icons.document_scanner_outlined,
        body: l10n.liveCameraOcrUnsupported(
          imageLanguageLabel(l10n, state.source),
        ),
        actions: [chooseSource],
      );
    }
    final consent = state.consent;
    if (consent != null) {
      return _Surface(
        child: ConsentInlinePrompt(
          key: ValueKey(consent),
          consent: consent,
          requests: liveCameraConsentRequests,
          onGranted: cubit.consentGranted,
        ),
      );
    }
    final error = state.translationError;
    if (error != null) {
      return LiveCameraMessage(
        key: const Key('live_camera_translation_error'),
        icon: Icons.translate,
        body: liveCameraTranslationErrorText(l10n, error),
        actions: [
          TextButton(
            key: const Key('live_camera_choose_engine'),
            onPressed: () => unawaited(showLiveEnginePicker(context)),
            child: Text(l10n.liveCameraChooseEngine),
          ),
        ],
      );
    }
    if (state.recognitionFailed) {
      return LiveCameraMessage(
        key: const Key('live_camera_recognition_failed'),
        icon: Icons.document_scanner_outlined,
        body: l10n.liveCameraRecognitionFailed,
        actions: [chooseSource],
      );
    }
    return null;
  }

  static TextRecognitionLanguageData? _languageData(BuildContext context) {
    try {
      return textRecognitionLanguageDataOf(
        context.read<TextRecognitionService>(),
      );
    } on ProviderNotFoundException {
      return null;
    }
  }
}

/// A message card over the camera: an icon, an optional [title], the
/// [body] and [actions]. Announced when it appears.
class LiveCameraMessage extends StatelessWidget {
  const new({
    required this.icon,
    required this.body,
    this.title,
    this.actions = const [],
    super.key,
  });

  final IconData icon;
  final String? title;
  final String body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = this.title;
    return _Surface(
      child: Semantics(
        container: true,
        liveRegion: true,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 12,
                children: [
                  Icon(icon, color: theme.colorScheme.primary),
                  Expanded(
                    child: title == null
                        ? Text(body, style: theme.textTheme.bodyMedium)
                        : Semantics(
                            header: true,
                            child: Text(
                              title,
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                  ),
                ],
              ),
              if (title != null) ...[
                const SizedBox(height: 8),
                Text(body, style: theme.textTheme.bodyMedium),
              ],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: actions),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The theme's surface under a message, so it reads over any picture.
class _Surface extends StatelessWidget {
  const new({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    borderRadius: AppRadius.cardBorderRadius,
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}
