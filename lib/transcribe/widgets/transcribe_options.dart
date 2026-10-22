import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/core/widgets/tab_hero.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/transcribe/cubit/transcribe_cubit.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/language_picker_sheet.dart';
import 'package:mozhi/voice/cubit/voice_settings_state.dart'
    show VoiceModelErrorKind;
import 'package:mozhi/voice/widgets/voice_error_message.dart'
    show voiceSettingsLocation;
import 'package:translation_repository/translation_repository.dart';

/// The engine Transcribe translates with (see `TranscribeCubit`): the
/// translate screen's, or the on-device one in Offline only.
TranslationEngine? transcribeEngine(BuildContext context) {
  final translate = context.read<TranslateCubit>().state;
  final repository = context.read<TranslationRepository>();
  final engine = translate.engine;
  if (repository.privacyMode != PrivacyMode.offlineOnly ||
      (engine?.isOffline ?? false)) {
    return engine;
  }
  return translate.engines.where((e) => e.isOffline).firstOrNull ?? engine;
}

/// The spoken language, translation on or off, its language and where the
/// phrases go to be translated; above them, what hears the speech.
class TranscribeOptions extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final cubit = context.read<TranscribeCubit>();
    final state = context.watch<TranscribeCubit>().state;
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: palette.secondaryText,
    );

    Future<void> pick({required bool source}) async {
      final picked = await showLanguagePicker(context, source: source);
      if (picked == null) return;
      if (source) {
        cubit.setSource(picked);
      } else {
        cubit.setTarget(picked);
      }
    }

    final engine = state.translate ? transcribeEngine(context) : null;
    final destination = engine == null ? null : _destinationOf(context, engine);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                state.mode == TranscribeMode.system
                    ? Icons.public
                    : Icons.phone_android,
                size: 16,
                color: palette.secondaryText,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  state.mode == TranscribeMode.system
                      ? l10n.transcribeSystemNotice
                      : l10n.transcribeOnDevice,
                  key: const Key('transcribe_hears'),
                  style: quiet,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ActionChip(
                key: const Key('transcribe_source'),
                avatar: const Icon(Icons.record_voice_over_outlined),
                tooltip: l10n.transcribeSpokenLanguage,
                label: Text(
                  l10n.transcribeSpokenLanguageValue(state.source.name),
                ),
                onPressed: state.isRecording
                    ? null
                    : () => unawaited(pick(source: true)),
              ),
              FilterChip(
                key: const Key('transcribe_translate'),
                avatar: state.translate ? null : const Icon(Icons.translate),
                selected: state.translate,
                label: Text(
                  state.translate
                      ? l10n.transcribeTranslateInto(state.target.name)
                      : l10n.transcribeTranslate,
                ),
                onSelected: (enabled) => cubit.setTranslate(enabled: enabled),
              ),
              if (state.translate)
                ActionChip(
                  key: const Key('transcribe_target'),
                  avatar: const Icon(Icons.language),
                  tooltip: l10n.transcribeTargetLanguage,
                  label: Text(state.target.name),
                  onPressed: () => unawaited(pick(source: false)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (destination != null) ...[
                Icon(
                  destinationIcon(destination),
                  size: 16,
                  color: palette.secondaryText,
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  !state.translate
                      ? l10n.transcribeTranslateOff
                      : engine == null
                      ? l10n.transcribeNoEngine
                      : destination is OnDeviceDestination
                      ? l10n.transcribeTranslatedOnDevice
                      : l10n.transcribeTranslatedBy(
                          destinationLabel(
                            l10n,
                            destination!,
                            engineId: engine.id,
                          ),
                        ),
                  key: const Key('transcribe_destination'),
                  style: quiet,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static DataDestination? _destinationOf(
    BuildContext context,
    TranslationEngine engine,
  ) {
    try {
      return context.read<TranslationRepository>().destinationOf(engine.id);
      // A provider removed meanwhile: nothing to say where.
      // ignore: avoid_catching_errors
    } on ArgumentError {
      return null;
    }
  }
}

/// Speech detection is missing: offer its download (with progress).
class TranscribeVadBanner extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<TranscribeCubit>();
    final state = context.watch<TranscribeCubit>().state;
    final progress = state.voiceDetectionProgress;
    final metered =
        state.voiceDetectionError?.kind == VoiceModelErrorKind.metered;
    final failed = state.voiceDetectionError != null && !metered;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: AppPalette.of(context).hairline),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                progress != null
                    ? l10n.transcribeVadDownloading((progress * 100).floor())
                    : metered
                    ? l10n.transcribeVadMetered
                    : failed
                    ? l10n.transcribeVadFailed
                    : l10n.transcribeVadMissing,
                key: const Key('transcribe_vad'),
                style: theme.textTheme.bodyMedium,
              ),
              if (progress != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 8, bottom: 8),
                  child: LinearProgressIndicator(value: progress),
                )
              else
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    key: const Key('transcribe_vad_download'),
                    onPressed: () => unawaited(
                      cubit.downloadVoiceDetection(overMeteredNetwork: metered),
                    ),
                    child: Text(
                      metered
                          ? l10n.transcribeVadDownloadAnyway
                          : l10n.transcribeVadDownload,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Why Transcribe cannot listen here, and what helps.
class TranscribeUnavailable extends StatelessWidget {
  const new({required this.mode, super.key});

  final TranscribeMode mode;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (title, body) = switch (mode) {
      TranscribeMode.needsModel => (
        l10n.transcribeNeedsModelTitle,
        l10n.transcribeNeedsModelBody,
      ),
      TranscribeMode.offlineOnly => (
        l10n.transcribeOfflineOnlyTitle,
        l10n.transcribeOfflineOnlyBody,
      ),
      _ => (l10n.transcribeUnavailableTitle, l10n.transcribeUnavailableBody),
    };
    final router = GoRouter.maybeOf(context);
    return Center(
      key: Key('transcribe_unavailable_${mode.name}'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: TabHero(
          icon: Icons.mic_off_outlined,
          title: title,
          body: body,
          child: mode == TranscribeMode.needsModel && router != null
              ? FilledButton.icon(
                  key: const Key('transcribe_download_model'),
                  onPressed: () async {
                    await router.push<void>(voiceSettingsLocation);
                    if (context.mounted) {
                      await context.read<TranscribeCubit>().load();
                    }
                  },
                  icon: const Icon(Icons.download),
                  label: Text(l10n.voiceDownloadModelAction),
                )
              : null,
        ),
      ),
    );
  }
}

/// The empty transcript.
class TranscribeEmpty extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      key: const Key('transcribe_empty'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: TabHero(
          icon: Icons.subtitles_outlined,
          title: l10n.transcribeEmptyTitle,
          body: l10n.transcribeEmptyBody,
        ),
      ),
    );
  }
}
