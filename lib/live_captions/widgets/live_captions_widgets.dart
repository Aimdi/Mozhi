import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/core/widgets/tab_hero.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/live/live_engine.dart';
import 'package:mozhi/live_captions/cubit/live_captions_cubit.dart';
import 'package:mozhi/live_captions/data/method_channel_captions_host.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/transcribe/data/transcriber.dart'
    show formatTranscriptTime;
import 'package:mozhi/transcribe/models/transcript_entry.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/language_picker_sheet.dart';
import 'package:mozhi/voice/offline/phrase_transcriber.dart';
import 'package:mozhi/voice/widgets/voice_error_message.dart'
    show voiceSettingsLocation;
import 'package:translation_repository/translation_repository.dart';

/// Opens the "Translate live with" picker (`showLiveEnginePicker`).
typedef LiveEnginePickerOpener = Future<void> Function(BuildContext context);

/// The engine live captions translate with ([resolveLiveEngine]: the one
/// the user picked for live use, else the offline engine).
TranslationEngine liveCaptionsEngine(BuildContext context) => resolveLiveEngine(
  context.read<SettingsCubit>().state,
  context.read<TranslateCubit>().state.engines,
);

/// "Caption other apps" for the Transcribe page's app bar: shown where
/// live captions run (Android 10+, [available], default: the platform's
/// captions host says so), it opens [AppRoutes.liveCaptions].
class LiveCaptionsEntryButton extends StatefulWidget {
  const new({this.available, super.key});

  /// Whether live captions run here (tests).
  final Future<bool> Function()? available;

  @override
  State<LiveCaptionsEntryButton> createState() =>
      _LiveCaptionsEntryButtonState();
}

class _LiveCaptionsEntryButtonState extends State<LiveCaptionsEntryButton> {
  late final Future<bool> _available =
      (widget.available ?? _platformAvailable)();

  static Future<bool> _platformAvailable() async =>
      (await platformCaptionsHost()).isSupported;

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
    future: _available,
    builder: (context, snapshot) {
      if (snapshot.data != true) return const SizedBox.shrink();
      final l10n = context.l10n;
      return IconButton(
        key: const Key('live_captions_entry'),
        tooltip: '${l10n.liveCaptionsEntry}\n${l10n.liveCaptionsEntryHint}',
        icon: const Icon(Icons.closed_caption_outlined),
        onPressed: () =>
            unawaited(GoRouter.of(context).push<void>(AppRoutes.liveCaptions)),
      );
    },
  );
}

/// What live captions do and what they capture, the languages, the live
/// engine (its chip opens the picker) and where the text goes.
class LiveCaptionsOptions extends StatelessWidget {
  const new({required this.openEnginePicker, super.key});

  final LiveEnginePickerOpener openEnginePicker;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final cubit = context.read<LiveCaptionsCubit>();
    final state = context.watch<LiveCaptionsCubit>().state;
    // Rebuilt when the live engine or the engines change.
    context
      ..watch<SettingsCubit>()
      ..watch<TranslateCubit>();
    final engine = liveCaptionsEngine(context);
    final destination = _destinationOf(context, engine);
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

    final detected = state.source.isAuto ? state.detectedLanguage : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ActionChip(
                key: const Key('live_captions_source'),
                avatar: const Icon(Icons.graphic_eq),
                tooltip: l10n.liveCaptionsSource,
                label: Text(
                  l10n.liveCaptionsSourceValue(
                    context.languageName(state.source),
                  ),
                ),
                onPressed: state.isActive
                    ? null
                    : () => unawaited(pick(source: true)),
              ),
              ActionChip(
                key: const Key('live_captions_target'),
                avatar: const Icon(Icons.closed_caption_outlined),
                tooltip: l10n.liveCaptionsTarget,
                label: Text(
                  l10n.liveCaptionsTargetValue(
                    context.languageName(state.target),
                  ),
                ),
                onPressed: () => unawaited(pick(source: false)),
              ),
              ActionChip(
                key: const Key('live_captions_engine'),
                avatar: Icon(
                  destination == null
                      ? Icons.translate
                      : destinationIcon(destination, engineId: engine.id),
                ),
                tooltip: l10n.liveCaptionsEngineTooltip,
                label: Text(engine.name),
                onPressed: () => unawaited(openEnginePicker(context)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            destination == null || destination is OnDeviceDestination
                ? l10n.liveCaptionsEngineOnDevice
                : l10n.liveCaptionsEngineSent(
                    destinationLabel(l10n, destination, engineId: engine.id),
                  ),
            key: const Key('live_captions_destination'),
            style: quiet,
          ),
          if (detected != null) ...[
            const SizedBox(height: 4),
            Text(
              l10n.liveCaptionsDetected(context.languageNameOf(detected)),
              key: const Key('live_captions_detected'),
              style: quiet,
            ),
          ],
          SwitchListTile(
            key: const Key('live_captions_show_original'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.liveCaptionsShowOriginal),
            value: state.showOriginal,
            onChanged: (enabled) => cubit.setShowOriginal(enabled: enabled),
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
      // An engine removed meanwhile: nothing to say where.
      // ignore: avoid_catching_errors
    } on ArgumentError {
      return null;
    }
  }
}

/// What live captions capture and keep (shown while the transcript is
/// empty).
class LiveCaptionsAbout extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    return SingleChildScrollView(
      key: const Key('live_captions_about'),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: TabHero.maxTextWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TabHero(
                icon: Icons.closed_caption_outlined,
                title: l10n.liveCaptionsAboutTitle,
                body: l10n.liveCaptionsAbout,
              ),
              const SizedBox(height: 16),
              for (final (icon, text) in [
                (Icons.lock_outline, l10n.liveCaptionsAboutPrivacy),
                (Icons.cast_outlined, l10n.liveCaptionsAboutConsent),
                (Icons.play_circle_outline, l10n.liveCaptionsEmptyBody),
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(icon, size: 20, color: palette.secondaryText),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(text, style: theme.textTheme.bodyMedium),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Why the captions hear nothing now, or what to know while they run: the
/// silence hint, the pause, the missing caption bar, phrases waiting.
class LiveCaptionsBanners extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<LiveCaptionsCubit>().state;
    final messages = <(Key, IconData, String)>[
      if (state.isRunning && state.silenceHint)
        (
          const Key('live_captions_silence'),
          Icons.volume_off_outlined,
          l10n.liveCaptionsSilenceHint,
        ),
      if (state.isRunning && !state.captionBar)
        (
          const Key('live_captions_no_bar'),
          Icons.picture_in_picture_outlined,
          l10n.liveCaptionsNoBar,
        ),
    ];
    if (messages.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (key, icon, text) in messages)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: DecoratedBox(
              key: key,
              decoration: BoxDecoration(
                border: Border.all(color: AppPalette.of(context).hairline),
                borderRadius: AppLook.of(context).menuRadius,
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 20),
                    const SizedBox(width: 12),
                    Expanded(child: Text(text)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The transcript: a paragraph per phrase, its time, the words and the
/// translation; it follows the newest phrase unless the user scrolled up.
class LiveCaptionsTranscript extends StatefulWidget {
  const new({super.key});

  @override
  State<LiveCaptionsTranscript> createState() => _LiveCaptionsTranscriptState();
}

class _LiveCaptionsTranscriptState extends State<LiveCaptionsTranscript> {
  final _scroll = ScrollController();
  int _count = 0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _follow() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    // Only when the newest was in view: reading back stays put.
    if (position.maxScrollExtent - position.pixels > 160) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final entries = context.select<LiveCaptionsCubit, List<TranscriptEntry>>(
      (cubit) => cubit.state.entries,
    );
    if (entries.length != _count) {
      _count = entries.length;
      _follow();
    }
    final consentId = entries
        .where((entry) => entry.translationError is ConsentRequiredException)
        .lastOrNull
        ?.id;
    final waiting = entries
        .where((entry) => entry.translationError is ConsentRequiredException)
        .length;
    final wide = MediaQuery.sizeOf(context).width >= 840;
    return ListView.builder(
      key: const Key('live_captions_transcript'),
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return LiveCaptionParagraph(
          key: ValueKey(entry.id),
          entry: entry,
          wide: wide,
          showConsent: entry.id == consentId,
          consentRequests: waiting,
        );
      },
    );
  }
}

/// One phrase of the transcript.
class LiveCaptionParagraph extends StatelessWidget {
  const new({
    required this.entry,
    this.wide = false,
    this.showConsent = false,
    this.consentRequests = 1,
    super.key,
  });

  final TranscriptEntry entry;

  /// The translation beside the words instead of below.
  final bool wide;

  /// Show the consent prompt (the latest phrase that waits for it).
  final bool showConsent;
  final int consentRequests;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final quiet = theme.textTheme.bodyMedium?.copyWith(
      color: palette.secondaryText,
      fontStyle: FontStyle.italic,
    );
    final time = formatTranscriptTime(entry.start);
    final original = switch (entry.status) {
      PhraseStatus.transcribed => SelectableText(
        entry.text,
        style: theme.textTheme.bodyLarge,
      ),
      PhraseStatus.skipped => Text(l10n.transcribeSkipped, style: quiet),
      PhraseStatus.failed => Text(l10n.transcribePhraseFailed, style: quiet),
    };
    final translation = entry.translationStatus == null
        ? null
        : _CaptionTranslation(
            entry: entry,
            showConsent: showConsent,
            consentRequests: consentRequests,
          );
    final body = translation == null
        ? original
        : wide
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: original),
              const SizedBox(width: 24),
              Expanded(child: translation),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [original, const SizedBox(height: 6), translation],
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            label: l10n.transcribeTimeLabel(time),
            excludeSemantics: true,
            child: Text(
              time,
              style: theme.textTheme.labelMedium?.copyWith(
                color: palette.secondaryText,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 4),
          body,
        ],
      ),
    );
  }
}

class _CaptionTranslation extends StatelessWidget {
  const new({
    required this.entry,
    required this.showConsent,
    required this.consentRequests,
  });

  final TranscriptEntry entry;
  final bool showConsent;
  final int consentRequests;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final scheme = theme.colorScheme;
    final quiet = theme.textTheme.bodyMedium?.copyWith(
      color: palette.secondaryText,
    );
    final text = entry.translation.trim();
    final cubit = context.read<LiveCaptionsCubit>();
    switch (entry.translationStatus) {
      case null:
        return const SizedBox.shrink();
      case TranscriptTranslationStatus.done ||
              TranscriptTranslationStatus.translating
          when text.isNotEmpty:
        return SelectableText(
          text,
          style: theme.textTheme.bodyLarge?.copyWith(color: scheme.primary),
        );
      case TranscriptTranslationStatus.done ||
          TranscriptTranslationStatus.translating:
        // Not a live region: captions are not announced one by one.
        return Text(l10n.transcribeTranslating, style: quiet);
      case TranscriptTranslationStatus.failed:
        final error = entry.translationError;
        if (error is ConsentRequiredException) {
          if (!showConsent) {
            return Text(l10n.transcribeTranslationWaiting, style: quiet);
          }
          return ConsentInlinePrompt(
            key: Key('live_captions_consent_${entry.id}'),
            consent: error,
            requests: consentRequests,
            onGranted: cubit.retryTranslations,
          );
        }
        if (error is LiveCaptionsBehindException) {
          return Text(l10n.liveCaptionsBehind, style: quiet);
        }
        return Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            Text(l10n.transcribeTranslationFailed, style: quiet),
            TextButton.icon(
              key: Key('live_captions_retry_${entry.id}'),
              onPressed: cubit.retryTranslations,
              icon: const Icon(Icons.refresh),
              label: Text(l10n.commonRetry),
            ),
          ],
        );
    }
  }
}

/// The bottom: the status (a live region) and Start / Stop.
class LiveCaptionsControls extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<LiveCaptionsCubit>();
    final state = context.watch<LiveCaptionsCubit>().state;
    final status = switch (state.status) {
      LiveCaptionsStatus.starting => l10n.liveCaptionsStatusStarting,
      LiveCaptionsStatus.running => switch (state.pause) {
        LiveCaptionsPause.locked => l10n.liveCaptionsStatusLocked,
        LiveCaptionsPause.hot => l10n.liveCaptionsStatusHot,
        null when state.pending > 1 => l10n.liveCaptionsPending(state.pending),
        null => l10n.liveCaptionsStatusListening,
      },
      _ => l10n.liveCaptionsStatusIdle,
    };
    final active = state.isActive;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              status,
              key: const Key('live_captions_status'),
              textAlign: TextAlign.center,
              style: theme.textTheme.labelLarge?.copyWith(
                color: AppPalette.of(context).secondaryText,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: active
                  ? FilledButton.tonalIcon(
                      key: const Key('live_captions_stop'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                      ),
                      onPressed: () => unawaited(cubit.stop()),
                      icon: const Icon(Icons.stop),
                      label: Text(l10n.liveCaptionsStop),
                    )
                  : FilledButton.icon(
                      key: const Key('live_captions_start'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                      ),
                      onPressed: state.canStart
                          ? () => unawaited(cubit.start())
                          : null,
                      icon: const Icon(Icons.closed_caption),
                      label: Text(l10n.liveCaptionsStart),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Why captions cannot run here (the web app, Android before 10) or what
/// they need (the speech model, offered from the voice input settings).
class LiveCaptionsUnavailable extends StatelessWidget {
  const new({required this.status, super.key});

  final LiveCaptionsStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final needsModel = status == LiveCaptionsStatus.needsModel;
    final router = GoRouter.maybeOf(context);
    return Center(
      key: Key('live_captions_unavailable_${status.name}'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: TabHero(
          icon: needsModel ? Icons.download_outlined : Icons.phone_android,
          title: needsModel
              ? l10n.liveCaptionsNeedsModelTitle
              : l10n.liveCaptionsUnsupportedTitle,
          body: needsModel
              ? l10n.liveCaptionsNeedsModelBody
              : l10n.liveCaptionsUnsupportedBody,
          child: needsModel && router != null
              ? FilledButton.icon(
                  key: const Key('live_captions_download_model'),
                  onPressed: () async {
                    await router.push<void>(voiceSettingsLocation);
                    if (context.mounted) {
                      await context.read<LiveCaptionsCubit>().load();
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
