import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
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

  /// Downloaded offline language models.
  final int offlineModels;
}

/// Deletes everything the app keeps on the device: the history (with its
/// encryption key), the settings and API keys, all other preferences
/// (presets, glossaries, usage counters, cached engine lists) and the
/// offline language models. In-memory state is reset where the app keeps
/// it ([settings] back to the defaults, which starts setup again, the
/// translate screen cleared).
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
    this.translate,
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

    return LocalDataEraser(
      history: context.read<HistoryCubit>(),
      settings: context.read<SettingsCubit>(),
      historyRepository: maybe<HistoryRepository>(),
      settingsRepository: maybe<SettingsRepository>(),
      preferences: maybe<KeyValueStore>(),
      offline: maybe<OfflineTranslator>(),
      translate: maybe<TranslateCubit>(),
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
  final TranslateCubit? translate;

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
    translate?.clear();
    history.search('');
    if (failure case final error?) {
      Error.throwWithStackTrace(error, failureTrace ?? StackTrace.current);
    }
  }

  Future<Set<String>> _downloadedModels() async {
    final offline = this.offline;
    if (offline == null || !offline.isAvailable) return const {};
    try {
      return await offline.downloadedLanguages();
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
