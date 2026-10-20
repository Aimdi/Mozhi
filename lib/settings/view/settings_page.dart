import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/semantics.dart'
    show AttributedString, LocaleStringAttribute;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/view/app_shell.dart' show AppDestination;
import 'package:mozhi/app/view/top_level_actions.dart';
import 'package:mozhi/core/on_device_ml.dart';
import 'package:mozhi/core/widgets/fold_aware_split.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_languages.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/about_page.dart' show AboutView;
import 'package:mozhi/settings/view/widgets/accent_color_picker.dart';
import 'package:mozhi/settings/view/widgets/choice_dialog.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:mozhi/settings/view/widgets/privacy_settings_section.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:mozhi/settings/view/widgets/speech_settings_section.dart';
import 'package:mozhi/settings/view/widgets/voice_input_settings_section.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:package_info_plus/package_info_plus.dart';

export 'widgets/privacy_settings_section.dart' show historyRetentionLabel;

/// App settings, in sections: General, Privacy, Offline languages, Online
/// engines, AI providers (advanced), Appearance, Read aloud, Voice input
/// and About.
/// Reads [SettingsCubit] (and `HistoryCubit` for the history rows) from the
/// app-wide providers.
///
/// A full page above the tabs, opened from their app bars
/// ([TopLevelActions]): its back arrow returns to the tab
/// ([topLevelBackButton]).
class SettingsPage extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) => const SettingsView();
}

class SettingsView extends StatelessWidget {
  const new({super.key});

  /// Width from which the sections are laid out in two columns (also at
  /// any width on either side of a vertical hinge or half-opened fold).
  static const twoPaneBreakpoint = 840.0;

  /// Whether on-device (offline) translation can run on this platform:
  /// Mozilla's Bergamot engine is in every build, but not on the web.
  static bool get offlineSupported => onDeviceMlSupported;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsCubit>().state;
    final primary = [
      _GeneralSection(settings: settings),
      PrivacySettingsSection(settings: settings),
      const _OfflineSection(),
      _OnlineSection(settings: settings),
    ];
    final secondary = [
      _AiSection(settings: settings),
      _AppearanceSection(settings: settings),
      if (_hasSpeechService(context))
        SpeechSettingsSection(
          languages: [
            settings.target,
            settings.source,
            ...settings.recentLanguages,
          ],
        ),
      VoiceInputSettingsSection(privacyMode: settings.privacyMode),
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
      appBar: AppBar(
        leading: topLevelBackButton(context),
        title: Text(context.l10n.settingsTitle),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final bookPosture =
              FoldAwareSplit.featureDirectionOf(context) == Axis.horizontal;
          if (width >= twoPaneBreakpoint || bookPosture) {
            return SingleChildScrollView(
              padding: centeredPadding(width, maxWidth: 1200),
              // The columns split at a vertical hinge or fold (inside the
              // scroll view horizontal ones are not followed).
              child: FoldAwareSplit(
                key: const Key('settings_columns'),
                gap: 24,
                crossAxisAlignment: CrossAxisAlignment.start,
                foldDirections: const {Axis.horizontal},
                first: column(primary),
                second: column(secondary),
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

/// App language, tab order, haptic feedback and multiline input.
class _GeneralSection extends StatelessWidget {
  const new({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<SettingsCubit>();
    final home = AppDestination.of(settings.tabOrder.first).label(l10n);
    return SettingsSection(
      title: l10n.settingsSectionGeneral,
      children: [
        _AppLanguageTile(appLocale: settings.appLocale),
        ListTile(
          key: const Key('settings_tab_order'),
          leading: const SettingsIcon(Icons.swap_vert),
          title: Text(l10n.settingsTabOrder),
          subtitle: Text(l10n.settingsTabOrderSubtitle(home)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/settings/tabs'),
        ),
        // Browsers cannot vibrate.
        if (!kIsWeb)
          SwitchListTile(
            key: const Key('settings_haptic_feedback'),
            secondary: const SettingsIcon(Icons.vibration),
            title: Text(l10n.settingsHapticFeedback),
            subtitle: Text(l10n.settingsHapticFeedbackSubtitle),
            value: settings.hapticFeedback,
            onChanged: (value) => cubit.setHapticFeedback(enabled: value),
          ),
        SwitchListTile(
          key: const Key('settings_multiline_input'),
          secondary: const SettingsIcon(Icons.keyboard_return),
          title: Text(l10n.settingsMultilineInput),
          subtitle: Text(l10n.settingsMultilineInputSubtitle),
          value: settings.multilineInput,
          onChanged: (value) => cubit.setMultilineInput(enabled: value),
        ),
      ],
    );
  }
}

/// The language of the app's texts: "System default" or one of
/// [AppLanguages.supported], each named in itself.
class _AppLanguageTile extends StatelessWidget {
  const new({required this.appLocale});

  final String? appLocale;

  /// The choice value of "System default".
  static const _system = '';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final locale = AppLanguages.resolve(appLocale);
    return ListTile(
      key: const Key('settings_app_language'),
      leading: const SettingsIcon(Icons.language),
      title: Text(l10n.settingsAppLanguage),
      subtitle: locale == null
          ? Text(l10n.settingsAppLanguageSystem)
          : _NativeLanguageName(locale),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _pick(context, locale),
    );
  }

  Future<void> _pick(BuildContext context, Locale? current) async {
    final l10n = context.l10n;
    final cubit = context.read<SettingsCubit>();
    final initial = current?.toLanguageTag() ?? _system;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => ChoiceDialog<String>(
        title: l10n.settingsAppLanguage,
        body: l10n.settingsAppLanguageDialogBody,
        initialValue: initial,
        options: [
          ChoiceDialogOption(
            value: _system,
            title: Text(l10n.settingsAppLanguageSystem),
          ),
          for (final locale in AppLanguages.byName)
            ChoiceDialogOption(
              value: locale.toLanguageTag(),
              title: _NativeLanguageName(locale),
            ),
        ],
      ),
    );
    if (choice == null || choice == initial) return;
    cubit.setAppLocale(choice == _system ? null : choice);
  }
}

/// The name of [locale]'s language in itself ("Deutsch", "日本語"), drawn
/// with that language's glyphs and read by screen readers in it.
class _NativeLanguageName extends StatelessWidget {
  const new(this.locale);

  final Locale locale;

  @override
  Widget build(BuildContext context) {
    final name = AppLanguages.nativeName(locale);
    return Semantics(
      attributedLabel: AttributedString(
        name,
        attributes: [
          LocaleStringAttribute(
            range: TextRange(start: 0, end: name.length),
            locale: locale,
          ),
        ],
      ),
      excludeSemantics: true,
      child: Text(name, locale: locale),
    );
  }
}

/// The on-device models (where the platform runs them).
class _OfflineSection extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsSection(
      title: l10n.offlineTitle,
      children: [
        if (SettingsView.offlineSupported)
          ListTile(
            key: const Key('settings_offline_languages'),
            leading: const SettingsIcon(Icons.download_for_offline_outlined),
            title: Text(l10n.settingsOfflineManage),
            subtitle: Text(l10n.settingsOfflineSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/offline'),
          )
        else
          ListTile(
            key: const Key('settings_offline_unavailable'),
            leading: const SettingsIcon(Icons.cloud_off_outlined),
            title: Text(l10n.settingsOfflineUnavailable),
            subtitle: Text(l10n.settingsOfflineUnavailableSubtitle),
          ),
      ],
    );
  }
}

/// Mozhi instances, machine translation services (DeepL, LibreTranslate),
/// the quality modes (and whether the last one is remembered) and instant
/// translation.
class _OnlineSection extends StatelessWidget {
  const new({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<SettingsCubit>();
    final instances = settings.instances;
    final services = settings.providers.where((p) => p.isMtService).toList();
    final enabled = services.where((p) => p.enabled).length;
    return SettingsSection(
      title: l10n.settingsSectionOnline,
      children: [
        ListTile(
          leading: const SettingsIcon(Icons.dns_outlined),
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
          key: const Key('settings_mt_services'),
          leading: const SettingsIcon(Icons.g_translate_outlined),
          title: Text(l10n.settingsMtServicesTitle),
          subtitle: Text(
            services.isEmpty
                ? l10n.settingsMtServicesNone
                : l10n.settingsMtServicesSummary(enabled, services.length),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/settings/providers'),
        ),
        ListTile(
          leading: const SettingsIcon(Icons.speed_outlined),
          title: Text(l10n.settingsQualityTitle),
          subtitle: Text(l10n.settingsQualitySubtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/settings/quality'),
        ),
        SwitchListTile(
          key: const Key('settings_remember_quality'),
          secondary: const SettingsIcon(Icons.bookmark_added_outlined),
          title: Text(l10n.settingsRememberQuality),
          subtitle: Text(l10n.settingsRememberQualitySubtitle),
          value: settings.rememberQuality,
          onChanged: (value) => cubit.setRememberQuality(enabled: value),
        ),
        SwitchListTile(
          secondary: const SettingsIcon(Icons.bolt_outlined),
          title: Text(l10n.settingsInstantTranslate),
          subtitle: Text(l10n.settingsInstantTranslateSubtitle),
          value: settings.instantTranslate,
          onChanged: (value) => cubit.setInstantTranslate(enabled: value),
        ),
      ],
    );
  }

  static String _host(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isEmpty ? url : host;
  }
}

/// AI providers and what uses them (insights, instant AI translation,
/// presets, glossaries, usage), marked as advanced.
class _AiSection extends StatelessWidget {
  const new({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<SettingsCubit>();
    final providers = settings.providers.where((p) => !p.isMtService).toList();
    final enabled = providers.where((p) => p.enabled).length;
    return SettingsSection(
      title: l10n.settingsProvidersTitle,
      badge: l10n.settingsAdvancedBadge,
      children: [
        ListTile(
          key: const Key('settings_ai_providers'),
          leading: const SettingsIcon(Icons.auto_awesome_outlined),
          title: Text(l10n.settingsProvidersTitle),
          subtitle: Text(
            providers.isEmpty
                ? l10n.settingsProvidersNone
                : l10n.settingsProvidersSummary(enabled, providers.length),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/settings/providers'),
        ),
        _AssistEngineTile(settings: settings),
        SwitchListTile(
          secondary: const SettingsIcon(Icons.electric_bolt_outlined),
          title: Text(l10n.settingsInstantTranslateAi),
          subtitle: Text(l10n.settingsInstantTranslateAiSubtitle),
          value: settings.instantTranslateAi,
          onChanged: (value) => cubit.setInstantTranslateAi(enabled: value),
        ),
        ListTile(
          leading: const SettingsIcon(Icons.tune),
          title: Text(l10n.presetsTitle),
          subtitle: Text(l10n.settingsPresetsSubtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/settings/presets'),
        ),
        ListTile(
          leading: const SettingsIcon(Icons.menu_book_outlined),
          title: Text(l10n.glossariesTitle),
          subtitle: Text(l10n.settingsGlossariesSubtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/settings/glossaries'),
        ),
        ListTile(
          leading: const SettingsIcon(Icons.insights_outlined),
          title: Text(l10n.settingsUsageTitle),
          subtitle: Text(l10n.settingsUsageSubtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/settings/usage'),
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
    final hasProviders = settings.providers.any((p) => !p.isMtService);
    return ListTile(
      leading: const SettingsIcon(Icons.lightbulb_outline),
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
        .where((p) => !p.isMtService && (p.enabled || 'ai:${p.id}' == current))
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
            secondary: const SettingsIcon(Icons.wallpaper_outlined),
            title: Text(l10n.settingsDynamicColor),
            subtitle: Text(l10n.settingsDynamicColorSubtitle),
            value: settings.dynamicColor,
            onChanged: (value) => cubit.setDynamicColor(enabled: value),
          ),
        _DarkLookPicker(
          lightsOut: settings.pureBlack,
          enabled: settings.themeMode != ThemeMode.light,
          onChanged: (value) => cubit.setPureBlack(enabled: value),
        ),
        SwitchListTile(
          secondary: const SettingsIcon(Icons.abc),
          title: Text(l10n.settingsShowTransliteration),
          subtitle: Text(l10n.settingsShowTransliterationSubtitle),
          value: settings.showTransliteration,
          onChanged: (value) => cubit.setShowTransliteration(enabled: value),
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

/// The dark look: "Dim" (dark blue-grey) or "Lights out" (true black, the
/// default), stored as [AppSettings.pureBlack]. Disabled while the light
/// theme is forced.
class _DarkLookPicker extends StatelessWidget {
  const new({
    required this.lightsOut,
    required this.enabled,
    required this.onChanged,
  });

  final bool lightsOut;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final options = [
      (false, const Color(0xFF15202B), l10n.settingsDarkLookDim),
      (true, const Color(0xFF000000), l10n.settingsDarkLookLightsOut),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ExcludeSemantics(
              child: Text(
                l10n.settingsDarkLook,
                style: theme.textTheme.bodyLarge,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
            child: Text(
              l10n.settingsDarkLookSubtitle,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppPalette.of(context).secondaryText,
              ),
            ),
          ),
          Semantics(
            container: true,
            explicitChildNodes: true,
            label: l10n.settingsDarkLook,
            child: RadioGroup<bool>(
              groupValue: lightsOut,
              onChanged: (value) {
                if (value != null && value != lightsOut) onChanged(value);
              },
              child: Column(
                children: [
                  for (final (value, swatch, label) in options)
                    RadioListTile<bool>(
                      key: Key('settings_dark_look_$value'),
                      value: value,
                      enabled: enabled,
                      title: Text(label),
                      secondary: _LookSwatch(color: swatch),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A small round preview of a dark look's background (decorative).
class _LookSwatch extends StatelessWidget {
  const new({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
    ),
  );
}

/// About Mozhi, the version, the source code, the licences (with the
/// offline models' MPL-2.0 notice) and "Run setup again".
class _AboutSection extends StatefulWidget {
  const new();

  @override
  State<_AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<_AboutSection> {
  late final Future<PackageInfo> _info = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FutureBuilder<PackageInfo>(
      future: _info,
      builder: (context, snapshot) {
        final info = snapshot.data;
        final version = info == null
            ? null
            : info.buildNumber.isEmpty
            ? info.version
            : '${info.version} (${info.buildNumber})';
        return SettingsSection(
          title: l10n.settingsSectionAbout,
          children: [
            ListTile(
              leading: const SettingsIcon(Icons.info_outline),
              title: Text(l10n.settingsAbout),
              subtitle: Text(l10n.settingsAboutSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/about'),
            ),
            ListTile(
              key: const Key('settings_version'),
              leading: const SettingsIcon(Icons.tag),
              title: Text(l10n.settingsVersion),
              subtitle: version == null ? null : Text(version),
            ),
            ListTile(
              key: const Key('settings_source_code'),
              leading: const SettingsIcon(Icons.code),
              title: Text(l10n.settingsAboutSource),
              subtitle: Text(AboutView.sourceCodeUrl.host),
              trailing: const Icon(Icons.open_in_new),
              onTap: () => LinkLauncher.open(context, AboutView.sourceCodeUrl),
            ),
            ListTile(
              key: const Key('settings_licenses'),
              leading: const SettingsIcon(Icons.description_outlined),
              title: Text(l10n.settingsAboutLicenses),
              subtitle: Text(l10n.settingsAboutLicensesSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showLicensePage(
                context: context,
                applicationName: l10n.appTitle,
                applicationVersion: version,
                applicationIcon: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Icon(
                    Icons.translate,
                    size: 40,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ),
            ListTile(
              leading: const SettingsIcon(Icons.restart_alt),
              title: Text(l10n.settingsRunSetup),
              subtitle: Text(l10n.settingsRunSetupSteps),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/onboarding'),
            ),
          ],
        );
      },
    );
  }
}
