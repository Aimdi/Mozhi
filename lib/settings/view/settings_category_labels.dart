import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/models/settings_category.dart';

/// How a [SettingsCategory] is listed: its title, a one-line summary of
/// what it holds, its icon and, for the AI settings, an "Advanced" badge.
extension SettingsCategoryLabels on SettingsCategory {
  String title(AppLocalizations l10n) => switch (this) {
    SettingsCategory.general => l10n.settingsSectionGeneral,
    SettingsCategory.privacy => l10n.settingsCategoryPrivacy,
    SettingsCategory.engines => l10n.settingsCategoryEngines,
    SettingsCategory.ai => l10n.settingsCategoryAi,
    SettingsCategory.appearance => l10n.settingsSectionAppearance,
    SettingsCategory.speech => l10n.settingsCategorySpeech,
    SettingsCategory.about => l10n.settingsSectionAbout,
  };

  String summary(AppLocalizations l10n) => switch (this) {
    SettingsCategory.general => l10n.settingsCategoryGeneralSummary,
    SettingsCategory.privacy => l10n.settingsCategoryPrivacySummary,
    SettingsCategory.engines => l10n.settingsCategoryEnginesSummary,
    SettingsCategory.ai => l10n.settingsCategoryAiSummary,
    SettingsCategory.appearance => l10n.settingsCategoryAppearanceSummary,
    SettingsCategory.speech => l10n.settingsCategorySpeechSummary,
    SettingsCategory.about => l10n.settingsAboutSubtitle,
  };

  IconData get icon => switch (this) {
    SettingsCategory.general => Icons.tune,
    SettingsCategory.privacy => Icons.shield_outlined,
    SettingsCategory.engines => Icons.translate,
    SettingsCategory.ai => Icons.auto_awesome_outlined,
    SettingsCategory.appearance => Icons.palette_outlined,
    SettingsCategory.speech => Icons.record_voice_over_outlined,
    SettingsCategory.about => Icons.info_outline,
  };

  /// A label shown with the title ("Advanced" for the AI settings).
  String? badge(AppLocalizations l10n) =>
      this == SettingsCategory.ai ? l10n.settingsAdvancedBadge : null;
}
