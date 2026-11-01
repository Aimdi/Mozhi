import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/clipboard_service.dart';
import 'package:mozhi/platform/engine_build_text.dart';
import 'package:mozhi/platform/free_space.dart';
import 'package:mozhi/settings/view/widgets/choice_dialog.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart'
    show formatStoredSize;
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:mozhi/voice/cubit/voice_settings_cubit.dart';
import 'package:mozhi/voice/offline/offline_speech.dart';
import 'package:mozhi/voice/speech_input_service.dart';
import 'package:mozhi/voice/widgets/prefer_on_device_speech_tile.dart';
import 'package:mozhi/voice/widgets/voice_model_cancel_button.dart';
import 'package:translation_repository/translation_repository.dart'
    show PrivacyMode;
import 'package:whisper_speech/whisper_speech.dart' show WhisperImportStatus;

/// The display name of speech model [id]: "Fast" (`tiny`), "Better"
/// (`base`), "Better (compact)" (`base-q5_1`), "Best" (`small-q5_1`),
/// "Large" (`large-v3-turbo-q5_0`), "Speech detection" (the voice activity
/// model, `silero-vad`), else the id.
String voiceModelName(AppLocalizations l10n, String id) => switch (id) {
  'tiny' => l10n.voiceModelFast,
  'base' => l10n.voiceModelBetter,
  'base-q5_1' => l10n.voiceModelBetterCompact,
  'small-q5_1' => l10n.voiceModelBest,
  'large-v3-turbo-q5_0' => l10n.voiceModelLarge,
  'silero-vad' => l10n.voiceModelVoiceDetection,
  _ => id,
};

/// What the user is told when a model operation ended ([outcome] of
/// `VoiceSettingsCubit.download`, `downloadVoiceDetection` or `delete`;
/// not a metered network, which asks instead): that the model is ready or
/// was deleted, or why it failed in plain words.
String voiceModelOutcomeMessage(
  AppLocalizations l10n,
  VoiceModelOutcome outcome,
) {
  final name = voiceModelName(l10n, outcome.model);
  final error = outcome.error;
  return switch (outcome.operation) {
    VoiceModelOperation.download when outcome.succeeded =>
      l10n.voiceModelDownloadDone(name),
    VoiceModelOperation.delete when outcome.succeeded =>
      l10n.voiceModelDeleteDone(name),
    VoiceModelOperation.delete => l10n.voiceModelDeleteFailed(name),
    VoiceModelOperation.download => switch ((error?.kind, error?.mirror)) {
      (VoiceModelErrorKind.checksum, final String mirror) =>
        l10n.voiceModelErrorChecksumMirror(name, mirror),
      (VoiceModelErrorKind.checksum, _) => l10n.voiceModelErrorChecksum(name),
      (VoiceModelErrorKind.server, final String mirror) =>
        l10n.voiceModelErrorServerMirror(name, mirror, error?.statusCode ?? 0),
      (VoiceModelErrorKind.server, _) => l10n.voiceModelErrorServer(
        name,
        error?.statusCode ?? 0,
      ),
      (VoiceModelErrorKind.storage, _) => l10n.voiceModelErrorStorage(name),
      (VoiceModelErrorKind.space, _) => switch (error?.space) {
        final space? => l10n.commonNotEnoughSpaceFor(
          name,
          formatStorageSize(l10n, space.requiredBytes),
          formatStorageSize(l10n, space.availableBytes),
        ),
        null => l10n.voiceModelErrorStorage(name),
      },
      (_, final String mirror) => l10n.voiceModelErrorNetworkMirror(
        name,
        mirror,
      ),
      _ => l10n.voiceModelErrorNetwork(name),
    },
  };
}

/// The "Voice input" settings: the recogniser ("System speech
/// recognition" or "Offline (Whisper)"), the offline speech models (Fast
/// and Better: download, delete, the one in use, import from files, links
/// to download them by hand) and "Prefer on-device speech recognition" for
/// the system recogniser.
///
/// Reads the [SpeechInputService] and, where Whisper runs, the
/// [OfflineSpeech] from context; renders nothing without a
/// [SpeechInputService] or speech recognition. [privacyMode] decides what
/// is said about the system recogniser: in [PrivacyMode.offlineOnly] it is
/// never used.
class VoiceInputSettingsSection extends StatelessWidget {
  const new({required this.privacyMode, super.key});

  final PrivacyMode privacyMode;

  @override
  Widget build(BuildContext context) {
    final speech = _maybeRead<SpeechInputService>(context);
    if (speech == null || !speech.isPlatformSupported) {
      return const SizedBox.shrink();
    }
    final offline = _maybeRead<OfflineSpeech>(context);
    return BlocProvider(
      create: (_) {
        final cubit = VoiceSettingsCubit(speechInput: speech, offline: offline);
        unawaited(cubit.load());
        return cubit;
      },
      child: VoiceInputSettingsView(privacyMode: privacyMode, speech: speech),
    );
  }

  static T? _maybeRead<T>(BuildContext context) {
    try {
      return context.read<T>();
    } on ProviderNotFoundException {
      return null;
    }
  }
}

class VoiceInputSettingsView extends StatelessWidget {
  const new({required this.privacyMode, required this.speech, super.key});

  final PrivacyMode privacyMode;
  final SpeechInputService speech;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<VoiceSettingsCubit>().state;
    final offlineOnly = privacyMode == PrivacyMode.offlineOnly;
    final children = <Widget>[
      if (state.offlineSupported) _EngineTile(engine: state.engine),
      if (offlineOnly)
        _Note(
          key: const Key('voice_offline_only_note'),
          text: state.offlineSupported
              ? l10n.voiceEngineOfflineOnlyNote
              : l10n.voiceEngineOfflineOnlyUnavailable,
        ),
      if (state.offlineSupported) ...[
        const _ModelsHeader(),
        for (final model in state.models)
          _ModelTile(
            model: model,
            installed: state.isInstalled(model.id),
            inUse: state.selected == model.id,
            operation: state.pending[model.id],
            progress: state.progress[model.id],
          ),
        if (state.voiceDetection case final detection?
            when state.voiceDetectionMissing ||
                state.pending.containsKey(detection.id))
          _VoiceDetectionTile(
            model: detection,
            downloading: state.pending.containsKey(detection.id),
            progress: state.progress[detection.id],
          ),
        _ImportTile(importing: state.importing),
        _CopyLinksTile(models: [...state.models, ?state.voiceDetection]),
        if (state.engineBuild case final build?)
          _Note(
            key: const Key('voice_engine_build'),
            text: engineBuildText(
              l10n,
              build.variant.name,
              skipped: build.skipped.firstOrNull?.name,
            ),
          ),
      ],
      if (!offlineOnly &&
          state.engine == VoiceInputEngine.system &&
          speech.isOnDeviceSupported)
        PreferOnDeviceSpeechTile.standalone(service: speech),
    ];
    if (children.isEmpty) return const SizedBox.shrink();
    return MultiBlocListener(
      listeners: [
        BlocListener<VoiceSettingsCubit, VoiceSettingsState>(
          listenWhen: (previous, current) =>
              current.outcome != null && current.outcome != previous.outcome,
          listener: (context, state) => _onOutcome(context, state.outcome!),
        ),
        BlocListener<VoiceSettingsCubit, VoiceSettingsState>(
          listenWhen: (previous, current) =>
              current.importOutcome != null &&
              current.importOutcome != previous.importOutcome,
          listener: (context, state) => _showSnackBar(
            context,
            _importMessage(l10n, state.importOutcome!),
          ),
        ),
      ],
      child: SettingsSection(
        title: l10n.voiceSettingsTitle,
        children: children,
      ),
    );
  }

  Future<void> _onOutcome(
    BuildContext context,
    VoiceModelOutcome outcome,
  ) async {
    final l10n = context.l10n;
    final cubit = context.read<VoiceSettingsCubit>();
    final name = voiceModelName(l10n, outcome.model);
    if (outcome.needsMeteredConsent) {
      final detection = cubit.state.voiceDetection;
      final isDetection = detection != null && outcome.model == detection.id;
      final size =
          (isDetection ? detection : cubit.state.model(outcome.model))
              ?.sizeBytes ??
          0;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => _MeteredDialog(
          body: l10n.voiceModelMeteredBody(name, formatStoredSize(l10n, size)),
        ),
      );
      if ((confirmed ?? false) && !cubit.isClosed) {
        await (isDetection
            ? cubit.downloadVoiceDetection(overMeteredNetwork: true)
            : cubit.download(outcome.model, overMeteredNetwork: true));
      }
      return;
    }
    if (!context.mounted) return;
    final message = voiceModelOutcomeMessage(l10n, outcome);
    _showSnackBar(context, message);
  }

  static String _importMessage(
    AppLocalizations l10n,
    VoiceImportOutcome outcome,
  ) {
    if (outcome.failed) return l10n.voiceModelImportFailed;
    if (outcome.models.isEmpty) return l10n.voiceModelImportNothing;
    return [
      for (final MapEntry(key: id, value: status) in outcome.models.entries)
        switch (status) {
          WhisperImportStatus.installed => l10n.voiceModelImportInstalled(
            voiceModelName(l10n, id),
          ),
          WhisperImportStatus.alreadyInstalled =>
            l10n.voiceModelImportAlreadyInstalled(voiceModelName(l10n, id)),
          WhisperImportStatus.checksumMismatch => l10n.voiceModelImportDamaged(
            voiceModelName(l10n, id),
          ),
          WhisperImportStatus.failed => switch (outcome.space) {
            final space? => l10n.commonNotEnoughSpaceFor(
              voiceModelName(l10n, id),
              formatStorageSize(l10n, space.requiredBytes),
              formatStorageSize(l10n, space.availableBytes),
            ),
            null => l10n.voiceModelImportFailed,
          },
        },
    ].join('\n');
  }

  static void _showSnackBar(BuildContext context, String message) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

/// "Speech recognition": system or offline; opens a choice dialog.
class _EngineTile extends StatelessWidget {
  const new({required this.engine});

  final VoiceInputEngine engine;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    String title(VoiceInputEngine engine) => switch (engine) {
      VoiceInputEngine.system => l10n.voiceEngineSystem,
      VoiceInputEngine.whisper => l10n.voiceEngineWhisper,
    };
    String subtitle(VoiceInputEngine engine) => switch (engine) {
      VoiceInputEngine.system => l10n.voiceEngineSystemSubtitle,
      VoiceInputEngine.whisper => l10n.voiceEngineWhisperSubtitle,
    };
    return ListTile(
      key: const Key('voice_engine'),
      leading: const SettingsIcon(Icons.record_voice_over_outlined),
      title: Text(l10n.voiceEngineTitle),
      subtitle: Text(title(engine)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final cubit = context.read<VoiceSettingsCubit>();
        final choice = await showDialog<VoiceInputEngine>(
          context: context,
          builder: (context) => ChoiceDialog<VoiceInputEngine>(
            title: l10n.voiceEngineTitle,
            body: l10n.voiceEngineDialogBody,
            initialValue: engine,
            options: [
              for (final option in VoiceInputEngine.values)
                ChoiceDialogOption(
                  value: option,
                  title: Text(title(option)),
                  subtitle: Text(subtitle(option)),
                ),
            ],
          ),
        );
        if (choice == null || cubit.isClosed) return;
        await cubit.setEngine(choice);
      },
    );
  }
}

/// A short explanation in the section (e.g. what Offline only means here).
class _Note extends StatelessWidget {
  const new({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.shield_outlined,
            size: 20,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppPalette.of(context).secondaryText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModelsHeader extends StatelessWidget {
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
              l10n.voiceModelsTitle,
              style: theme.textTheme.titleSmall,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.voiceModelsDescription,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// One speech model: download (with progress and Cancel), delete, or tap
/// to use it.
class _ModelTile extends StatelessWidget {
  const new({
    required this.model,
    required this.installed,
    required this.inUse,
    required this.operation,
    required this.progress,
  });

  final VoiceModel model;
  final bool installed;
  final bool inUse;
  final VoiceModelOperation? operation;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<VoiceSettingsCubit>();
    final name = voiceModelName(l10n, model.id);
    final description = switch (model.id) {
      'tiny' => l10n.voiceModelFastDescription,
      'base' => l10n.voiceModelBetterDescription,
      'base-q5_1' => l10n.voiceModelBetterCompactDescription,
      'small-q5_1' => l10n.voiceModelBestDescription,
      'large-v3-turbo-q5_0' => l10n.voiceModelLargeDescription,
      _ => '',
    };
    final size = formatStoredSize(l10n, model.sizeBytes);
    final downloading = operation == VoiceModelOperation.download;
    final busy = operation != null;
    final subtitle = downloading
        ? l10n.voiceModelDownloading(((progress ?? 0) * 100).floor())
        : [
            if (description.isNotEmpty)
              l10n.voiceModelSubtitle(description, size)
            else
              size,
            if (inUse) l10n.voiceModelInUse,
          ].join(' · ');
    final Widget trailing;
    if (busy) {
      final ring = SizedBox.square(
        dimension: 48,
        child: Center(
          child: SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: downloading && (progress ?? 0) > 0 ? progress : null,
              semanticsLabel: subtitle,
            ),
          ),
        ),
      );
      // A download can be stopped (and resumed later); a deletion cannot.
      trailing = downloading
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ring,
                VoiceModelCancelButton(
                  model: name,
                  onPressed: () => cubit.cancel(model.id),
                ),
              ],
            )
          : ring;
    } else if (installed) {
      trailing = IconButton(
        key: Key('voice_model_delete_${model.id}'),
        tooltip: l10n.voiceModelDeleteTooltip(name),
        icon: const Icon(Icons.delete_outline),
        onPressed: () => unawaited(_confirmDelete(context, cubit, name)),
      );
    } else {
      trailing = IconButton(
        key: Key('voice_model_download_${model.id}'),
        tooltip: l10n.voiceModelDownloadTooltip(name),
        icon: const Icon(Icons.download_outlined),
        onPressed: () => unawaited(cubit.download(model.id)),
      );
    }
    return Semantics(
      selected: inUse,
      child: ListTile(
        key: Key('voice_model_${model.id}'),
        leading: SettingsIcon(
          inUse ? Icons.check_circle : Icons.graphic_eq,
          color: inUse ? Theme.of(context).colorScheme.primary : null,
        ),
        title: Text(name),
        subtitle: Text(subtitle),
        trailing: trailing,
        onTap: installed && !inUse && !busy
            ? () => unawaited(cubit.select(model.id))
            : null,
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    VoiceSettingsCubit cubit,
    String name,
  ) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.voiceModelDeleteTitle(name)),
        content: Text(l10n.voiceModelDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            key: const Key('voice_model_delete_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if ((confirmed ?? false) && !cubit.isClosed) await cubit.delete(model.id);
  }
}

/// The voice activity model ("Speech detection") when speech models are
/// installed without it (they came before the app had one): what it does,
/// its size and a download button (with progress while it downloads).
class _VoiceDetectionTile extends StatelessWidget {
  const new({
    required this.model,
    required this.downloading,
    required this.progress,
  });

  final VoiceModel model;
  final bool downloading;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final name = l10n.voiceModelVoiceDetection;
    final subtitle = downloading
        ? l10n.voiceModelDownloading(((progress ?? 0) * 100).floor())
        : l10n.voiceModelVoiceDetectionSubtitle(
            formatStoredSize(l10n, model.sizeBytes),
          );
    return ListTile(
      key: const Key('voice_model_voice_detection'),
      leading: const SettingsIcon(Icons.hearing_outlined),
      title: Text(name),
      subtitle: Text(subtitle),
      trailing: downloading
          ? SizedBox.square(
              dimension: 48,
              child: Center(
                child: SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    value: (progress ?? 0) > 0 ? progress : null,
                    semanticsLabel: subtitle,
                  ),
                ),
              ),
            )
          : IconButton(
              key: const Key('voice_model_download_voice_detection'),
              tooltip: l10n.voiceModelDownloadTooltip(name),
              icon: const Icon(Icons.download_outlined),
              onPressed: () => unawaited(
                context.read<VoiceSettingsCubit>().downloadVoiceDetection(),
              ),
            ),
    );
  }
}

/// "Import from files": installs models downloaded by hand, offline.
class _ImportTile extends StatelessWidget {
  const new({required this.importing});

  final bool importing;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListTile(
      key: const Key('voice_model_import'),
      leading: const SettingsIcon(Icons.file_open_outlined),
      title: Text(importing ? l10n.offlineImporting : l10n.offlineImportAction),
      subtitle: Text(l10n.voiceModelImportSubtitle),
      trailing: importing
          ? const SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      onTap: importing
          ? null
          : () =>
                unawaited(context.read<VoiceSettingsCubit>().importFromFiles()),
    );
  }
}

/// Copies the download links of the models (to fetch them elsewhere and
/// import them here).
class _CopyLinksTile extends StatelessWidget {
  const new({required this.models});

  final List<VoiceModel> models;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListTile(
      key: const Key('voice_model_copy_links'),
      leading: const SettingsIcon(Icons.link),
      title: Text(l10n.voiceModelCopyLinks),
      subtitle: Text(l10n.voiceModelCopyLinksSubtitle),
      onTap: () async {
        final messenger = ScaffoldMessenger.maybeOf(context);
        await copyText([for (final model in models) '${model.url}'].join('\n'));
        if (systemShowsCopyConfirmation) return;
        messenger
          ?..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(l10n.commonCopied)));
      },
    );
  }
}

/// Asks whether to download over a metered network.
class _MeteredDialog extends StatelessWidget {
  const new({required this.body});

  final String body;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      icon: const Icon(Icons.signal_cellular_alt),
      title: Text(l10n.offlineMeteredTitle),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: const Key('voice_model_metered_confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.offlineMeteredDownloadAnyway),
        ),
      ],
    );
  }
}
