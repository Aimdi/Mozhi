import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

/// The name of a backup section (by `BackupSection.id`) as the user
/// sees it, and its icon. Unknown ids (a newer version's) show as they
/// are.
abstract final class BackupSectionLabels {
  static String name(AppLocalizations l10n, String id) => switch (id) {
    'history' => l10n.backupSectionHistory,
    'presets' => l10n.backupSectionPresets,
    'glossaries' => l10n.backupSectionGlossaries,
    'settings' => l10n.backupSectionSettings,
    'phrasebook' => l10n.backupSectionPhrasebook,
    'practice' => l10n.backupSectionPractice,
    _ => id,
  };

  static IconData icon(String id) => switch (id) {
    'history' => Icons.history,
    'presets' => Icons.tune,
    'glossaries' => Icons.menu_book_outlined,
    'settings' => Icons.settings_outlined,
    'phrasebook' => Icons.bookmarks_outlined,
    'practice' => Icons.school_outlined,
    _ => Icons.inventory_2_outlined,
  };
}
