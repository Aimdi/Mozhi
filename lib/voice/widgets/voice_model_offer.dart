import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart'
    show formatStoredSize;
import 'package:mozhi/settings/view/widgets/voice_input_settings_section.dart'
    show voiceModelName, voiceModelOutcomeMessage;
import 'package:mozhi/voice/cubit/voice_settings_cubit.dart';
import 'package:mozhi/voice/offline/offline_speech.dart';
import 'package:mozhi/voice/speech_input_service.dart';
import 'package:mozhi/voice/speech_input_state.dart';
import 'package:mozhi/voice/widgets/voice_error_message.dart';

/// The app's [OfflineSpeech] (`RepositoryProvider<OfflineSpeech>`) when
/// Whisper runs here; null without one (the web app, unsupported CPUs).
OfflineSpeech? offlineSpeechOf(BuildContext context) {
  final OfflineSpeech offline;
  try {
    offline = context.read<OfflineSpeech>();
  } on ProviderNotFoundException {
    return null;
  }
  return offline.isAvailable ? offline : null;
}

/// Whether [offerVoiceModel] has something to offer for [failure]: the
/// offline speech model would fix it ([voiceInputFailureNeedsOfflineModel])
/// and Whisper runs here ([offline]).
bool canOfferVoiceModel(
  SpeechInputFailure failure, {
  required SpeechInputService service,
  required OfflineSpeech? offline,
}) =>
    offline != null &&
    voiceInputFailureNeedsOfflineModel(
      failure,
      offlineSupported: service.isOfflineSupported,
    );

/// Offers to download the offline speech model right where voice input
/// failed for the lack of it ([canOfferVoiceModel]): a dialog that names
/// the model (the fastest one this device has the memory for, "Fast"),
/// its size and where it comes from, and downloads it with progress on
/// "Download (74 MB)". The download follows the app's rules
/// ([VoiceSettingsCubit.download]): "Download over Wi-Fi only" asks in the
/// dialog before using mobile data, and failures are explained there in
/// plain words (try again). "Other models" opens the voice input settings
/// ([voiceSettingsLocation], with a [GoRouter] above) to pick another or
/// import one; "Continue in background" closes the dialog while the
/// download goes on.
///
/// [failure] chooses the explanation: no speech recognition service on
/// the device ([SpeechInputFailure.recognizerUnavailable]) or Whisper
/// chosen (or required by Offline only) without a model.
///
/// Returns whether a speech model is installed when the dialog closes
/// (the caller can start listening right away).
Future<bool> offerVoiceModel(
  BuildContext context, {
  required SpeechInputService service,
  required OfflineSpeech offline,
  required SpeechInputFailure failure,
}) async {
  final router = GoRouter.maybeOf(context);
  final installed = await showDialog<bool>(
    context: context,
    builder: (context) => BlocProvider(
      create: (_) {
        final cubit = VoiceSettingsCubit(
          speechInput: service,
          offline: offline,
        );
        unawaited(cubit.load());
        return cubit;
      },
      child: VoiceModelOfferDialog(
        failure: failure,
        offline: offline,
        onOtherModels: router == null
            ? null
            : () => unawaited(router.push<void>(voiceSettingsLocation)),
      ),
    ),
  );
  return installed ?? false;
}

/// The dialog of [offerVoiceModel]; reads the [VoiceSettingsCubit] above
/// (loaded). Pops `true` once a speech model is installed, else `false`.
class VoiceModelOfferDialog extends StatefulWidget {
  const new({
    required this.failure,
    required this.offline,
    this.onOtherModels,
    super.key,
  });

  /// Key of the download button.
  static const downloadKey = Key('voice_offer_download');

  /// Key of the progress bar shown while downloading.
  static const progressKey = Key('voice_offer_progress');

  final SpeechInputFailure failure;
  final OfflineSpeech offline;

  /// Opens the voice input settings; null hides "Other models".
  final VoidCallback? onOtherModels;

  @override
  State<VoiceModelOfferDialog> createState() => _VoiceModelOfferDialogState();
}

class _VoiceModelOfferDialogState extends State<VoiceModelOfferDialog> {
  /// The last download was refused on a metered network: the next one
  /// uses it anyway.
  bool _metered = false;
  bool _closed = false;
  bool _wifiOnly = false;

  @override
  void initState() {
    super.initState();
    unawaited(_readWifiOnly());
  }

  Future<void> _readWifiOnly() async {
    final wifiOnly = await widget.offline.wifiOnly();
    if (mounted) setState(() => _wifiOnly = wifiOnly);
  }

  void _close({required bool installed}) {
    if (_closed) return;
    _closed = true;
    Navigator.of(context).pop(installed);
  }

  /// The model offered: the fastest that suits this device.
  VoiceModel? _model(VoiceSettingsState state) => state.models.firstOrNull;

  /// What the download costs: the model and, the first time, the speech
  /// detector that comes with it.
  int _size(VoiceSettingsState state, VoiceModel model) =>
      model.sizeBytes +
      (state.voiceDetectionInstalled
          ? 0
          : state.voiceDetection?.sizeBytes ?? 0);

  void _onState(BuildContext context, VoiceSettingsState state) {
    if (state.status != VoiceSettingsStatus.ready) return;
    // Installed meanwhile (another screen, an import): nothing to offer.
    if (state.installed.isNotEmpty && state.pending.isEmpty) {
      _close(installed: true);
      return;
    }
    final outcome = state.outcome;
    final model = _model(state);
    if (outcome == null || model == null || outcome.model != model.id) return;
    if (outcome.needsMeteredConsent) setState(() => _metered = true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<VoiceSettingsCubit>();
    return BlocConsumer<VoiceSettingsCubit, VoiceSettingsState>(
      listener: _onState,
      builder: (context, state) {
        final model = _model(state);
        final loading =
            state.status != VoiceSettingsStatus.ready || model == null;
        final name = model == null ? '' : voiceModelName(l10n, model.id);
        final size = model == null
            ? ''
            : formatStoredSize(l10n, _size(state, model));
        final downloading =
            model != null && state.pending.containsKey(model.id);
        final progress = model == null ? null : state.progress[model.id];
        final outcome = state.outcome;
        final failed =
            !downloading &&
            outcome != null &&
            outcome.model == model?.id &&
            !outcome.succeeded &&
            !outcome.needsMeteredConsent;
        final metered = _metered && !downloading;
        return AlertDialog(
          icon: const Icon(Icons.mic_none_outlined),
          title: Text(l10n.voiceOfferTitle),
          content: loading
              ? const SizedBox(
                  height: 48,
                  child: Center(child: CircularProgressIndicator()),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.failure == SpeechInputFailure.recognizerUnavailable
                          ? l10n.voiceOfferBodyNoRecognizer(name, size)
                          : l10n.voiceOfferBody(name, size),
                    ),
                    if (metered) ...[
                      const SizedBox(height: 12),
                      Text(
                        l10n.voiceModelMeteredBody(name, size),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ] else if (_wifiOnly && !downloading) ...[
                      const SizedBox(height: 12),
                      Text(
                        l10n.voiceOfferWifiNote,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                    if (downloading) ...[
                      const SizedBox(height: 16),
                      LinearProgressIndicator(
                        key: VoiceModelOfferDialog.progressKey,
                        value: progress,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.voiceModelDownloading(
                          ((progress ?? 0) * 100).floor(),
                        ),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                    if (failed) ...[
                      const SizedBox(height: 12),
                      Text(
                        voiceModelOutcomeMessage(l10n, outcome),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
          actions: [
            if (widget.onOtherModels case final open? when !downloading)
              TextButton(
                onPressed: () {
                  _close(installed: false);
                  open();
                },
                child: Text(l10n.voiceOfferOtherModels),
              ),
            TextButton(
              onPressed: () => _close(installed: false),
              child: Text(
                downloading ? l10n.voiceOfferBackground : l10n.voiceOfferNotNow,
              ),
            ),
            if (!downloading && model != null && !loading)
              FilledButton(
                key: VoiceModelOfferDialog.downloadKey,
                onPressed: () async {
                  final overMetered = _metered;
                  setState(() => _metered = false);
                  await cubit.download(
                    model.id,
                    overMeteredNetwork: overMetered,
                  );
                  if (!mounted || cubit.isClosed) return;
                  final done = cubit.state.outcome;
                  if (done != null &&
                      done.model == model.id &&
                      done.succeeded) {
                    _close(installed: true);
                  }
                },
                child: Text(
                  metered
                      ? l10n.offlineMeteredDownloadAnyway
                      : l10n.voiceOfferDownload(size),
                ),
              ),
          ],
        );
      },
    );
  }
}
