import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/undo_snack_bar.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/view/widgets/clear_history_dialog.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/accent_color_picker.dart';
import 'package:mozhi/settings/view/widgets/choice_dialog.dart';
import 'package:mozhi/settings/view/widgets/history_data_actions.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:mozhi/settings/view/widgets/speech_settings_section.dart';
import 'package:mozhi/speech/speech_service.dart';

/// App settings. Reads [SettingsCubit] (and `HistoryCubit` for the data
/// actions) from the app-wide providers.
class SettingsPage extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) => const SettingsView();
}

class SettingsView extends StatelessWidget {
  const new({super.key});

  /// Width from which the sections are laid out in two columns.
  static const twoPaneBreakpoint = 840.0;

  /// Whether on-device (ML Kit) offline translation exists on this platform.
  static bool get offlineSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsCubit>().state;
    final primary = [
      _ServicesSection(settings: settings),
      _TranslationSection(settings: settings),
      if (_hasSpeechService(context))
        SpeechSettingsSection(
          languages: [
            settings.target,
            settings.source,
            ...settings.recentLanguages,
          ],
        ),
    ];
    final secondary = [
      _AppearanceSection(settings: settings),
      _DataSection(settings: settings),
      const _AboutSection(),
    ];
    // Each column is its own focus traversal group and semantics container,
    // so keyboard and screen-reader order finish the left column before
    // moving to the right one instead of zig-zagging between them.
    Widget column(List<Widget> children) => Semantics(
      container: true,
      explicitChildNodes: true,
      child: FocusTraversalGroup(child: Column(children: children)),
    );
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.settingsTitle)),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          if (width >= twoPaneBreakpoint) {
            return SingleChildScrollView(
              padding: centeredPadding(width, maxWidth: 1200),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: column(primary)),
                  const SizedBox(width: 24),
                  Expanded(child: column(secondary)),
                ],
              ),
            );
          }
          return ListView(
            padding: centeredPadding(width),
            children: [...primary, ...secondary],
          );
        },
      ),
    );
  }
}

/// Whether a [SpeechService] is provided (the read-aloud settings need it).
bool _hasSpeechService(BuildContext context) {
  try {
    context.read<SpeechService>();
    return true;
  } on ProviderNotFoundException {
    return false;
  }
}

class _ServicesSection extends StatelessWidget {
  const new({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final instances = settings.instances;
    final providers = settings.providers;
    final enabled = providers.where((p) => p.enabled).length;
    return SettingsSection(
      title: l10n.settingsSectionServices,
      children: [
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: Text(l10n.settingsInstancesTitle),
          subtitle: Text(
            instances.isEmpty
                ? l10n.settingsInstancesNone
                : l10n.settingsInstancesSummary(
                    _host(instances.first.url),
                    instances.length,
                  ),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/settings/instances'),
        ),
        ListTile(
          leading: const Icon(Icons.auto_awesome_outlined),
          title: Text(l10n.settingsProvidersTitle),
          subtitle: Text(
            providers.isEmpty
                ? l10n.settingsProvidersNone
                : l10n.settingsProvidersSummary(enabled, providers.length),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/settings/providers'),
        ),
        if (SettingsView.offlineSupported)
          ListTile(
            leading: const Icon(Icons.download_for_offline_outlined),
            title: Text(l10n.offlineTitle),
            subtitle: Text(l10n.settingsOfflineSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/offline'),
          ),
        ListTile(
          leading: const Icon(Icons.insights_outlined),
          title: Text(l10n.settingsUsageTitle),
          subtitle: Text(l10n.settingsUsageSubtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/settings/usage'),
        ),
      ],
    );
  }

  static String _host(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isEmpty ? url : host;
  }
}

class _TranslationSection extends StatelessWidget {
  const new({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<SettingsCubit>();
    return SettingsSection(
      title: l10n.settingsSectionTranslation,
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.bolt_outlined),
          title: Text(l10n.settingsInstantTranslate),
          subtitle: Text(l10n.settingsInstantTranslateSubtitle),
          value: settings.instantTranslate,
          onChanged: (value) => cubit.setInstantTranslate(enabled: value),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.electric_bolt_outlined),
          title: Text(l10n.settingsInstantTranslateAi),
          subtitle: Text(l10n.settingsInstantTranslateAiSubtitle),
          value: settings.instantTranslateAi,
          onChanged: (value) => cubit.setInstantTranslateAi(enabled: value),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.history),
          title: Text(l10n.settingsSaveHistory),
          subtitle: Text(l10n.settingsSaveHistorySubtitle),
          value: settings.saveHistory,
          onChanged: (value) => cubit.setSaveHistory(enabled: value),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.abc),
          title: Text(l10n.settingsShowTransliteration),
          subtitle: Text(l10n.settingsShowTransliterationSubtitle),
          value: settings.showTransliteration,
          onChanged: (value) => cubit.setShowTransliteration(enabled: value),
        ),
        _AssistEngineTile(settings: settings),
        ListTile(
          leading: const Icon(Icons.speed_outlined),
          title: Text(l10n.settingsQualityTitle),
          subtitle: Text(l10n.settingsQualitySubtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/settings/quality'),
        ),
        ListTile(
          leading: const Icon(Icons.tune),
          title: Text(l10n.presetsTitle),
          subtitle: Text(l10n.settingsPresetsSubtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/settings/presets'),
        ),
        ListTile(
          leading: const Icon(Icons.menu_book_outlined),
          title: Text(l10n.glossariesTitle),
          subtitle: Text(l10n.settingsGlossariesSubtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/settings/glossaries'),
        ),
      ],
    );
  }
}

class _AssistEngineTile extends StatelessWidget {
  const new({required this.settings});

  final AppSettings settings;

  static const _automatic = '';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final current = settings.assistEngineId;
    final selected = settings.providers
        .where((p) => 'ai:${p.id}' == current)
        .firstOrNull;
    final hasProviders = settings.providers.isNotEmpty;
    return ListTile(
      leading: const Icon(Icons.lightbulb_outline),
      title: Text(l10n.settingsAssistEngine),
      subtitle: Text(
        !hasProviders
            ? l10n.settingsAssistEngineNone
            : selected?.name ?? l10n.settingsAssistEngineAutomatic,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: hasProviders
          ? () => _pick(context)
          : () => context.push('/settings/providers'),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final l10n = context.l10n;
    final cubit = context.read<SettingsCubit>();
    final current = settings.assistEngineId ?? _automatic;
    final providers = settings.providers
        .where((p) => p.enabled || 'ai:${p.id}' == current)
        .toList();
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => ChoiceDialog<String>(
        title: l10n.settingsAssistEngine,
        body: l10n.settingsAssistEngineDialogBody,
        initialValue: current,
        options: [
          ChoiceDialogOption(
            value: _automatic,
            title: Text(l10n.settingsAssistEngineAutomatic),
            subtitle: Text(l10n.settingsAssistEngineAutomaticSubtitle),
          ),
          for (final provider in providers)
            ChoiceDialogOption(
              value: 'ai:${provider.id}',
              title: Text(provider.name),
              subtitle: Text(provider.model),
            ),
        ],
      ),
    );
    if (choice == null || choice == current) return;
    cubit.setAssistEngine(choice == _automatic ? null : choice);
  }
}

class _AppearanceSection extends StatelessWidget {
  const new({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<SettingsCubit>();
    final platform = Theme.of(context).platform;
    final dynamicColorAvailable = !kIsWeb && platform != TargetPlatform.iOS;
    final showAccent = !dynamicColorAvailable || !settings.dynamicColor;
    return SettingsSection(
      title: l10n.settingsSectionAppearance,
      children: [
        _ThemeModePicker(
          value: settings.themeMode,
          onChanged: cubit.setThemeMode,
        ),
        if (dynamicColorAvailable)
          SwitchListTile(
            secondary: const Icon(Icons.wallpaper_outlined),
            title: Text(l10n.settingsDynamicColor),
            subtitle: Text(l10n.settingsDynamicColorSubtitle),
            value: settings.dynamicColor,
            onChanged: (value) => cubit.setDynamicColor(enabled: value),
          ),
        SwitchListTile(
          secondary: const Icon(Icons.contrast),
          title: Text(l10n.settingsPureBlack),
          subtitle: Text(l10n.settingsPureBlackSubtitle),
          value: settings.pureBlack,
          onChanged: settings.themeMode == ThemeMode.light
              ? null
              : (value) => cubit.setPureBlack(enabled: value),
        ),
        if (showAccent)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Text(
                    l10n.settingsAccentColor,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
                const SizedBox(height: 8),
                Semantics(
                  container: true,
                  explicitChildNodes: true,
                  label: l10n.settingsAccentColor,
                  child: AccentColorPicker(
                    selected: settings.seedColor,
                    onSelected: cubit.setSeedColor,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Theme mode choice: a segmented button, or radio rows when large text
/// would truncate the segment labels (WCAG 1.4.4).
class _ThemeModePicker extends StatelessWidget {
  const new({required this.value, required this.onChanged});

  /// Text scale above which the three segments no longer fit.
  static const largeTextScale = 1.3;

  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final options = [
      (
        ThemeMode.system,
        Icons.brightness_auto_outlined,
        l10n.settingsThemeSystem,
      ),
      (ThemeMode.light, Icons.light_mode_outlined, l10n.settingsThemeLight),
      (ThemeMode.dark, Icons.dark_mode_outlined, l10n.settingsThemeDark),
    ];
    // The visible title names the group below (WCAG 1.3.1, 4.1.2), so it
    // is read once, as the group's label.
    final title = ExcludeSemantics(
      child: Text(
        l10n.settingsTheme,
        style: Theme.of(context).textTheme.bodyLarge,
      ),
    );
    final largeText =
        MediaQuery.textScalerOf(context).scale(1) > largeTextScale;
    if (largeText) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: title,
            ),
            Semantics(
              container: true,
              explicitChildNodes: true,
              label: l10n.settingsTheme,
              child: RadioGroup<ThemeMode>(
                groupValue: value,
                onChanged: (mode) {
                  if (mode != null) onChanged(mode);
                },
                child: Column(
                  children: [
                    for (final (mode, icon, label) in options)
                      RadioListTile<ThemeMode>(
                        value: mode,
                        title: Text(label),
                        secondary: Icon(icon),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          title,
          const SizedBox(height: 12),
          Semantics(
            container: true,
            explicitChildNodes: true,
            label: l10n.settingsTheme,
            child: SegmentedButton<ThemeMode>(
              segments: [
                for (final (mode, icon, label) in options)
                  ButtonSegment(
                    value: mode,
                    icon: Icon(icon),
                    label: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              selected: {value},
              onSelectionChanged: (selection) => onChanged(selection.first),
            ),
          ),
        ],
      ),
    );
  }
}

class _DataSection extends StatelessWidget {
  const new({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final error = Theme.of(context).colorScheme.error;
    final pairs = settings.recentPairs.length;
    return SettingsSection(
      title: l10n.settingsSectionData,
      children: [
        ListTile(
          leading: const Icon(Icons.auto_delete_outlined),
          title: Text(l10n.settingsHistoryRetention),
          subtitle: Text(
            historyRetentionLabel(l10n, settings.historyRetention),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _pickRetention(context),
        ),
        ListTile(
          leading: const Icon(Icons.upload_outlined),
          title: Text(l10n.settingsExportHistory),
          subtitle: Text(l10n.settingsExportHistorySubtitle),
          onTap: () => showExportHistorySheet(context),
        ),
        ListTile(
          leading: const Icon(Icons.download_outlined),
          title: Text(l10n.settingsImportHistory),
          subtitle: Text(l10n.settingsImportHistorySubtitle),
          onTap: () => showImportHistoryDialog(context),
        ),
        ListTile(
          leading: const Icon(Icons.swap_horiz),
          title: Text(l10n.settingsClearRecentPairs),
          subtitle: Text(l10n.settingsRecentPairsSummary(pairs)),
          enabled: pairs > 0,
          onTap: () => _clearRecentPairs(context),
        ),
        ListTile(
          leading: Icon(Icons.delete_sweep_outlined, color: error),
          title: Text(l10n.historyClearMenu, style: TextStyle(color: error)),
          subtitle: Text(l10n.settingsClearHistorySubtitle),
          onTap: () => confirmClearHistory(context),
        ),
      ],
    );
  }

  Future<void> _pickRetention(BuildContext context) async {
    final l10n = context.l10n;
    final cubit = context.read<SettingsCubit>();
    final current = settings.historyRetention;
    final choice = await showDialog<HistoryRetention>(
      context: context,
      builder: (context) => ChoiceDialog<HistoryRetention>(
        title: l10n.settingsHistoryRetention,
        body: l10n.settingsHistoryRetentionDialogBody,
        initialValue: current,
        options: [
          for (final retention in HistoryRetention.values)
            ChoiceDialogOption(
              value: retention,
              title: Text(historyRetentionLabel(l10n, retention)),
            ),
        ],
      ),
    );
    if (choice == null || choice == current || !context.mounted) return;
    if (!await _confirmRetention(context, choice)) return;
    cubit.setHistoryRetention(choice);
  }

  /// Asks before a [retention] that deletes existing translations right
  /// away (e.g. "Never" -> "After 1 day"); true when nothing would be
  /// deleted or the user confirmed.
  static Future<bool> _confirmRetention(
    BuildContext context,
    HistoryRetention retention,
  ) async {
    final maxAge = retention.maxAge;
    if (maxAge == null) return true;
    final expired = context.read<HistoryCubit>().state.expiredCount(
      maxAge,
      now: DateTime.now(),
    );
    if (expired == 0) return true;
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final colors = Theme.of(context).colorScheme;
        return AlertDialog(
          icon: const Icon(Icons.auto_delete_outlined),
          title: Text(l10n.settingsHistoryRetentionConfirmTitle),
          content: Text(
            l10n.settingsHistoryRetentionConfirmBody(expired, maxAge.inDays),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.commonCancel),
            ),
            TextButton(
              key: const Key('settings_history_retention_confirm'),
              style: TextButton.styleFrom(foregroundColor: colors.error),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.commonDelete),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }

  void _clearRecentPairs(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<SettingsCubit>();
    final previous = cubit.state.recentPairs;
    cubit.clearRecentPairs();
    showUndoSnackBar(
      context,
      message: l10n.settingsRecentPairsCleared,
      onUndo: () => cubit.update(
        (current) => current.copyWith(
          recentPairs: List.unmodifiable(
            [
              ...current.recentPairs,
              ...previous.where((p) => !current.recentPairs.contains(p)),
            ].take(SettingsCubit.maxRecentPairs),
          ),
        ),
      ),
    );
  }
}

/// "Never" / "After N days" for [retention].
String historyRetentionLabel(
  AppLocalizations l10n,
  HistoryRetention retention,
) => switch (retention.maxAge) {
  null => l10n.settingsHistoryRetentionNever,
  final maxAge => l10n.settingsHistoryRetentionDays(maxAge.inDays),
};

class _AboutSection extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsSection(
      title: l10n.settingsSectionAbout,
      children: [
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: Text(l10n.settingsAbout),
          subtitle: Text(l10n.settingsAboutSubtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/settings/about'),
        ),
        ListTile(
          leading: const Icon(Icons.restart_alt),
          title: Text(l10n.settingsRunSetup),
          subtitle: Text(l10n.settingsRunSetupSubtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/onboarding'),
        ),
      ],
    );
  }
}
