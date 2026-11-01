import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/app_bar_title.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/engine_list_cubit.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/choice_dialog.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:translation_repository/translation_repository.dart';

/// Picks the engines of the quality modes ([QualityMode.fast] and
/// [QualityMode.best]) from the engines of the [TranslationRepository]
/// read from the context. Reads the app-wide [SettingsCubit].
class QualityModesPage extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) {
        final cubit = EngineListCubit(
          repository: context.read<TranslationRepository>(),
        );
        unawaited(cubit.load());
        return cubit;
      },
      child: const QualityModesView(),
    );
  }
}

class QualityModesView extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final engines = context.watch<EngineListCubit>().state;
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.settingsQualityTitle)),
      body: LayoutBuilder(
        builder: (context, constraints) => ListView(
          padding: centeredPadding(constraints.maxWidth),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text(
                l10n.settingsQualityIntro,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (engines.status == EngineListStatus.initial ||
                engines.status == EngineListStatus.loading)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: LinearProgressIndicator(
                  semanticsLabel: l10n.settingsQualityLoading,
                ),
              ),
            if (engines.status == EngineListStatus.failure)
              _Notice(
                icon: Icons.error_outline,
                message: l10n.settingsQualityLoadFailed,
                action: TextButton(
                  onPressed: () =>
                      context.read<EngineListCubit>().load(refresh: true),
                  child: Text(l10n.commonRetry),
                ),
              ),
            if (engines.status == EngineListStatus.ready &&
                engines.engines.isEmpty)
              _Notice(
                icon: Icons.info_outline,
                message: l10n.settingsQualityNoEngines,
              ),
            const _QualityEngineSection(mode: QualityMode.fast),
            const _QualityEngineSection(mode: QualityMode.best),
          ],
        ),
      ),
    );
  }
}

/// The engine picked for [mode] ([QualityMode.fast] or [QualityMode.best]).
class _QualityEngineSection extends StatelessWidget {
  const new({required this.mode});

  final QualityMode mode;

  bool get _isBest => mode == QualityMode.best;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final settings = context.watch<SettingsCubit>().state;
    final list = context.watch<EngineListCubit>().state;
    final ready = list.status == EngineListStatus.ready;
    final id = _isBest ? settings.bestEngineId : settings.fastEngineId;
    final engine = list.engine(id);

    final String title;
    final String subtitle;
    // Without an engine of its own a mode uses the usual engine, once the
    // other mode has one (see `TranslateCubit`).
    final otherId = _isBest ? settings.fastEngineId : settings.bestEngineId;
    if (id == null) {
      title = l10n.settingsQualityNotSet;
      subtitle = otherId == null
          ? l10n.settingsQualityChoose
          : l10n.settingsQualityUsesUsual;
    } else if (engine != null) {
      title = engine.name;
      subtitle = engine.subtitle ?? '';
    } else {
      title = _fallbackName(id, settings);
      subtitle = ready ? l10n.settingsQualityUnavailable : '';
    }
    final hasAi = list.engines.any((e) => e.isAi);

    return SettingsSection(
      title: _isBest ? l10n.settingsQualityBest : l10n.settingsQualityFast,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            _isBest
                ? l10n.settingsQualityBestDescription
                : l10n.settingsQualityFastDescription,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        ListTile(
          leading: Icon(
            engine != null
                ? engineKindIcon(engine.kind)
                : _isBest
                ? Icons.workspace_premium_outlined
                : Icons.bolt_outlined,
          ),
          title: Text(title),
          subtitle: subtitle.isEmpty ? null : Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
          enabled: ready && list.engines.isNotEmpty,
          onTap: () => _pick(context, current: id, engines: list.engines),
        ),
        if (_isBest && ready && !hasAi)
          ListTile(
            leading: const SettingsIcon(Icons.add),
            title: Text(l10n.settingsProvidersAdd),
            subtitle: Text(l10n.settingsQualityBestNoAi),
            onTap: () => context.push('/settings/providers'),
          ),
      ],
    );
  }

  Future<void> _pick(
    BuildContext context, {
    required String? current,
    required List<TranslationEngine> engines,
  }) async {
    final l10n = context.l10n;
    final cubit = context.read<SettingsCubit>();
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => EnginePickerDialog(
        title: _isBest
            ? l10n.settingsQualityPickBest
            : l10n.settingsQualityPickFast,
        engines: engines,
        selected: current,
      ),
    );
    if (choice == null) return;
    final picked = choice.isEmpty ? null : choice;
    if (picked == current) return;
    final settings = cubit.state;
    cubit.setQualityEngines(
      fast: _isBest ? settings.fastEngineId : picked,
      best: _isBest ? picked : settings.bestEngineId,
    );
  }

  /// A readable name for the engine [id] while it is not in the list.
  static String _fallbackName(String id, AppSettings settings) {
    final separator = id.indexOf(':');
    if (separator == -1) return id;
    final kind = id.substring(0, separator);
    final rest = id.substring(separator + 1);
    if (kind == 'ai' || kind == 'mt') {
      for (final provider in settings.providers) {
        if (provider.id == rest) return provider.name;
      }
    }
    return rest.isEmpty ? id : rest;
  }
}

/// Icon of an engine of [kind], matching the settings entries.
IconData engineKindIcon(EngineKind kind) => switch (kind) {
  EngineKind.mozhi => Icons.dns_outlined,
  EngineKind.ai => Icons.auto_awesome_outlined,
  EngineKind.mt => Icons.translate,
  EngineKind.offline => Icons.download_for_offline_outlined,
};

/// Lets the user pick one of [engines] or none; Save confirms the choice
/// (see [ChoiceDialog]). Pops the engine id, an empty string for "none",
/// or null when cancelled.
class EnginePickerDialog extends StatelessWidget {
  const new({
    required this.title,
    required this.engines,
    this.selected,
    super.key,
  });

  final String title;
  final List<TranslationEngine> engines;

  /// The current engine id; null = none.
  final String? selected;

  static const _none = '';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ChoiceDialog<String>(
      title: title,
      initialValue: selected ?? _none,
      options: [
        ChoiceDialogOption(value: _none, title: Text(l10n.settingsQualityNone)),
        for (final engine in engines)
          ChoiceDialogOption(
            value: engine.id,
            title: Text(engine.name),
            subtitle: engine.subtitle == null
                ? null
                : Text(
                    engine.subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            secondary: Icon(engineKindIcon(engine.kind)),
          ),
      ],
    );
  }
}

/// A message (with an optional action) above the sections.
class _Notice extends StatelessWidget {
  const new({required this.icon, required this.message, this.action});

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Card.filled(
        margin: EdgeInsets.zero,
        color: colors.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: AppLook.of(context).cardRadius,
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                liveRegion: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, color: colors.onSurfaceVariant),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(message, style: theme.textTheme.bodyMedium),
                    ),
                  ],
                ),
              ),
              if (action case final action?)
                Align(alignment: AlignmentDirectional.centerEnd, child: action),
            ],
          ),
        ),
      ),
    );
  }
}
