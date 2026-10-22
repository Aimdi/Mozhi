import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/offline.dart' show OfflineEngineBadge;
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/quality_toggle.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart'
    show isOfflineEngineId;
import 'package:translation_repository/translation_repository.dart';

/// App bar button showing the engine translating; opens [EngineSheet].
///
/// It names the engine only (a model id stays in the sheet). Once Fast
/// and Best are set up (`TranslateState.hasQualityModes`) the Fast | Best
/// toggle is the engine control and this button shows the engine of the
/// active mode as quieter, secondary text.
class EngineSelectorButton extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    return BlocBuilder<TranslateCubit, TranslateState>(
      buildWhen: (previous, current) =>
          previous.engine != current.engine ||
          previous.engines != current.engines ||
          previous.hasQualityModes != current.hasQualityModes,
      builder: (context, state) {
        final engine = state.engine;
        final name = engine?.name ?? l10n.translateEngineSheetTitle;
        final secondary = state.hasQualityModes;
        return Tooltip(
          message: l10n.translateEngineSelectorTooltip,
          child: TextButton(
            key: const Key('translate_engine_selector'),
            // An outlined pill (the control outline, 3:1): clearly tappable,
            // calm next to the title.
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              padding: const EdgeInsetsDirectional.only(start: 12, end: 8),
              shape: StadiumBorder(
                side: BorderSide(color: theme.colorScheme.outline),
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
                    data: IconThemeData(
                      color: secondary ? muted : theme.colorScheme.primary,
                    ),
                    child: EngineIcon(
                      engine: engine,
                      size: secondary ? 18 : 20,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    name,
                    key: const Key('translate_engine_selector_name'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: secondary
                        ? theme.textTheme.labelLarge?.copyWith(
                            color: muted,
                            fontWeight: FontWeight.w500,
                          )
                        : theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.expand_more, size: 20, color: muted),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The engine picker as a modal bottom sheet. In offline-first mode,
/// opening it lets the app load the Mozhi engine list it has deferred
/// (`TranslateCubit.loadDeferredEngines`).
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
const String translateQualityLocation = AppRoutes.quality;

/// A one-line note on what [engine] is good for (modest claims), or null
/// when there is nothing reliable to say (an unknown Mozhi engine).
String? translateEngineDescriptor(
  AppLocalizations l10n,
  TranslationEngine engine,
) {
  if (isOnDeviceEngine(engine)) return l10n.translateEngineAboutOnDevice;
  if (engine.isAi) {
    return engine.usesMtProfile
        ? l10n.translateEngineAboutAiTranslationModel
        : l10n.translateEngineAboutAi;
  }
  return switch (engine.mtService) {
    MtService.deepl => l10n.translateEngineAboutDeepl,
    MtService.libreTranslate => l10n.translateEngineAboutLibre,
    MtService.llm => null,
    null => switch (engine.mozhiEngine?.toLowerCase()) {
      'google' => l10n.translateEngineAboutGoogle,
      'deepl' => l10n.translateEngineAboutDeepl,
      'duckduckgo' || 'bing' => l10n.translateEngineAboutBing,
      'mymemory' => l10n.translateEngineAboutMyMemory,
      'reverso' => l10n.translateEngineAboutReverso,
      'yandex' => l10n.translateEngineAboutYandex,
      'libre' => l10n.translateEngineAboutLibre,
      _ => null,
    },
  };
}

/// The engine picker.
///
/// Once Fast and Best are set up (`TranslateState.hasQualityModes`) it
/// starts with the two modes, each with its engine (choosing one calls
/// `TranslateCubit.setQualityMode`), and "Custom engine…" opens the
/// engine list to pick the engine of the active mode
/// (`TranslateCubit.selectEngine`). Otherwise the list is shown right away
/// and picks the engine.
///
/// The list groups engines by kind: "On this device" (offline engines),
/// "Mozhi engines (via host)", "Machine translation" (DeepL API,
/// LibreTranslate) and "AI models". Each engine has a one-line note on
/// what it is good for ([translateEngineDescriptor]) and its details (an AI
/// model's id). Where the text goes ([PrivacyBadge]) is shown once in a
/// section's header when every engine of the section sends it to the same
/// kind of place (e.g. the Mozhi instance), else on each row. Links to the
/// provider, instance and quality mode settings follow; the quality modes
/// entry explains how to get the Fast / Best toggle while it is not set up.
class EngineSheet extends StatefulWidget {
  const new({super.key});

  @override
  State<EngineSheet> createState() => _EngineSheetState();
}

class _EngineSheetState extends State<EngineSheet> {
  /// Whether the engine list shows while Fast and Best are set up.
  bool _custom = false;

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
    final modes = state.hasQualityModes;
    final mode = state.qualityMode;
    final showList = !modes || _custom;

    void select(TranslationEngine engine) {
      final cubit = context.read<TranslateCubit>();
      Navigator.of(context).pop();
      if (engine.id != state.engine?.id) unawaited(cubit.selectEngine(engine));
    }

    void selectMode(QualityMode chosen) {
      final cubit = context.read<TranslateCubit>();
      Navigator.of(context).pop();
      if (chosen != mode) unawaited(cubit.setQualityMode(chosen));
    }

    // Pushed above the tabs, so back returns to the translate screen.
    void open(String location) {
      final router = GoRouter.of(context);
      Navigator.of(context).pop();
      unawaited(router.push<void>(location));
    }

    List<Widget> section(String title, List<TranslationEngine> engines) {
      if (engines.isEmpty) return const [];
      final shared = _sharedBadge(context, engines);
      return [
        _SectionHeader(title, badge: shared),
        for (final engine in engines)
          _EngineTile(
            engine: engine,
            selected: engine.id == state.engine?.id,
            badge: shared == null,
            // The instance is in the header already.
            showSubtitle: !engine.isMozhi,
            onTap: () => select(engine),
          ),
      ];
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
          if (modes) ...[
            _SectionHeader(l10n.translateQualityMode),
            for (final option in const [QualityMode.fast, QualityMode.best])
              if (state.qualityEngine(option) case final engine?)
                _ModeTile(
                  mode: option,
                  engine: engine,
                  selected: option == mode,
                  onTap: () => selectMode(option),
                ),
            ListTile(
              key: const Key('translate_engine_custom'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: const Icon(Icons.tune),
              title: Text(l10n.translateEngineCustom),
              subtitle: Text(
                mode == QualityMode.best
                    ? l10n.translateEngineCustomBest
                    : l10n.translateEngineCustomFast,
              ),
              trailing: Icon(_custom ? Icons.expand_less : Icons.expand_more),
              onTap: () => setState(() => _custom = !_custom),
            ),
          ],
          if (showList) ...[
            ...section(l10n.translateOfflineEnginesHeader, offline),
            ...section(
              host == null
                  ? l10n.translateMozhiEnginesHeaderNoInstance
                  : l10n.translateMozhiEnginesHeader(host),
              mozhi,
            ),
            ...section(l10n.translateMtServicesHeader, mt),
            ...section(l10n.translateAiModelsHeader, ai),
          ],
          const Divider(height: 24),
          ListTile(
            leading: const Icon(Icons.add),
            title: Text(l10n.translateAddAiProvider),
            onTap: () => open(AppRoutes.providers),
          ),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(l10n.translateManageInstances),
            onTap: () => open(AppRoutes.instances),
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

  /// The badge every engine of [engines] shares (the on-device badge, or
  /// where their text goes), or null when they differ.
  static Widget? _sharedBadge(
    BuildContext context,
    List<TranslationEngine> engines,
  ) {
    if (engines.every(isOnDeviceEngine)) return const OfflineEngineBadge();
    if (engines.any(isOnDeviceEngine)) return null;
    final destination = PrivacyBadge.destinationFor(context, engines.first);
    for (final engine in engines.skip(1)) {
      final other = PrivacyBadge.destinationFor(context, engine);
      if (other.runtimeType != destination.runtimeType) return null;
    }
    return PrivacyBadge(engine: engines.first, destination: destination);
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
  const new(this.title, {this.badge});

  final String title;

  /// Where the text of every engine of the section goes, when it is the
  /// same for all of them.
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final badge = this.badge;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          ?badge,
        ],
      ),
    );
  }
}

/// Fast or Best ([mode]) in the engine sheet, with its [engine] and what
/// it is good for.
class _ModeTile extends StatelessWidget {
  const new({
    required this.mode,
    required this.engine,
    required this.selected,
    required this.onTap,
  });

  final QualityMode mode;
  final TranslationEngine engine;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final about = translateEngineDescriptor(l10n, engine);
    return ListTile(
      key: ValueKey('translate_engine_mode_${mode.name}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      selected: selected,
      leading: Icon(translateQualityIcon(mode)),
      title: Text(translateQualityLabel(l10n, mode)),
      subtitle: Text(about == null ? engine.name : '${engine.name} · $about'),
      trailing: selected ? const Icon(Icons.check) : null,
      onTap: onTap,
    );
  }
}

class _EngineTile extends StatelessWidget {
  const new({
    required this.engine,
    required this.selected,
    required this.badge,
    required this.showSubtitle,
    required this.onTap,
  });

  final TranslationEngine engine;
  final bool selected;

  /// Whether the row shows where the text goes (its section does not).
  final bool badge;

  /// Whether the engine's details (an AI model's id, a server) show.
  final bool showSubtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final about = translateEngineDescriptor(context.l10n, engine);
    final subtitle = showSubtitle ? engine.subtitle?.trim() : null;
    final details = [
      ?about,
      if (subtitle != null && subtitle.isNotEmpty) subtitle,
    ];
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      selected: selected,
      leading: EngineIcon(engine: engine),
      title: Text(engine.name),
      subtitle: details.isEmpty && !badge
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (badge) PrivacyBadge(engine: engine),
                  if (details.isNotEmpty) Text(details.join(' · ')),
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
        TranslationEngine(isMozhi: true) => const PublicInstanceDestination(''),
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
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.badge)),
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
