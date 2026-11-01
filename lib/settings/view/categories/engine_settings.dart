import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/on_device_ml.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/choice_dialog.dart';
import 'package:mozhi/settings/view/widgets/model_source_dialog.dart';
import 'package:mozhi/settings/view/widgets/on_device_ai_tile.dart';
import 'package:mozhi/settings/view/widgets/settings_search.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// Anchors ([SettingsAnchor.id]) of the Translation engines settings.
abstract final class EngineAnchors {
  static const offlineLanguages = 'offline_languages';
  static const onDeviceAi = 'engines_on_device_ai';
  static const modelSource = 'model_source';
  static const instances = 'instances';
  static const duckDuckGoFallback = 'duckduckgo_fallback';
  static const services = 'mt_services';
  static const quality = 'quality_modes';
  static const rememberQuality = 'remember_quality';
  static const instantTranslate = 'instant_translate';
}

/// The Translation engines settings: the offline languages (where the
/// platform runs them) and on-device AI (where it runs), the online
/// engines (Mozhi instances, whether DuckDuckGo may take over when Google
/// fails on every one of them, machine translation services such as DeepL
/// and LibreTranslate) and how they translate (quality modes, remembering
/// the last one, instant translation).
class EngineSettings extends StatelessWidget {
  const new({required this.settings, super.key});

  final AppSettings settings;

  /// Whether on-device (offline) translation can run on this platform:
  /// Mozilla's Bergamot engine is in every build, natively on Android and
  /// as WebAssembly in the web app. A browser that can't run it is
  /// explained on the Offline languages screen.
  static bool get offlineSupported =>
      offlineEngineIncluded && (onDeviceMlPlatform || kIsWeb);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<SettingsCubit>();
    final instances = settings.instances;
    final services = settings.providers.where((p) => p.isMtService).toList();
    final enabled = services.where((p) => p.enabled).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: l10n.offlineTitle,
          children: [
            SettingsAnchor(
              id: EngineAnchors.offlineLanguages,
              child: offlineSupported
                  ? ListTile(
                      key: const Key('settings_offline_languages'),
                      leading: const SettingsIcon(
                        Icons.download_for_offline_outlined,
                      ),
                      title: Text(l10n.settingsOfflineManage),
                      subtitle: Text(l10n.settingsOfflineSubtitle),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.push(AppRoutes.offline),
                    )
                  : ListTile(
                      key: const Key('settings_offline_unavailable'),
                      leading: const SettingsIcon(Icons.cloud_off_outlined),
                      title: Text(l10n.settingsOfflineUnavailable),
                      subtitle: Text(l10n.settingsOfflineUnavailableSubtitle),
                    ),
            ),
            // AI on this phone (Android, where it runs).
            if (onDeviceAiOffered(context))
              const SettingsAnchor(
                id: EngineAnchors.onDeviceAi,
                child: OnDeviceAiTile(),
              ),
            // Offline languages, voice input and text recognition.
            const SettingsAnchor(
              id: EngineAnchors.modelSource,
              child: ModelSourceTile(),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.settingsSectionOnline,
          children: [
            SettingsAnchor(
              id: EngineAnchors.instances,
              child: ListTile(
                key: const Key('settings_instances'),
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
                onTap: () => context.push(AppRoutes.instances),
              ),
            ),
            // Sending text to another engine for this one case: on by
            // default (Google rate-limits most volunteer servers); turning
            // it off or on is the user's choice, kept from then on.
            SettingsAnchor(
              id: EngineAnchors.duckDuckGoFallback,
              child: SwitchListTile(
                key: const Key('settings_duckduckgo_fallback'),
                secondary: const SettingsIcon(Icons.alt_route),
                title: Text(l10n.settingsFallbackDuckDuckGo),
                subtitle: Text(l10n.settingsFallbackDuckDuckGoOnSubtitle),
                isThreeLine: true,
                value: settings.fallbackToDuckDuckGo,
                onChanged: (value) =>
                    cubit.setFallbackToDuckDuckGo(enabled: value),
              ),
            ),
            SettingsAnchor(
              id: EngineAnchors.services,
              child: ListTile(
                key: const Key('settings_mt_services'),
                leading: const SettingsIcon(Icons.g_translate_outlined),
                title: Text(l10n.settingsMtServicesTitle),
                subtitle: Text(
                  services.isEmpty
                      ? l10n.settingsMtServicesNone
                      : l10n.settingsMtServicesSummary(
                          enabled,
                          services.length,
                        ),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(AppRoutes.providers),
              ),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.settingsSectionTranslating,
          divider: false,
          children: [
            SettingsAnchor(
              id: EngineAnchors.quality,
              child: ListTile(
                key: const Key('settings_quality_modes'),
                leading: const SettingsIcon(Icons.speed_outlined),
                title: Text(l10n.settingsQualityTitle),
                subtitle: Text(l10n.settingsQualitySubtitle),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(AppRoutes.quality),
              ),
            ),
            SettingsAnchor(
              id: EngineAnchors.rememberQuality,
              child: SwitchListTile(
                key: const Key('settings_remember_quality'),
                secondary: const SettingsIcon(Icons.bookmark_added_outlined),
                title: Text(l10n.settingsRememberQuality),
                subtitle: Text(l10n.settingsRememberQualitySubtitle),
                value: settings.rememberQuality,
                onChanged: (value) => cubit.setRememberQuality(enabled: value),
              ),
            ),
            SettingsAnchor(
              id: EngineAnchors.instantTranslate,
              child: InstantTranslateTile(settings: settings),
            ),
          ],
        ),
      ],
    );
  }

  static String _host(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isEmpty ? url : host;
  }
}

/// Which engines translate while the user types: one choice over the two
/// stored switches, [AppSettings.instantTranslate] (every engine that is
/// not an AI model: Mozhi, translation services, on-device) and
/// [AppSettings.instantTranslateAi] (AI providers).
enum InstantTranslateChoice {
  /// Neither.
  off(nonAi: false, ai: false),

  /// Every engine but AI models.
  engines(nonAi: true, ai: false),

  /// Every engine.
  enginesAndAi(nonAi: true, ai: true),

  /// Only AI models: a combination the earlier two switches allowed. It is
  /// offered only while it is set.
  aiOnly(nonAi: false, ai: true);

  new({required this.nonAi, required this.ai});

  /// The choice [settings] hold.
  factory of(AppSettings settings) => values.firstWhere(
    (choice) =>
        choice.nonAi == settings.instantTranslate &&
        choice.ai == settings.instantTranslateAi,
  );

  /// [AppSettings.instantTranslate].
  final bool nonAi;

  /// [AppSettings.instantTranslateAi].
  final bool ai;

  String title(AppLocalizations l10n) => switch (this) {
    off => l10n.settingsInstantOff,
    engines => l10n.settingsInstantEngines,
    enginesAndAi => l10n.settingsInstantEnginesAndAi,
    aiOnly => l10n.settingsInstantAiOnly,
  };

  String subtitle(AppLocalizations l10n) => switch (this) {
    off => l10n.settingsInstantOffSubtitle,
    engines => l10n.settingsInstantEnginesSubtitle,
    enginesAndAi => l10n.settingsInstantEnginesAndAiSubtitle,
    aiOnly => l10n.settingsInstantAiOnlySubtitle,
  };
}

/// "Instant translate": the current [InstantTranslateChoice], picked in a
/// dialog of "Off", "Online engines" and "Online engines and AI".
class InstantTranslateTile extends StatelessWidget {
  const new({required this.settings, super.key});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final current = InstantTranslateChoice.of(settings);
    return ListTile(
      key: const Key('settings_instant_translate'),
      leading: const SettingsIcon(Icons.bolt_outlined),
      title: Text(l10n.settingsInstantTranslate),
      subtitle: Text(current.title(l10n)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _pick(context, current),
    );
  }

  Future<void> _pick(
    BuildContext context,
    InstantTranslateChoice current,
  ) async {
    final l10n = context.l10n;
    final cubit = context.read<SettingsCubit>();
    final choice = await showDialog<InstantTranslateChoice>(
      context: context,
      builder: (context) => ChoiceDialog<InstantTranslateChoice>(
        title: l10n.settingsInstantTranslate,
        body: l10n.settingsInstantTranslateDialogBody,
        initialValue: current,
        options: [
          for (final choice in InstantTranslateChoice.values)
            if (choice != InstantTranslateChoice.aiOnly || choice == current)
              ChoiceDialogOption(
                value: choice,
                title: Text(choice.title(l10n)),
                subtitle: Text(choice.subtitle(l10n)),
              ),
        ],
      ),
    );
    if (choice == null || choice == current) return;
    cubit.update(
      (settings) => settings.copyWith(
        instantTranslate: choice.nonAi,
        instantTranslateAi: choice.ai,
      ),
    );
  }
}
