import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/offline.dart' show OfflineEngineBadge;
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart'
    show isOfflineEngineId;
import 'package:translation_repository/translation_repository.dart';

/// Above this text scale the selector drops its subtitle so the two lines
/// still fit the fixed-height app bar (the subtitle is also in the sheet).
const engineSubtitleMaxTextScale = 1.3;

/// App bar button showing the current engine; opens [EngineSheet].
class EngineSelectorButton extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final largeText =
        MediaQuery.textScalerOf(context).scale(1) > engineSubtitleMaxTextScale;
    return BlocBuilder<TranslateCubit, TranslateState>(
      buildWhen: (previous, current) =>
          previous.engine != current.engine ||
          previous.engines != current.engines,
      builder: (context, state) {
        final engine = state.engine;
        final name = engine?.name ?? l10n.translateEngineSheetTitle;
        final subtitle = largeText ? null : engine?.subtitle;
        return Tooltip(
          message: l10n.translateEngineSelectorTooltip,
          child: TextButton(
            key: const Key('translate_engine_selector'),
            // A hairline-outlined pill: clearly tappable, calm next to the
            // title.
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              padding: const EdgeInsetsDirectional.only(start: 12, end: 8),
              shape: StadiumBorder(
                side: BorderSide(color: AppPalette.of(context).hairline),
              ),
              backgroundColor: Colors.transparent,
              foregroundColor: theme.colorScheme.onSurface,
            ),
            onPressed: state.engines.isEmpty
                ? null
                : () => unawaited(showEngineSheet(context)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (engine != null) ...[
                  IconTheme.merge(
                    data: IconThemeData(color: theme.colorScheme.primary),
                    child: EngineIcon(engine: engine, size: 20),
                  ),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (subtitle != null && subtitle.isNotEmpty)
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: AppPalette.of(context).secondaryText,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.expand_more,
                  size: 20,
                  color: AppPalette.of(context).secondaryText,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Opens the engine picker as a modal bottom sheet.
/// The engine picker. In offline-first mode, opening it lets the app load
/// the Mozhi engine list it has deferred (`TranslateCubit
/// .loadDeferredEngines`).
Future<void> showEngineSheet(BuildContext context) {
  final cubit = context.read<TranslateCubit>();
  unawaited(cubit.loadDeferredEngines());
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) =>
        BlocProvider.value(value: cubit, child: const EngineSheet()),
  );
}

/// Location of the quality modes settings (Fast / Best engines).
const translateQualityLocation = '/settings/quality';

/// Engines grouped by kind: "On this device" (offline engines, with the
/// offline badge), "Mozhi engines (via host)", "Machine translation"
/// (DeepL API, LibreTranslate) and "AI models" (each with a privacy badge),
/// followed by links to the provider, instance and quality mode settings.
/// The quality modes entry explains how to get the Fast / Best toggle while
/// no quality engine is configured.
class EngineSheet extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = context.watch<TranslateCubit>().state;
    final offline = state.engines.where(isOnDeviceEngine).toList();
    List<TranslationEngine> ofKind(EngineKind kind) => [
      for (final engine in state.engines)
        if (engine.kind == kind && !isOnDeviceEngine(engine)) engine,
    ];
    final mozhi = ofKind(EngineKind.mozhi);
    final mt = ofKind(EngineKind.mt);
    final ai = ofKind(EngineKind.ai);
    final host = _instanceHost(mozhi);

    void select(TranslationEngine engine) {
      final cubit = context.read<TranslateCubit>();
      Navigator.of(context).pop();
      if (engine.id != state.engine?.id) unawaited(cubit.selectEngine(engine));
    }

    void open(String location) {
      final router = GoRouter.of(context);
      Navigator.of(context).pop();
      router.go(location);
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.3,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Semantics(
              header: true,
              child: Text(
                l10n.translateEngineSheetTitle,
                style: theme.textTheme.titleLarge,
              ),
            ),
          ),
          if (offline.isNotEmpty) ...[
            _SectionHeader(l10n.translateOfflineEnginesHeader),
            for (final engine in offline)
              _EngineTile(
                engine: engine,
                selected: engine.id == state.engine?.id,
                showSubtitle: true,
                onTap: () => select(engine),
              ),
          ],
          if (mozhi.isNotEmpty) ...[
            _SectionHeader(
              host == null
                  ? l10n.translateMozhiEnginesHeaderNoInstance
                  : l10n.translateMozhiEnginesHeader(host),
            ),
            for (final engine in mozhi)
              _EngineTile(
                engine: engine,
                selected: engine.id == state.engine?.id,
                showSubtitle: false,
                onTap: () => select(engine),
              ),
          ],
          if (mt.isNotEmpty) ...[
            _SectionHeader(l10n.translateMtServicesHeader),
            for (final engine in mt)
              _EngineTile(
                engine: engine,
                selected: engine.id == state.engine?.id,
                showSubtitle: true,
                onTap: () => select(engine),
              ),
          ],
          if (ai.isNotEmpty) ...[
            _SectionHeader(l10n.translateAiModelsHeader),
            for (final engine in ai)
              _EngineTile(
                engine: engine,
                selected: engine.id == state.engine?.id,
                showSubtitle: true,
                onTap: () => select(engine),
              ),
          ],
          const Divider(height: 24),
          ListTile(
            leading: const Icon(Icons.add),
            title: Text(l10n.translateAddAiProvider),
            onTap: () => open('/settings/providers'),
          ),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(l10n.translateManageInstances),
            onTap: () => open('/settings/instances'),
          ),
          ListTile(
            key: const Key('translate_quality_settings'),
            leading: const Icon(Icons.bolt),
            title: Text(l10n.translateQualityModesTitle),
            subtitle: Text(
              state.hasQualityModes
                  ? l10n.translateQualityModesChange
                  : l10n.translateQualityModesSetUp,
            ),
            onTap: () => open(translateQualityLocation),
          ),
        ],
      ),
    );
  }

  static String? _instanceHost(List<TranslationEngine> mozhi) {
    for (final engine in mozhi) {
      final subtitle = engine.subtitle?.trim();
      if (subtitle != null && subtitle.isNotEmpty) {
        return subtitle.replaceFirst(RegExp(r'^via\s+'), '');
      }
    }
    return null;
  }
}

class _SectionHeader extends StatelessWidget {
  const new(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
        child: Text(
          title,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

class _EngineTile extends StatelessWidget {
  const new({
    required this.engine,
    required this.selected,
    required this.showSubtitle,
    required this.onTap,
  });

  final TranslationEngine engine;
  final bool selected;
  final bool showSubtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final subtitle = engine.subtitle;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      selected: selected,
      leading: EngineIcon(engine: engine),
      title: Text(engine.name),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (isOnDeviceEngine(engine))
              const OfflineEngineBadge()
            else
              PrivacyBadge(engine: engine),
            if (showSubtitle && subtitle != null && subtitle.isNotEmpty)
              Text(subtitle),
          ],
        ),
      ),
      trailing: selected ? const Icon(Icons.check) : null,
      onTap: onTap,
    );
  }
}

/// Whether [engine] translates on this device: only offline engines
/// ([EngineKind.offline], ids `offline:<backend>`). Mozhi engines, AI
/// providers and machine translation services ([EngineKind.mt]: DeepL API,
/// LibreTranslate) are servers, even on the LAN.
bool isOnDeviceEngine(TranslationEngine engine) =>
    engine.isOffline || isOfflineEngineId(engine.id);

/// Icon for an engine kind (offline, local AI, cloud AI, Mozhi engine or
/// machine translation service).
class EngineIcon extends StatelessWidget {
  const new({required this.engine, this.size, super.key});

  final TranslationEngine engine;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final icon = switch (engine) {
      _ when isOnDeviceEngine(engine) => OfflineEngineBadge.icon,
      TranslationEngine(isAi: true, isLocal: true) => Icons.memory,
      TranslationEngine(isAi: true) => Icons.auto_awesome_outlined,
      // Mozhi engines and machine translation services.
      _ => Icons.translate,
    };
    return Icon(icon, size: size);
  }
}

/// Where the engine's text goes, from its [DataDestination]: On device,
/// Self-hosted (the user's own server, LAN, Tor), Public server (a public
/// Mozhi or LibreTranslate instance run by someone else) or Cloud (an AI
/// provider or DeepL).
///
/// [destination] defaults to `TranslationRepository.destinationOf` (when a
/// repository is provided); without one, local engines count as
/// self-hosted, Mozhi engines as public servers and other engines as cloud.
class PrivacyBadge extends StatelessWidget {
  const new({required this.engine, this.destination, super.key});

  final TranslationEngine engine;
  final DataDestination? destination;

  /// The destination of [engine] (see [PrivacyBadge]).
  static DataDestination destinationFor(
    BuildContext context,
    TranslationEngine engine,
  ) {
    try {
      return context.read<TranslationRepository>().destinationOf(engine.id);
    } on Object {
      // No repository (or a test double): judge by the engine.
      return switch (engine) {
        _ when isOnDeviceEngine(engine) => const OnDeviceDestination(),
        TranslationEngine(isLocal: true) => const SelfHostedDestination(''),
        TranslationEngine(isMozhi: true) => const PublicInstanceDestination(
          '',
        ),
        _ => CloudProviderDestination(engine.name),
      };
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final where = destination ?? destinationFor(context, engine);
    final (label, icon, background, foreground) = switch (where) {
      OnDeviceDestination() => (
        l10n.translateBadgeOnDevice,
        Icons.phone_android,
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      SelfHostedDestination() => (
        l10n.translateBadgeSelfHosted,
        Icons.dns_outlined,
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      PublicInstanceDestination() => (
        l10n.translateBadgePublic,
        Icons.public,
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      CloudProviderDestination() => (
        l10n.translateBadgeCloud,
        Icons.cloud_outlined,
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: foreground),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
