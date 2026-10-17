import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/mlkit_bindings.dart'
    show createTextRecognitionService;
import 'package:mozhi/platform/offline_engine.dart'
    show deleteOfflineModelFiles;
import 'package:mozhi/platform/text_recognition.dart' as text_recognition;
import 'package:mozhi/presets/cubit/glossary_cubit.dart';
import 'package:mozhi/presets/cubit/presets_cubit.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:mozhi/voice/offline/offline_speech.dart';
import 'package:mozhi/voice/speech_input_service.dart';
import 'package:translation_repository/translation_repository.dart';

/// What "Delete all local data" deletes, for the confirmation.
@immutable
class LocalDataSummary {
  const new({
    required this.historyEntries,
    required this.apiKeys,
    this.historyLength,
    this.offlineModels = 0,
  });

  /// Translations in the history.
  final int historyEntries;

  /// Stored length of the history (UTF-16 code units), when known.
  final int? historyLength;

  /// Saved API keys.
  final int apiKeys;

  /// Downloaded offline languages (not counting built-in English).
  final int offlineModels;
}

/// Deletes everything the app keeps on the device: the history (with its
/// encryption key), the settings and their secrets (API keys, custom
/// headers, instance passwords), all other preferences (presets,
/// glossaries, usage counters, speech settings, cached engine lists) and
/// the offline language models with the whole models folder
/// ([deleteOfflineFiles]: partial downloads too), the offline speech
/// models ([offlineSpeech]) and the text recognition data
/// ([textRecognition], then its folder with [deleteTextRecognitionFiles]).
///
/// What the app keeps in memory is reset too, so that nothing deleted is
/// shown or written back before the next start: [settings] go back to the
/// defaults (which starts setup again), [presets], [glossaries] and
/// [usage] are read again from the emptied store, [speech] and
/// [speechInput] forget their settings and cached clips, the
/// [translationRepository]'s translation cache is emptied and the
/// translate screen is cleared. Screens other than the shell's are closed
/// when setup starts.
///
/// Only [history] and [settings] are required; the others are skipped when
/// null. [LocalDataEraser.of] takes them from the widget tree.
class LocalDataEraser {
  const new({
    required this.history,
    required this.settings,
    this.historyRepository,
    this.settingsRepository,
    this.preferences,
    this.offline,
    this.deleteOfflineFiles,
    this.translate,
    this.translationRepository,
    this.presets,
    this.glossaries,
    this.usage,
    this.speech,
    this.speechInput,
    this.offlineSpeech,
    this.textRecognition,
    this.deleteTextRecognitionFiles,
  });

  /// Uses what the app provides above [context].
  factory of(BuildContext context) {
    T? maybe<T>() {
      try {
        return context.read<T>();
      } on ProviderNotFoundException {
        return null;
      }
    }

    final offline = maybe<OfflineTranslator>();
    // Tesseract's downloadable data in the default build (ML Kit in the Play
    // variant has none). Creating the recognizer loads nothing.
    final ocr = textRecognitionLanguageDataOf(createTextRecognitionService());
    final hasOcrData = ocr?.isSupported ?? false;
    return LocalDataEraser(
      history: context.read<HistoryCubit>(),
      settings: context.read<SettingsCubit>(),
      historyRepository: maybe<HistoryRepository>(),
      settingsRepository: maybe<SettingsRepository>(),
      preferences: maybe<KeyValueStore>(),
      offline: offline,
      // Only where the engine runs: nothing else ever stores models.
      deleteOfflineFiles: (offline?.isAvailable ?? false)
          ? deleteOfflineModelFiles
          : null,
      translate: maybe<TranslateCubit>(),
      translationRepository: maybe<TranslationRepository>(),
      presets: maybe<PresetsCubit>(),
      glossaries: maybe<GlossaryCubit>(),
      usage: maybe<UsageTracker>(),
      speech: maybe<SpeechService>(),
      speechInput: maybe<SpeechInputService>(),
      offlineSpeech: maybe<OfflineSpeech>(),
      textRecognition: hasOcrData ? ocr : null,
      deleteTextRecognitionFiles: hasOcrData
          ? text_recognition.deleteTextRecognitionFiles
          : null,
    );
  }

  final HistoryCubit history;
  final SettingsCubit settings;
  final HistoryRepository? historyRepository;
  final SettingsRepository? settingsRepository;

  /// The app's plain preferences; cleared entirely when they are a
  /// [ClearableKeyValueStore].
  final KeyValueStore? preferences;
  final OfflineTranslator? offline;

  /// Deletes the offline models folder (see `deleteOfflineModelFiles`),
  /// after the languages were deleted through [offline].
  final Future<void> Function()? deleteOfflineFiles;
  final TranslateCubit? translate;
  final TranslationRepository? translationRepository;
  final PresetsCubit? presets;
  final GlossaryCubit? glossaries;
  final UsageTracker? usage;
  final SpeechService? speech;
  final SpeechInputService? speechInput;

  /// The offline speech models (Whisper), deleted with the offline
  /// languages.
  final OfflineSpeech? offlineSpeech;

  /// The text recognition language data (Tesseract), deleted language by
  /// language so that open screens update.
  final TextRecognitionLanguageData? textRecognition;

  /// Deletes the text recognition folder afterwards (see
  /// `deleteTextRecognitionFiles`): partial downloads too.
  final Future<void> Function()? deleteTextRecognitionFiles;

  /// What [erase] deletes. Never throws: what cannot be found out is left
  /// out (sizes) or counted as nothing.
  Future<LocalDataSummary> summarize() async {
    int? historyLength;
    try {
      historyLength = await historyRepository?.storedLength();
    } on Object {
      historyLength = null;
    }
    return LocalDataSummary(
      historyEntries: history.state.entries.length,
      historyLength: historyLength,
      apiKeys: settings.state.providers
          .where((p) => p.apiKey?.isNotEmpty ?? false)
          .length,
      offlineModels: (await _downloadedModels()).length,
    );
  }

  /// Deletes everything (see the class docs). Every part is attempted;
  /// the first error is rethrown at the end.
  Future<void> erase() async {
    Object? failure;
    StackTrace? failureTrace;
    Future<void> attempt(Future<void> Function() step) async {
      try {
        await step();
      } on Object catch (error, stackTrace) {
        failure ??= error;
        failureTrace ??= stackTrace;
      }
    }

    await attempt(history.deleteAll);
    for (final code in await _downloadedModels()) {
      await attempt(() => offline!.deleteLanguage(code));
    }
    if (deleteOfflineFiles case final deleteFiles?) await attempt(deleteFiles);
    if (offlineSpeech case final speech?) await attempt(speech.deleteAll);
    if (textRecognition case final ocr?) {
      await attempt(() async {
        for (final code in (await ocr.installedOcrLanguages()).keys) {
          await ocr.deleteOcrLanguage(code);
        }
      });
    }
    if (deleteTextRecognitionFiles case final deleteFiles?) {
      await attempt(deleteFiles);
    }
    // Back to the defaults (setup starts again): saving them also deletes
    // the API keys of every provider.
    settings.update((_) => const AppSettings());
    final repository = settingsRepository;
    if (repository != null) {
      await attempt(() => repository.save(const AppSettings()));
    }
    final preferences = this.preferences;
    if (preferences is ClearableKeyValueStore) {
      await attempt(preferences.clear);
    }
    // In-memory copies: read again from the emptied store or forgotten, so
    // that the next change does not write the deleted data back.
    await presets?.load();
    await glossaries?.load();
    if (usage case final usage?) await attempt(usage.load);
    if (speech case final speech?) await attempt(speech.forgetLocalData);
    speechInput?.forgetSettings();
    translationRepository
      ?..clearCache()
      ..resetActiveInstance();
    translate?.clear();
    history.search('');
    if (failure case final error?) {
      Error.throwWithStackTrace(error, failureTrace ?? StackTrace.current);
    }
  }

  /// Languages with downloaded models: English, which every offline model
  /// translates from or into, needs no download and is left out.
  Future<Set<String>> _downloadedModels() async {
    final offline = this.offline;
    if (offline == null || !offline.isAvailable) return const {};
    try {
      return {...await offline.downloadedLanguages()}..remove('en');
    } on Object {
      return const {};
    }
  }
}

/// "12 KB" / "1.4 MB" for [length] bytes, in the locale of [l10n].
String formatStoredSize(AppLocalizations l10n, int length) {
  if (length < 1024) {
    return l10n.commonSizeBytes(
      NumberFormat.decimalPattern(l10n.localeName).format(length),
    );
  }
  if (length < 1024 * 1024) {
    return l10n.commonSizeKilobytes(
      NumberFormat.decimalPattern(l10n.localeName)
          .format((length / 1024).round()),
    );
  }
  return l10n.commonSizeMegabytes(
    NumberFormat('0.0', l10n.localeName).format(length / (1024 * 1024)),
  );
}

/// Asks for confirmation (listing what goes) and deletes all local data
/// with [eraser] (default: [LocalDataEraser.of]), then starts setup again.
Future<void> confirmDeleteLocalData(
  BuildContext context, {
  LocalDataEraser? eraser,
}) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final router = GoRouter.maybeOf(context);
  final eraseWith = eraser ?? LocalDataEraser.of(context);
  final summary = await eraseWith.summarize();
  if (!context.mounted) return;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => DeleteLocalDataDialog(summary: summary),
  );
  if (confirmed != true) return;
  try {
    await eraseWith.erase();
  } on Object {
    messenger?.showSnackBar(
      SnackBar(content: Text(l10n.settingsDeleteAllDataFailed)),
    );
    return;
  }
  messenger?.showSnackBar(
    SnackBar(content: Text(l10n.settingsDeleteAllDataDone)),
  );
  router?.go(AppRoutes.onboarding);
}

/// Lists what "Delete all local data" deletes; pops true to delete.
class DeleteLocalDataDialog extends StatelessWidget {
  const new({required this.summary, super.key});

  final LocalDataSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final historyLength = summary.historyLength;
    final items = [
      (
        Icons.history,
        historyLength == null || historyLength == 0
            ? l10n.settingsDeleteAllDataHistory(summary.historyEntries)
            : l10n.settingsDeleteAllDataHistorySize(
                summary.historyEntries,
                formatStoredSize(l10n, historyLength),
              ),
      ),
      (Icons.tune, l10n.settingsDeleteAllDataSettings),
      (Icons.key_outlined, l10n.settingsDeleteAllDataKeys(summary.apiKeys)),
      if (summary.offlineModels > 0)
        (
          Icons.download_for_offline_outlined,
          l10n.settingsDeleteAllDataModels(summary.offlineModels),
        ),
    ];
    return AlertDialog(
      icon: Icon(Icons.delete_forever_outlined, color: colors.error),
      title: Text(l10n.settingsDeleteAllDataTitle),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.settingsDeleteAllDataBody),
          const SizedBox(height: 12),
          for (final (icon, label) in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(
                    child: Icon(icon, size: 20, color: colors.onSurfaceVariant),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(label)),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Text(
            l10n.settingsDeleteAllDataIrreversible,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          key: const Key('settings_delete_all_confirm'),
          style: TextButton.styleFrom(foregroundColor: colors.error),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.settingsDeleteAllDataAction),
        ),
      ],
    );
  }
}
