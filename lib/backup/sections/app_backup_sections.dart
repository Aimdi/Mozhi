import 'dart:convert';

import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/backup/sections/glossaries_backup_section.dart';
import 'package:mozhi/backup/sections/history_backup_section.dart';
import 'package:mozhi/backup/sections/presets_backup_section.dart';
import 'package:mozhi/backup/sections/settings_backup_section.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/presets/data/glossary_repository.dart';
import 'package:mozhi/presets/data/presets_repository.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';

export 'glossaries_backup_section.dart';
export 'history_backup_section.dart';
export 'presets_backup_section.dart';
export 'settings_backup_section.dart';

/// The app's [BackupRegistry] with the sections of the data it keeps
/// itself: the history (with favourites), presets, glossaries and
/// settings, in that order. Presets and glossaries are read from and
/// written to [preferences], where the app keeps them. Merging history
/// applies the "Delete history automatically" stored in [settings]
/// ([historyMaxAge]).
///
/// Features with data of their own register their section with the
/// returned registry (phrasebook, practice...).
BackupRegistry createAppBackupRegistry({
  required SettingsRepository settings,
  required HistoryRepository history,
  required KeyValueStore preferences,
  Future<String> Function()? appVersion,
}) => BackupRegistry(appVersion: appVersion)
  ..register(
    HistoryBackupSection(history, maxAge: () => historyMaxAge(settings)),
  )
  ..register(PresetsBackupSection(PresetsRepository(store: preferences)))
  ..register(GlossariesBackupSection(GlossaryRepository(store: preferences)))
  ..register(SettingsBackupSection(settings));

/// How long the history keeps non-favourites according to the settings
/// stored by [settings] (`AppSettings.historyRetention`; null: for ever,
/// also when nothing or something unreadable is stored). Reads only the
/// stored settings, none of their secrets.
Future<Duration?> historyMaxAge(SettingsRepository settings) async {
  final raw = await settings.prefs.read(SettingsRepository.settingsKey);
  if (raw == null) return null;
  try {
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic>) return null;
    return AppSettings.fromJson(json).historyRetention.maxAge;
  } on Object {
    return null;
  }
}
