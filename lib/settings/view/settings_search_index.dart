import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app_lock/view/app_lock_settings_tile.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/pairing/view/pairing_entries.dart' show PairingAnchors;
import 'package:mozhi/pairing/view/pairing_unavailable.dart'
    show isPairingSupported;
import 'package:mozhi/screen_translate/view/screen_translate_settings.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/models/settings_category.dart';
import 'package:mozhi/settings/view/about_page.dart';
import 'package:mozhi/settings/view/categories/ai_settings.dart';
import 'package:mozhi/settings/view/categories/appearance_settings.dart';
import 'package:mozhi/settings/view/categories/backup_settings.dart';
import 'package:mozhi/settings/view/categories/engine_settings.dart';
import 'package:mozhi/settings/view/categories/general_settings.dart';
import 'package:mozhi/settings/view/categories/speech_settings.dart';
import 'package:mozhi/settings/view/widgets/model_source_dialog.dart';
import 'package:mozhi/settings/view/widgets/on_device_ai_tile.dart';
import 'package:mozhi/settings/view/widgets/privacy_settings_section.dart';
import 'package:mozhi/settings/view/widgets/settings_search.dart';
import 'package:mozhi/sync/view/sync_settings_section.dart';

/// Every row the settings search finds, in the settings' order: what each
/// category page shows here ([settings], the platform and the services
/// provided), with the texts the rows show.
///
/// Each entry's anchor is a [SettingsAnchor] on its category's page (a
/// test checks that they match).
List<SettingsSearchEntry> settingsSearchIndex(
  BuildContext context,
  AppSettings settings,
) {
  final l10n = context.l10n;
  SettingsSearchEntry entry(
    SettingsCategory category,
    String anchor,
    String title, {
    String? subtitle,
    List<String> keywords = const [],
  }) => SettingsSearchEntry(
    category: category,
    anchor: anchor,
    title: title,
    subtitle: subtitle,
    keywords: keywords,
  );
  const general = SettingsCategory.general;
  const privacy = SettingsCategory.privacy;
  const backup = SettingsCategory.backup;
  const engines = SettingsCategory.engines;
  const ai = SettingsCategory.ai;
  const appearance = SettingsCategory.appearance;
  const speech = SettingsCategory.speech;
  const about = SettingsCategory.about;
  final dynamicColor = AppearanceSettings.dynamicColorAvailable(
    Theme.of(context).platform,
  );
  return [
    entry(
      general,
      GeneralAnchors.appLanguage,
      l10n.settingsAppLanguage,
      subtitle: l10n.settingsAppLanguageSystem,
    ),
    entry(general, GeneralAnchors.tabOrder, l10n.settingsTabOrder),
    if (GeneralSettings.hapticFeedbackSupported)
      entry(
        general,
        GeneralAnchors.hapticFeedback,
        l10n.settingsHapticFeedback,
        subtitle: l10n.settingsHapticFeedbackSubtitle,
      ),
    entry(
      general,
      GeneralAnchors.multilineInput,
      l10n.settingsMultilineInput,
      subtitle: l10n.settingsMultilineInputSubtitle,
    ),
    if (GeneralSettings.offlineAppShellSupported)
      entry(
        general,
        GeneralAnchors.offlineAppShell,
        l10n.settingsOfflineAppShell,
        keywords: [l10n.settingsOfflineAppShellKeywords],
      ),
    // Android integration (ScreenTranslateSettingsSection).
    entry(
      general,
      ScreenTranslateAnchors.translateScreen,
      l10n.settingsScreenTranslate,
      subtitle: ScreenTranslateSettingsSection.supported()
          ? l10n.settingsScreenTranslateSubtitle
          : l10n.settingsScreenTranslateUnavailable,
      keywords: [
        l10n.settingsAndroidIntegration,
        l10n.settingsScreenTranslateKeywords,
      ],
    ),
    if (ScreenTranslateSettingsSection.supported())
      entry(
        general,
        ScreenTranslateAnchors.bubble,
        l10n.settingsScreenTranslateBubble,
        subtitle: l10n.settingsScreenTranslateBubbleSubtitle,
        keywords: [
          l10n.settingsAndroidIntegration,
          l10n.settingsScreenTranslateOverlayTitle,
          l10n.settingsScreenTranslateKeywords,
        ],
      ),
    entry(
      privacy,
      PrivacyAnchors.privacyMode,
      l10n.settingsPrivacyMode,
      keywords: [
        l10n.settingsPrivacyModeOfflineOnly,
        l10n.settingsPrivacyModeOfflineOnlySubtitle,
        l10n.settingsPrivacyModeOfflineFirst,
        l10n.settingsPrivacyModeOfflineFirstSubtitle,
        l10n.settingsPrivacyModeOnline,
        l10n.settingsPrivacyModeOnlineSubtitle,
      ],
    ),
    entry(
      privacy,
      PrivacyAnchors.incognito,
      l10n.settingsIncognito,
      subtitle: l10n.settingsIncognitoSubtitle,
    ),
    if (PrivacySettingsSection.secureScreenSupported)
      entry(
        privacy,
        PrivacyAnchors.secureScreen,
        l10n.settingsSecureScreen,
        subtitle: l10n.settingsSecureScreenSubtitle,
      ),
    entry(
      privacy,
      PrivacyAnchors.appLock,
      l10n.settingsAppLock,
      subtitle: appLockTimeoutLabel(l10n, settings.appLock),
      keywords: [
        l10n.settingsAppLockSearchKeywords,
        for (final timeout in AppLockTimeout.values)
          appLockTimeoutLabel(l10n, timeout),
      ],
    ),
    entry(
      privacy,
      PrivacyAnchors.maskPersonalData,
      l10n.settingsMaskPersonalData,
      subtitle: l10n.settingsMaskPersonalDataSubtitle,
    ),
    entry(
      privacy,
      PrivacyAnchors.saveHistory,
      l10n.settingsSaveHistory,
      subtitle: l10n.settingsSaveHistorySubtitle,
    ),
    entry(
      privacy,
      PrivacyAnchors.historyRetention,
      l10n.settingsHistoryRetention,
      subtitle: historyRetentionLabel(l10n, settings.historyRetention),
      keywords: [
        for (final retention in HistoryRetention.values)
          historyRetentionLabel(l10n, retention),
      ],
    ),
    entry(
      privacy,
      PrivacyAnchors.exportHistory,
      l10n.settingsExportHistory,
      subtitle: l10n.settingsExportHistoryPlainSubtitle,
    ),
    entry(
      privacy,
      PrivacyAnchors.importHistory,
      l10n.settingsImportHistory,
      subtitle: l10n.settingsImportHistorySubtitle,
    ),
    entry(
      privacy,
      PrivacyAnchors.phrasebook,
      l10n.settingsPhrasebook,
      subtitle: l10n.settingsPhrasebookSubtitle,
      keywords: [l10n.phrasebookStarterTitle],
    ),
    entry(
      privacy,
      PrivacyAnchors.practice,
      l10n.practiceTitle,
      subtitle: l10n.practiceSettingsTileSubtitle,
      keywords: [l10n.practiceSearchKeywords],
    ),
    entry(privacy, PrivacyAnchors.recentPairs, l10n.settingsClearRecentPairs),
    entry(privacy, PrivacyAnchors.networkPairs, l10n.settingsNetworkPairs),
    entry(
      privacy,
      PrivacyAnchors.consentedProviders,
      l10n.settingsConsentedProviders,
    ),
    entry(
      privacy,
      PrivacyAnchors.httpProxy,
      l10n.settingsHttpProxy,
      subtitle: settings.httpProxy ?? l10n.settingsHttpProxyOff,
    ),
    entry(
      privacy,
      PrivacyAnchors.networkActivity,
      l10n.settingsNetworkActivity,
      subtitle: l10n.settingsNetworkActivitySubtitle,
    ),
    entry(
      privacy,
      PrivacyAnchors.clearHistory,
      l10n.historyClearMenu,
      subtitle: l10n.settingsClearHistorySubtitle,
    ),
    entry(
      privacy,
      PrivacyAnchors.deleteAllData,
      l10n.settingsDeleteAllData,
      subtitle: l10n.settingsDeleteAllDataSubtitle,
    ),
    entry(
      backup,
      BackupAnchors.backUp,
      l10n.settingsBackupCreate,
      keywords: [
        l10n.settingsCategoryBackup,
        l10n.settingsBackupKeywords,
        l10n.backupIncludeSecrets,
      ],
    ),
    entry(
      backup,
      BackupAnchors.restore,
      l10n.settingsBackupRestore,
      subtitle: l10n.settingsBackupRestoreSubtitle,
      keywords: [l10n.settingsCategoryBackup, l10n.settingsBackupKeywords],
    ),
    if (SyncSettingsSection.serviceOf(context) != null)
      entry(
        backup,
        SyncAnchors.sync,
        l10n.syncTitle,
        subtitle: l10n.syncSetUpSubtitle,
        keywords: [
          l10n.syncSetUp,
          l10n.syncNow,
          l10n.syncWhatToSync,
          l10n.syncWifiOnly,
          l10n.syncChangePassphrase,
          l10n.syncTurnOff,
          ...SyncAnchors.keywords,
        ],
      ),
    if (isPairingSupported) ...[
      entry(
        backup,
        PairingAnchors.receive,
        l10n.pairingReceiveAction,
        subtitle: l10n.pairingReceiveSubtitle,
        keywords: [l10n.pairingSectionTitle],
      ),
      entry(
        backup,
        PairingAnchors.send,
        l10n.pairingSendAction,
        subtitle: l10n.pairingSendSubtitle,
        keywords: [l10n.pairingSectionTitle, l10n.pairingSharePacksAction],
      ),
    ],
    if (EngineSettings.offlineSupported)
      entry(
        engines,
        EngineAnchors.offlineLanguages,
        l10n.settingsOfflineManage,
        subtitle: l10n.settingsOfflineSubtitle,
        keywords: [l10n.offlineTitle],
      )
    else
      entry(
        engines,
        EngineAnchors.offlineLanguages,
        l10n.offlineTitle,
        subtitle: l10n.settingsOfflineUnavailableSubtitle,
      ),
    if (onDeviceAiOffered(context))
      entry(
        engines,
        EngineAnchors.onDeviceAi,
        l10n.settingsOnDeviceAi,
        subtitle: l10n.settingsOnDeviceAiSubtitle,
        keywords: [l10n.settingsOnDeviceAiKeywords],
      ),
    entry(
      engines,
      EngineAnchors.modelSource,
      l10n.settingsModelSource,
      subtitle: modelSourceSummary(l10n, settings.modelSource),
      keywords: [
        l10n.settingsModelSourceDefault,
        l10n.settingsModelSourceCustom,
        l10n.settingsModelSourceUrlLabel,
      ],
    ),
    entry(engines, EngineAnchors.instances, l10n.settingsInstancesTitle),
    entry(engines, EngineAnchors.services, l10n.settingsMtServicesTitle),
    entry(
      engines,
      EngineAnchors.quality,
      l10n.settingsQualityTitle,
      subtitle: l10n.settingsQualitySubtitle,
    ),
    entry(
      engines,
      EngineAnchors.rememberQuality,
      l10n.settingsRememberQuality,
      subtitle: l10n.settingsRememberQualitySubtitle,
    ),
    entry(
      engines,
      EngineAnchors.instantTranslate,
      l10n.settingsInstantTranslate,
      subtitle: InstantTranslateChoice.of(settings).title(l10n),
      keywords: [
        l10n.settingsInstantTranslateDialogBody,
        l10n.settingsInstantEnginesAndAi,
      ],
    ),
    entry(
      ai,
      AiAnchors.onDeviceAi,
      l10n.settingsOnDeviceAi,
      subtitle: onDeviceAiOffered(context)
          ? l10n.settingsOnDeviceAiSubtitle
          : l10n.settingsOnDeviceAiUnavailable,
      keywords: [l10n.settingsOnDeviceAiKeywords],
    ),
    entry(ai, AiAnchors.providers, l10n.settingsProvidersTitle),
    entry(ai, AiAnchors.assistant, l10n.settingsAssistEngine),
    entry(
      ai,
      AiAnchors.presets,
      l10n.presetsTitle,
      subtitle: l10n.settingsPresetsSubtitle,
    ),
    entry(
      ai,
      AiAnchors.glossaries,
      l10n.glossariesTitle,
      subtitle: l10n.settingsGlossariesSubtitleAllEngines,
    ),
    entry(
      ai,
      AiAnchors.usage,
      l10n.settingsUsageTitle,
      subtitle: l10n.settingsUsageSubtitle,
    ),
    entry(
      appearance,
      AppearanceAnchors.theme,
      l10n.settingsTheme,
      keywords: [
        l10n.settingsThemeSystem,
        l10n.settingsThemeLight,
        l10n.settingsThemeDark,
      ],
    ),
    if (dynamicColor)
      entry(
        appearance,
        AppearanceAnchors.dynamicColor,
        l10n.settingsDynamicColor,
        subtitle: l10n.settingsDynamicColorSubtitle,
      ),
    entry(
      appearance,
      AppearanceAnchors.darkLook,
      l10n.settingsDarkLook,
      subtitle: l10n.settingsDarkLookSubtitle,
      keywords: [l10n.settingsDarkLookDim, l10n.settingsDarkLookLightsOut],
    ),
    entry(
      appearance,
      AppearanceAnchors.transliteration,
      l10n.settingsShowTransliteration,
      subtitle: l10n.settingsShowTransliterationSubtitle,
    ),
    entry(
      appearance,
      AppearanceAnchors.tapToLookUp,
      l10n.settingsTapToLookUp,
      subtitle: l10n.settingsTapToLookUpSubtitle,
    ),
    entry(
      appearance,
      AppearanceAnchors.highlightSpokenWord,
      l10n.settingsHighlightSpokenWord,
      subtitle: l10n.settingsHighlightSpokenWordSubtitle,
    ),
    if (!dynamicColor || !settings.dynamicColor)
      entry(
        appearance,
        AppearanceAnchors.accentColor,
        l10n.settingsAccentColor,
      ),
    if (SpeechCategorySettings.readAloudAvailable(context))
      entry(
        speech,
        SpeechAnchors.readAloud,
        l10n.speechSettingsTitle,
        keywords: [
          l10n.speechRate,
          l10n.speechRateSubtitle,
          l10n.speechDeviceVoiceOnly,
          l10n.speechVoicesTitle,
        ],
      ),
    if (SpeechCategorySettings.voiceInputAvailable(context))
      entry(
        speech,
        SpeechAnchors.voiceInput,
        l10n.voiceSettingsTitle,
        keywords: [l10n.voiceEngineTitle, l10n.voicePreferOnDeviceTitle],
      ),
    entry(
      about,
      AboutAnchors.version,
      l10n.settingsAbout,
      subtitle: l10n.settingsAboutSubtitle,
      keywords: [l10n.settingsVersion],
    ),
    entry(
      about,
      AboutAnchors.privacy,
      l10n.settingsAboutPrivacyTitle,
      keywords: [
        l10n.settingsAboutPrivacyTelemetry,
        l10n.settingsAboutPrivacyHistory,
        l10n.settingsAboutPrivacyServices,
      ],
    ),
    entry(about, AboutAnchors.sourceCode, l10n.settingsAboutSource),
    entry(
      about,
      AboutAnchors.mozhiProject,
      l10n.settingsAboutMozhiProject,
      subtitle: l10n.settingsAboutMozhiProjectSubtitle,
    ),
    entry(
      about,
      AboutAnchors.licenses,
      l10n.settingsAboutLicenses,
      subtitle: l10n.settingsAboutLicensesSubtitle,
    ),
    entry(
      about,
      AboutAnchors.runSetup,
      l10n.settingsRunSetup,
      subtitle: l10n.settingsRunSetupSteps,
    ),
  ];
}
