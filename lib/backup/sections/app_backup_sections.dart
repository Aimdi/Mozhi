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

export 'glossaries_backup_section.dart';
export 'history_backup_section.dart';
export 'presets_backup_section.dart';
export 'settings_backup_section.dart';

/// The app's [BackupRegistry] with the sections of the data it keeps
/// itself: the history (with favourites), presets, glossaries and
/// settings, in that order. Presets and glossaries are read from and
/// written to [preferences], where the app keeps them.
///
/// Features with data of their own register their section with the
/// returned registry (phrasebook, practice...).
BackupRegistry createAppBackupRegistry({
  required SettingsRepository settings,
  required HistoryRepository history,
  required KeyValueStore preferences,
  Future<String> Function()? appVersion,
}) => BackupRegistry(appVersion: appVersion)
  ..register(HistoryBackupSection(history))
  ..register(PresetsBackupSection(PresetsRepository(store: preferences)))
  ..register(GlossariesBackupSection(GlossaryRepository(store: preferences)))
  ..register(SettingsBackupSection(settings));
