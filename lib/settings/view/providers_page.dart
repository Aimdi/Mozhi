import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/view/provider_editor_page.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:translation_repository/translation_repository.dart';

/// Lists the configured AI providers and machine translation services.
///
/// On the web ([isWeb]) it says that API keys only last for the browser
/// session (they are kept in `sessionStorage`).
class ProvidersPage extends StatelessWidget {
  const new({super.key, this.isWeb = kIsWeb});

  final bool isWeb;

  @override
  Widget build(BuildContext context) => ProvidersView(isWeb: isWeb);
}

/// Location of the provider editor for [providerId] or [presetId].
String providerEditorLocation({String? providerId, String? presetId}) => Uri(
  path: '/settings/providers/edit',
  queryParameters: {'id': ?providerId, 'preset': ?presetId},
).toString();

class ProvidersView extends StatelessWidget {
  const new({super.key, this.isWeb = kIsWeb});

  /// Whether the app runs in a browser, where API keys are session-only.
  final bool isWeb;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final providers = context.select<SettingsCubit, List<AiProviderConfig>>(
      (cubit) => cubit.state.providers,
    );
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsProvidersTitle)),
      floatingActionButton: providers.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => showAddProviderSheet(context),
              icon: const Icon(Icons.add),
              label: Text(l10n.settingsProvidersAdd),
            ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final padding = centeredPadding(constraints.maxWidth, bottom: 96);
          if (providers.isEmpty) {
            return SingleChildScrollView(
              padding: padding,
              child: Column(
                children: [
                  const _EmptyState(),
                  if (isWeb)
                    _FooterNote(
                      icon: Icons.schedule_outlined,
                      text: l10n.settingsProvidersWebNote,
                    ),
                ],
              ),
            );
          }
          return ListView(
            padding: padding,
            children: [
              for (final provider in providers)
                _ProviderTile(key: ValueKey(provider.id), provider: provider),
              if (isWeb)
                _FooterNote(
                  icon: Icons.schedule_outlined,
                  text: l10n.settingsProvidersWebNote,
                )
              else
                _FooterNote(
                  icon: Icons.lock_outline,
                  text: l10n.settingsProvidersFooter,
                ),
            ],
          );
        },
      ),
    );
  }
}

/// A small note below the providers.
class _FooterNote extends StatelessWidget {
  const new({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows the preset picker and opens the editor for the chosen preset.
Future<void> showAddProviderSheet(BuildContext context) async {
  final presetId = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => const PresetPickerSheet(),
  );
  if (presetId == null || !context.mounted) return;
  await context.push(providerEditorLocation(presetId: presetId));
}

/// Bottom sheet listing [AiProviderPreset.all] and, in their own section,
/// [AiProviderPreset.mtServices]; pops the chosen preset id.
class PresetPickerSheet extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Semantics(
              header: true,
              child: Text(
                l10n.settingsProvidersPresetsTitle,
                style: theme.textTheme.titleLarge,
              ),
            ),
          ),
          _PresetSection(title: l10n.settingsProvidersPresetsAi),
          for (final preset in AiProviderPreset.all)
            _PresetTile(preset: preset),
          _PresetSection(
            title: l10n.settingsProvidersPresetsMt,
            body: l10n.settingsProvidersPresetsMtBody,
          ),
          for (final preset in AiProviderPreset.mtServices)
            _PresetTile(preset: preset),
        ],
      ),
    );
  }
}

/// A section header in [PresetPickerSheet].
class _PresetSection extends StatelessWidget {
  const new({required this.title, this.body});

  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                color: colors.primary,
              ),
            ),
          ),
          if (body case final body?) ...[
            const SizedBox(height: 4),
            Text(
              body,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One preset in [PresetPickerSheet]; pops its id.
class _PresetTile extends StatelessWidget {
  const new({required this.preset});

  final AiProviderPreset preset;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final isMt = preset.service != MtService.llm;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      leading: Icon(
        isMt
            ? Icons.translate
            : preset.isLocal
            ? Icons.computer_outlined
            : Icons.cloud_outlined,
      ),
      title: Row(
        children: [
          Flexible(child: Text(preset.name)),
          if (preset.isLocal) ...[
            const SizedBox(width: 8),
            StatusBadge(
              label: l10n.settingsProvidersLocal,
              color: theme.colorScheme.success,
            ),
          ],
        ],
      ),
      subtitle: preset.description.isEmpty
          ? null
          : Text(
              preset.description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
      onTap: () => Navigator.of(context).pop(preset.id),
    );
  }
}

/// Subtitle of a machine translation service in the list: the service and
/// its server host (none for the official DeepL API).
String _mtSubtitle(AppLocalizations l10n, AiProviderConfig provider) {
  final service = mtServiceName(l10n, provider.service) ?? provider.name;
  final url = provider.baseUrl.trim();
  final host = url.isEmpty
      ? ''
      : Uri.tryParse(url.contains('://') ? url : 'https://$url')?.host ?? '';
  return host.isEmpty
      ? service
      : l10n.settingsProviderMtSubtitle(service, host);
}

class _ProviderTile extends StatelessWidget {
  const new({required this.provider, super.key});

  final AiProviderConfig provider;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isLocal = provider.isLocal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      // A flat hairline card (X's quoted-post box).
      child: Card.outlined(
        margin: EdgeInsets.zero,
        color: colors.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.cardBorderRadius,
          side: BorderSide(color: Theme.of(context).colorScheme.outline),
        ),
        child: InkWell(
          onTap: () =>
              context.push(providerEditorLocation(providerId: provider.id)),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 8, 12),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: colors.secondaryContainer,
                  foregroundColor: colors.onSecondaryContainer,
                  child: Icon(
                    provider.isMtService
                        ? Icons.translate
                        : isLocal
                        ? Icons.computer_outlined
                        : Icons.cloud_outlined,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        provider.name,
                        style: theme.textTheme.bodyLarge,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        provider.isMtService
                            ? _mtSubtitle(l10n, provider)
                            : provider.model,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      StatusBadge(
                        label: isLocal
                            ? l10n.settingsProvidersLocal
                            : l10n.settingsProvidersCloud,
                        color: isLocal ? colors.success : colors.tertiary,
                        icon: isLocal
                            ? Icons.shield_outlined
                            : Icons.public_outlined,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Semantics(
                  label: l10n.settingsProvidersEnable(provider.name),
                  child: Switch(
                    value: provider.enabled,
                    onChanged: (value) => context
                        .read<SettingsCubit>()
                        .setProviderEnabled(provider.id, enabled: value),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Icon(
                Icons.auto_awesome,
                size: 40,
                color: colors.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(height: 24),
          Semantics(
            header: true,
            child: Text(
              l10n.settingsProvidersEmptyTitle,
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            l10n.settingsProvidersEmptyBody,
            style: theme.textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            l10n.settingsProvidersEmptyBenefits,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => showAddProviderSheet(context),
            icon: const Icon(Icons.add),
            label: Text(l10n.settingsProvidersAdd),
          ),
        ],
      ),
    );
  }
}
