import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/on_device_ai/data/on_device_ai.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/choice_dialog.dart';
import 'package:mozhi/settings/view/widgets/on_device_ai_tile.dart';
import 'package:mozhi/settings/view/widgets/settings_search.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:translation_repository/translation_repository.dart';

/// Anchors ([SettingsAnchor.id]) of the AI settings.
abstract final class AiAnchors {
  static const onDeviceAi = 'on_device_ai';
  static const providers = 'ai_providers';
  static const assistant = 'ai_assistant';
  static const presets = 'presets';
  static const glossaries = 'glossaries';
  static const usage = 'usage';
}

/// The AI settings (marked as advanced where they are listed): on-device
/// AI ([OnDeviceAiTile]), the AI providers and what uses them (insights,
/// presets, glossaries, usage).
/// Instant translation with AI is one of the choices of "Instant
/// translate" (Translation engines).
class AiSettings extends StatelessWidget {
  const new({required this.settings, super.key});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final providers = settings.providers.where((p) => !p.isMtService).toList();
    final enabled = providers.where((p) => p.enabled).length;
    return SettingsSection(
      divider: false,
      children: [
        const SettingsAnchor(
          id: AiAnchors.onDeviceAi,
          child: OnDeviceAiTile(),
        ),
        SettingsAnchor(
          id: AiAnchors.providers,
          child: ListTile(
            key: const Key('settings_ai_providers'),
            leading: const SettingsIcon(Icons.auto_awesome_outlined),
            title: Text(l10n.settingsProvidersTitle),
            subtitle: Text(
              providers.isEmpty
                  ? l10n.settingsProvidersNone
                  : l10n.settingsProvidersSummary(enabled, providers.length),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.providers),
          ),
        ),
        SettingsAnchor(
          id: AiAnchors.assistant,
          child: _AssistEngineTile(settings: settings),
        ),
        SettingsAnchor(
          id: AiAnchors.presets,
          child: ListTile(
            key: const Key('settings_presets'),
            leading: const SettingsIcon(Icons.tune),
            title: Text(l10n.presetsTitle),
            subtitle: Text(l10n.settingsPresetsSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.presets),
          ),
        ),
        SettingsAnchor(
          id: AiAnchors.glossaries,
          child: ListTile(
            key: const Key('settings_glossaries'),
            leading: const SettingsIcon(Icons.menu_book_outlined),
            title: Text(l10n.glossariesTitle),
            subtitle: Text(l10n.settingsGlossariesSubtitleAllEngines),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.glossaries),
          ),
        ),
        SettingsAnchor(
          id: AiAnchors.usage,
          child: ListTile(
            key: const Key('settings_usage'),
            leading: const SettingsIcon(Icons.insights_outlined),
            title: Text(l10n.settingsUsageTitle),
            subtitle: Text(l10n.settingsUsageSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.usage),
          ),
        ),
      ],
    );
  }
}

/// The AI provider that writes insights and explanations: "Automatic" or
/// one of the enabled AI providers, the on-device assistant model included
/// (opens the providers without any).
class _AssistEngineTile extends StatelessWidget {
  const new({required this.settings});

  final AppSettings settings;

  static const _automatic = '';

  @override
  Widget build(BuildContext context) {
    final onDeviceAi = _onDeviceAiOf(context);
    if (onDeviceAi == null) return _tile(context, const []);
    return StreamBuilder<List<AiProviderConfig>>(
      stream: onDeviceAi.providersChanges,
      initialData: onDeviceAi.providers,
      builder: (context, snapshot) => _tile(context, [
        // The translation model does no extras.
        for (final provider in snapshot.data ?? const <AiProviderConfig>[])
          if (!provider.resolvedPromptProfile.isTranslationOnly) provider,
      ]),
    );
  }

  /// The tile, with the [onDevice] assistant models' providers.
  Widget _tile(BuildContext context, List<AiProviderConfig> onDevice) {
    final l10n = context.l10n;
    final current = settings.assistEngineId;
    final selected = [...settings.providers, ...onDevice]
        .where((p) => 'ai:${p.id}' == current)
        .firstOrNull;
    final hasProviders =
        onDevice.isNotEmpty || settings.providers.any((p) => !p.isMtService);
    return ListTile(
      key: const Key('settings_assist_engine'),
      leading: const SettingsIcon(Icons.lightbulb_outline),
      title: Text(l10n.settingsAssistEngine),
      subtitle: Text(
        !hasProviders
            ? l10n.settingsAssistEngineNone
            : selected?.name ?? l10n.settingsAssistEngineAutomatic,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: hasProviders
          ? () => _pick(context, onDevice)
          : () => context.push(AppRoutes.providers),
    );
  }

  /// The on-device AI, where it runs.
  static OnDeviceAi? _onDeviceAiOf(BuildContext context) {
    try {
      return context.read<OnDeviceAi>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  Future<void> _pick(
    BuildContext context,
    List<AiProviderConfig> onDevice,
  ) async {
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
            subtitle: Text(
              onDevice.isEmpty
                  ? l10n.settingsAssistEngineAutomaticSubtitle
                  : l10n.settingsAssistEngineAutomaticOnDeviceSubtitle,
            ),
          ),
          for (final provider in providers)
            ChoiceDialogOption(
              value: 'ai:${provider.id}',
              title: Text(provider.name),
              subtitle: Text(provider.model),
            ),
          for (final provider in onDevice)
            ChoiceDialogOption(
              value: 'ai:${provider.id}',
              title: Text(provider.name),
              subtitle: Text(l10n.settingsProviderTypeOnDevice),
            ),
        ],
      ),
    );
    if (choice == null || choice == current) return;
    cubit.setAssistEngine(choice == _automatic ? null : choice);
  }
}
