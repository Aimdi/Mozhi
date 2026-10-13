import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/history/view/widgets/clear_history_dialog.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/accent_color_picker.dart';
import 'package:mozhi/settings/view/widgets/history_data_actions.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// App settings. Reads [SettingsCubit] (and `HistoryCubit` for the data
/// actions) from the app-wide providers.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) => const SettingsView();
}

class SettingsView extends StatelessWidget {
  const SettingsView({super.key});

  /// Width from which the sections are laid out in two columns.
  static const twoPaneBreakpoint = 840.0;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsCubit>().state;
    final primary = [
      _ServicesSection(settings: settings),
      _TranslationSection(settings: settings),
    ];
    final secondary = [
      _AppearanceSection(settings: settings),
      const _DataSection(),
      const _AboutSection(),
    ];
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
                  Expanded(child: Column(children: primary)),
                  const SizedBox(width: 24),
                  Expanded(child: Column(children: secondary)),
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

class _ServicesSection extends StatelessWidget {
  const _ServicesSection({required this.settings});

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
      ],
    );
  }

  static String _host(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isEmpty ? url : host;
  }
}

class _TranslationSection extends StatelessWidget {
  const _TranslationSection({required this.settings});

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
      ],
    );
  }
}

class _AssistEngineTile extends StatelessWidget {
  const _AssistEngineTile({required this.settings});

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
      builder: (context) => AlertDialog(
        title: Text(l10n.settingsAssistEngine),
        scrollable: true,
        contentPadding: const EdgeInsets.fromLTRB(0, 16, 0, 0),
        content: RadioGroup<String>(
          groupValue: current,
          onChanged: (value) => Navigator.of(context).pop(value),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(l10n.settingsAssistEngineDialogBody),
              ),
              RadioListTile<String>(
                value: _automatic,
                title: Text(l10n.settingsAssistEngineAutomatic),
                subtitle: Text(l10n.settingsAssistEngineAutomaticSubtitle),
              ),
              for (final provider in providers)
                RadioListTile<String>(
                  value: 'ai:${provider.id}',
                  title: Text(provider.name),
                  subtitle: Text(provider.model),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.commonCancel),
          ),
        ],
      ),
    );
    if (choice == null || choice == current) return;
    cubit.setAssistEngine(choice == _automatic ? null : choice);
  }
}

class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection({required this.settings});

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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.settingsTheme,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 12),
              SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: ThemeMode.system,
                    icon: const Icon(Icons.brightness_auto_outlined),
                    label: _SegmentLabel(l10n.settingsThemeSystem),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    icon: const Icon(Icons.light_mode_outlined),
                    label: _SegmentLabel(l10n.settingsThemeLight),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    icon: const Icon(Icons.dark_mode_outlined),
                    label: _SegmentLabel(l10n.settingsThemeDark),
                  ),
                ],
                selected: {settings.themeMode},
                onSelectionChanged: (selection) =>
                    cubit.setThemeMode(selection.first),
              ),
            ],
          ),
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
                Text(
                  l10n.settingsAccentColor,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 8),
                AccentColorPicker(
                  selected: settings.seedColor,
                  onSelected: cubit.setSeedColor,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SegmentLabel extends StatelessWidget {
  const _SegmentLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, maxLines: 1, overflow: TextOverflow.ellipsis);
}

class _DataSection extends StatelessWidget {
  const _DataSection();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final error = Theme.of(context).colorScheme.error;
    return SettingsSection(
      title: l10n.settingsSectionData,
      children: [
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
          leading: Icon(Icons.delete_sweep_outlined, color: error),
          title: Text(l10n.historyClearMenu, style: TextStyle(color: error)),
          subtitle: Text(l10n.settingsClearHistorySubtitle),
          onTap: () => confirmClearHistory(context),
        ),
      ],
    );
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection();

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
      ],
    );
  }
}
