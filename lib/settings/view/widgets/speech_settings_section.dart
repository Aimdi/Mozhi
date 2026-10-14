import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/local_overlay.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/speech_settings_cubit.dart';
import 'package:mozhi/settings/view/widgets/choice_dialog.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:mozhi/speech/speech_error_message.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/speech/widgets/prefer_device_voice_tile.dart';
import 'package:translation_repository/translation_repository.dart';

/// The "Read aloud" settings: the speech rate with a live preview, the
/// "use device voice" switch and a device voice per recently used language.
/// Reads the [SpeechService] from context.
class SpeechSettingsSection extends StatelessWidget {
  const new({required this.languages, super.key});

  /// Recently used languages, most relevant first (e.g. the current target
  /// and source, then the recent languages); see [voiceLanguages].
  final List<Language> languages;

  /// Most recent languages offered for a voice choice.
  static const maxVoiceLanguages = 4;

  /// The languages to offer a voice for: the first [maxVoiceLanguages]
  /// speakable [recent] languages (one per device language tag; `auto` and
  /// custom languages are skipped), then every other language that has a
  /// chosen voice in [settings], so it can be reset.
  static List<Language> voiceLanguages(
    List<Language> recent,
    SpeechSettings settings,
  ) {
    final tags = <String>{};
    final languages = <Language>[];
    for (final language in recent) {
      if (languages.length == maxVoiceLanguages) break;
      if (language.isAuto || language.isCustom) continue;
      final tag = speechLanguageTag(language.code);
      if (tag != null && tags.add(tag)) languages.add(language);
    }
    for (final tag in settings.voices.keys) {
      if (!tags.add(tag)) continue;
      languages.add(
        LanguageCatalog.byCode(tag) ?? Language(code: tag, name: tag),
      );
    }
    return languages;
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) {
        final cubit = SpeechSettingsCubit(context.read<SpeechService>());
        unawaited(cubit.load());
        return cubit;
      },
      child: SpeechSettingsView(languages: languages),
    );
  }
}

class SpeechSettingsView extends StatelessWidget {
  const new({required this.languages, super.key});

  /// See [SpeechSettingsSection.languages].
  final List<Language> languages;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<SpeechSettingsCubit>().state;
    final voiceLanguages = SpeechSettingsSection.voiceLanguages(
      languages,
      state.settings,
    );
    return BlocListener<SpeechSettingsCubit, SpeechSettingsState>(
      // Voice previews fail inside the voice picker, which shows the error
      // itself: a snackbar would be hidden under the dialog's barrier.
      listenWhen: (previous, current) =>
          current.previewError != null &&
          current.previewError != previous.previewError &&
          !SpeechSettingsCubit.isVoicePreviewId(current.failedPreviewId),
      listener: (context, state) => ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(speechErrorMessage(l10n, state.previewError!)),
          ),
        ),
      child: SettingsSection(
        title: l10n.speechSettingsTitle,
        children: [
          _RateSetting(
            rate: state.settings.rate,
            previewing: state.previewingRate,
          ),
          if (state.deviceVoiceSupported) ...[
            const PreferDeviceVoiceTile(),
            if (voiceLanguages.isNotEmpty) ...[
              const _VoicesHeader(),
              for (final language in voiceLanguages)
                _VoiceTile(
                  language: language,
                  voice: state.settings.voiceFor(language.code),
                  listed: state.voices[speechLanguageTag(language.code)],
                  loading:
                      state.loadingVoicesFor ==
                      speechLanguageTag(language.code),
                ),
            ],
          ],
        ],
      ),
    );
  }
}

/// The speech rate slider (0.5x-1.5x) and its preview button.
class _RateSetting extends StatelessWidget {
  const new({required this.rate, required this.previewing});

  final double rate;
  final bool previewing;

  /// Language of the preview sentence: the app's language.
  static String _previewLanguage(BuildContext context) =>
      speechLanguageTag(Localizations.localeOf(context).toLanguageTag()) ??
      'en';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<SpeechSettingsCubit>();
    final value = l10n.speechRateValue(rate);
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 4, end: 8, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(Icons.av_timer_outlined),
            title: Text(l10n.speechRate),
            subtitle: Text(l10n.speechRateSubtitle),
            // The slider below reads the value.
            trailing: ExcludeSemantics(
              child: Text(value, style: theme.textTheme.titleMedium),
            ),
          ),
          Row(
            children: [
              const SizedBox(width: 8),
              Expanded(
                // One node: the slider named by its label.
                child: MergeSemantics(
                  child: Semantics(
                    label: l10n.speechRate,
                    child: LocalOverlay(
                      child: Slider(
                        key: const Key('speech_rate_slider'),
                        value: rate,
                        min: SpeechSettings.minRate,
                        max: SpeechSettings.maxRate,
                        divisions:
                            ((SpeechSettings.maxRate - SpeechSettings.minRate) /
                                    SpeechSettings.rateStep)
                                .round(),
                        // No value indicator: the value is shown above, and
                        // the indicator text would also become the slider's
                        // semantic label ("1.0×" read twice).
                        showValueIndicator: ShowValueIndicator.never,
                        semanticFormatterCallback: (value) =>
                            l10n.speechRateValue(
                              SpeechSettings.normalizeRate(value),
                            ),
                        onChanged: (value) => unawaited(cubit.setRate(value)),
                        onChangeEnd: (_) =>
                            unawaited(cubit.refreshRatePreview()),
                      ),
                    ),
                  ),
                ),
              ),
              IconButton(
                key: const Key('speech_rate_preview'),
                tooltip: previewing ? l10n.commonStop : l10n.speechRatePreview,
                isSelected: previewing,
                icon: const Icon(Icons.play_circle_outline),
                selectedIcon: const Icon(Icons.stop_circle_outlined),
                onPressed: () => unawaited(
                  cubit.previewRate(
                    text: l10n.speechRatePreviewText,
                    languageCode: _previewLanguage(context),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _VoicesHeader extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            container: true,
            header: true,
            child: Text(
              l10n.speechVoicesTitle,
              style: theme.textTheme.titleSmall,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.speechVoicesDescription,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The device voice chosen for [language]; opens the voice picker.
class _VoiceTile extends StatelessWidget {
  const new({
    required this.language,
    required this.voice,
    required this.listed,
    required this.loading,
  });

  final Language language;
  final DeviceVoice? voice;

  /// The device voices listed for [language], if known (to name [voice]).
  final List<DeviceVoice>? listed;

  /// Whether the device voices of [language] are being listed.
  final bool loading;

  /// [ChoiceDialog] value of the default voice.
  static const _defaultVoice = '';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListTile(
      leading: const Icon(Icons.graphic_eq),
      title: Text(l10n.speechVoiceForLanguage(language.name)),
      subtitle: Text(switch (voice) {
        final voice? => voiceLabel(l10n, voice, listed),
        null => l10n.speechVoiceSystemDefault,
      }),
      trailing: loading
          ? SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                semanticsLabel: l10n.speechVoicesLoading,
              ),
            )
          : const Icon(Icons.chevron_right),
      onTap: loading ? null : () => unawaited(_pick(context)),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final l10n = context.l10n;
    final cubit = context.read<SpeechSettingsCubit>();
    final tag = speechLanguageTag(language.code);
    if (tag == null) return;
    await cubit.loadVoices(language.code);
    if (!context.mounted || cubit.isClosed) return;
    final current = cubit.state.settings.voiceFor(language.code);
    final listed = cubit.state.voices[tag] ?? const <DeviceVoice>[];
    final voices = [
      // Still offered when it is no longer installed, so it stays visible.
      if (current != null && !listed.any((v) => v.id == current.id)) current,
      ...listed,
    ];
    final sample = _sampleText(language);
    // Without any listed voice the device most likely cannot speak the
    // language, so there is nothing to preview.
    Widget? preview(DeviceVoice? voice, String name) => listed.isEmpty
        ? null
        : _VoicePreviewButton(
            language: language,
            voice: voice,
            name: name,
            sample: sample,
          );
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => BlocProvider.value(
        value: cubit,
        child: ChoiceDialog<String>(
          title: l10n.speechVoiceForLanguage(language.name),
          body: listed.isEmpty
              ? l10n.speechVoiceNone(language.name)
              : l10n.speechVoiceDialogBody(language.name),
          initialValue: current?.id ?? _defaultVoice,
          footer: _VoicePreviewStatus(languageTag: tag),
          options: [
            ChoiceDialogOption(
              value: _defaultVoice,
              title: Text(l10n.speechVoiceSystemDefault),
              action: preview(null, l10n.speechVoiceSystemDefault),
            ),
            for (final voice in voices)
              ChoiceDialogOption(
                value: voice.id,
                title: Text(voiceLabel(l10n, voice, listed)),
                subtitle: Text(_voiceDetails(l10n, voice)),
                action: preview(voice, voiceLabel(l10n, voice, listed)),
              ),
          ],
        ),
      ),
    );
    if (cubit.isClosed) return;
    cubit.dismissPreviewError();
    await cubit.stopPreview();
    if (choice == null) return;
    final selected = voices.where((voice) => voice.id == choice).firstOrNull;
    await cubit.setVoice(language.code, selected);
  }

  /// Read when a voice is previewed: the language's own name and a few
  /// numbers, which every voice reads in its language.
  static String _sampleText(Language language) {
    final name =
        language.nativeName ??
        LanguageCatalog.byCode(language.code)?.nativeName ??
        language.name;
    return '$name. 1, 2, 3, 4, 5.';
  }
}

/// The name shown for [voice]: its own name, or, for a technical engine
/// name such as `fr-fr-x-frd-local` ([DeviceVoice.hasEngineName]), "Voice
/// 3" numbered among the [listed] voices of its locale (by variant, e.g.
/// "Voice FRD", while they are not known).
String voiceLabel(
  AppLocalizations l10n,
  DeviceVoice voice,
  Iterable<DeviceVoice>? listed,
) {
  final variant = voice.engineVariant;
  if (variant == null) return voice.name;
  return switch (voice.numberAmong(listed ?? const [])) {
    final number? => l10n.speechVoiceNumbered(number),
    null => l10n.speechVoiceVariant(variant.toUpperCase()),
  };
}

/// The locale and labels shown under a voice, e.g. `fr-CA · High quality`.
String _voiceDetails(AppLocalizations l10n, DeviceVoice voice) => [
  voice.locale,
  if (voice.isHighQuality) l10n.speechVoiceHighQuality,
  if (voice.networkRequired) l10n.speechVoiceNeedsInternet,
].join(' · ');

/// Plays [sample] with [voice] (null: the default voice); stops when that
/// preview is playing.
class _VoicePreviewButton extends StatelessWidget {
  const new({
    required this.language,
    required this.voice,
    required this.name,
    required this.sample,
  });

  final Language language;
  final DeviceVoice? voice;

  /// The voice's name for the tooltip ([voiceLabel]).
  final String name;
  final String sample;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tag = speechLanguageTag(language.code) ?? language.code;
    final id = SpeechSettingsCubit.voicePreviewId(tag, voice);
    final playing = context.select<SpeechSettingsCubit, bool>(
      (cubit) => cubit.state.speakingId == id,
    );
    return IconButton(
      tooltip: playing ? l10n.commonStop : l10n.speechVoicePreview(name),
      isSelected: playing,
      icon: const Icon(Icons.play_circle_outline),
      selectedIcon: const Icon(Icons.stop_circle_outlined),
      onPressed: () => unawaited(
        context.read<SpeechSettingsCubit>().previewVoice(
          languageCode: language.code,
          text: sample,
          voice: voice,
        ),
      ),
    );
  }
}

/// Why the last voice preview of [languageTag] could not be played, under
/// the voice picker's options; announced by screen readers (live region).
class _VoicePreviewStatus extends StatelessWidget {
  const new({required this.languageTag});

  final String languageTag;

  @override
  Widget build(BuildContext context) {
    final failed = context.select<SpeechSettingsCubit, bool>(
      (cubit) => cubit.state.voicePreviewFailed(languageTag),
    );
    if (!failed) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final color = theme.colorScheme.error;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(24, 12, 24, 0),
      child: Semantics(
        container: true,
        liveRegion: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: color, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                context.l10n.speechVoicePreviewError,
                style: theme.textTheme.bodyMedium?.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
