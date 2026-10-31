import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart' show AppLook;
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';

/// Icon of a quality mode.
IconData translateQualityIcon(QualityMode mode) => switch (mode) {
  QualityMode.off => Icons.speed,
  QualityMode.fast => Icons.bolt,
  QualityMode.best => Icons.workspace_premium_outlined,
};

/// Name of a quality mode: "Fast" or "Best" ([QualityMode.off], the usual
/// engine, is never offered as a mode of its own: "Quality mode").
String translateQualityLabel(AppLocalizations l10n, QualityMode mode) =>
    switch (mode) {
      QualityMode.off => l10n.translateQualityMode,
      QualityMode.fast => l10n.translateQualityFast,
      QualityMode.best => l10n.translateQualityBest,
    };

/// How [QualityToggle] is drawn.
enum QualityToggleLayout {
  /// Segments with icon and label.
  labels,

  /// Icon-only segments (narrow app bars).
  icons,

  /// One icon button showing the mode, with a menu of the modes (app bars
  /// too narrow for segments).
  menu,
}

/// Kagi-style Fast / Best toggle next to the engine selector (while the
/// empty screen's greeting shows [QualityChip], the app bar leaves it out).
///
/// Once Fast and Best are set up (`TranslateState.hasQualityModes`) it is
/// the engine control: one of the two is always selected, and choosing the
/// other calls `TranslateCubit.setQualityMode`. Nothing at all before that
/// (the engine sheet links to the quality modes settings).
///
/// Every segment and menu entry names its engine (tooltip or second line)
/// and has a spoken name; the selection is shown with a check mark.
class QualityToggle extends StatelessWidget {
  const new({this.layout = QualityToggleLayout.labels, super.key});

  /// Narrowest app bar title (engine selector plus toggle) that still fits
  /// [QualityToggleLayout.icons]; below it use [QualityToggleLayout.menu].
  static const double iconsMinWidth = 300;

  /// Narrowest app bar title (screen title, engine selector and toggle)
  /// that fits [QualityToggleLayout.labels] at the normal text size; it
  /// grows with the text size.
  static const double labelsMinWidth = 520;

  /// The layout for an app bar title area [width] wide: labelled segments
  /// when it also holds the screen title ([withTitle]) and is at least
  /// [labelsMinWidth] (scaled by [textScaler]) wide, icon-only segments
  /// from [iconsMinWidth], else the menu.
  static QualityToggleLayout layoutFor(
    double width, {
    TextScaler textScaler = TextScaler.noScaling,
    bool withTitle = true,
  }) {
    final scale = textScaler.scale(_referenceFontSize) / _referenceFontSize;
    if (withTitle && width >= labelsMinWidth * scale) {
      return QualityToggleLayout.labels;
    }
    return width >= iconsMinWidth
        ? QualityToggleLayout.icons
        : QualityToggleLayout.menu;
  }

  /// Font size the text scale is measured at (segment labels).
  static const double _referenceFontSize = 14;

  final QualityToggleLayout layout;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TranslateCubit, TranslateState>(
      buildWhen: (previous, current) =>
          previous.qualityMode != current.qualityMode ||
          previous.fastEngine != current.fastEngine ||
          previous.bestEngine != current.bestEngine,
      builder: (context, state) {
        if (!state.hasQualityModes) return const SizedBox.shrink();
        void select(QualityMode mode) =>
            unawaited(context.read<TranslateCubit>().setQualityMode(mode));
        return Padding(
          padding: const EdgeInsetsDirectional.only(start: 8),
          child: layout == QualityToggleLayout.menu
              ? _QualityMenu(state: state, onSelected: select)
              : _QualitySegments(
                  state: state,
                  showLabels: layout == QualityToggleLayout.labels,
                  onSelected: select,
                ),
        );
      },
    );
  }
}

/// Tooltip of a mode's segment ("Fast: translate with Google").
String _modeTooltip(
  AppLocalizations l10n,
  TranslateState state,
  QualityMode mode,
) {
  final engine = state.qualityEngine(mode)?.name ?? '';
  return mode == QualityMode.fast
      ? l10n.translateQualityFastTooltip(engine)
      : l10n.translateQualityBestTooltip(engine);
}

class _QualitySegments extends StatelessWidget {
  const new({
    required this.state,
    required this.showLabels,
    required this.onSelected,
  });

  final TranslateState state;
  final bool showLabels;
  final ValueChanged<QualityMode> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final modes = state.availableQualityModes.where(
      (mode) => mode != QualityMode.off,
    );
    final mode = state.qualityMode;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: l10n.translateQualityMode,
      child: SegmentedButton<QualityMode>(
        key: const Key('translate_quality_toggle'),
        segments: [
          for (final mode in modes)
            ButtonSegment(
              value: mode,
              tooltip: _modeTooltip(l10n, state, mode),
              icon: Icon(
                translateQualityIcon(mode),
                // Icon-only segments still need a spoken name.
                semanticLabel: showLabels
                    ? null
                    : translateQualityLabel(l10n, mode),
              ),
              label: showLabels
                  ? Text(translateQualityLabel(l10n, mode))
                  : null,
            ),
        ],
        selected: {if (mode != QualityMode.off) mode},
        // Only for the moment before the cubit moves a saved "usual
        // engine" to a mode; a selected segment stays selected.
        emptySelectionAllowed: mode == QualityMode.off,
        style: const ButtonStyle(
          tapTargetSize: MaterialTapTargetSize.padded,
          visualDensity: VisualDensity.standard,
        ),
        onSelectionChanged: (selection) {
          if (selection.isNotEmpty) onSelected(selection.first);
        },
      ),
    );
  }
}

/// The entries of the quality menu: Fast and Best with their engines, the
/// current one checked.
List<PopupMenuEntry<QualityMode>> _menuItems(
  AppLocalizations l10n,
  TranslateState state,
) => [
  for (final option in state.availableQualityModes)
    CheckedPopupMenuItem(
      key: ValueKey('translate_quality_${option.name}'),
      value: option,
      checked: option == state.qualityMode,
      child: _MenuEntry(
        label: translateQualityLabel(l10n, option),
        engine: state.qualityEngine(option)?.name,
      ),
    ),
];

class _QualityMenu extends StatelessWidget {
  const new({required this.state, required this.onSelected});

  final TranslateState state;
  final ValueChanged<QualityMode> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final mode = state.qualityMode;
    final on = mode != QualityMode.off;
    return PopupMenuButton<QualityMode>(
      key: const Key('translate_quality_menu'),
      tooltip: l10n.translateQualityMenuTooltip(
        translateQualityLabel(l10n, mode),
      ),
      icon: Icon(translateQualityIcon(mode)),
      style: on
          ? IconButton.styleFrom(
              backgroundColor: theme.colorScheme.secondaryContainer,
              foregroundColor: theme.colorScheme.onSecondaryContainer,
            )
          : null,
      initialValue: mode,
      onSelected: (selected) {
        if (selected != mode) onSelected(selected);
      },
      itemBuilder: (context) => _menuItems(l10n, state),
    );
  }
}

/// The quality mode as an outlined pill, like Kagi Translate's quality
/// chip at the top of its start screen: the mode's icon and name, then the
/// engine translating as secondary text ("⚡ Fast · Google"). The empty
/// translate screen shows it in its greeting (`TranslateHero`) instead of
/// the app bar's [QualityToggle].
///
/// Tapping it opens the menu of [QualityToggleLayout.menu]: Fast and Best
/// with their engines, the current one checked; choosing the other mode
/// calls `TranslateCubit.setQualityMode`. For screen readers it is that
/// menu button too ("Quality mode: Fast", collapsed or expanded). Nothing
/// at all until Fast and Best are set up.
class QualityChip extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TranslateCubit, TranslateState>(
      buildWhen: (previous, current) =>
          previous.qualityMode != current.qualityMode ||
          previous.fastEngine != current.fastEngine ||
          previous.bestEngine != current.bestEngine ||
          previous.engine != current.engine,
      builder: (context, state) {
        if (!state.hasQualityModes) return const SizedBox.shrink();
        final l10n = context.l10n;
        final muted = AppPalette.of(context).secondaryText;
        final engine = state.engine?.name;
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final mode = state.qualityMode;
        final label = translateQualityLabel(l10n, mode);
        return PopupMenuButton<QualityMode>(
          key: const Key('translate_quality_chip'),
          tooltip: l10n.translateQualityMenuTooltip(label),
          padding: const EdgeInsetsDirectional.only(start: 14, end: 18),
          style: ButtonStyle(
            shape: WidgetStatePropertyAll(
              AppLook.of(context).control
                  .copyWith(side: BorderSide(color: scheme.outline)),
            ),
            foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
            textStyle: WidgetStatePropertyAll(
              theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            minimumSize: const WidgetStatePropertyAll(Size(48, 40)),
            tapTargetSize: MaterialTapTargetSize.padded,
          ),
          initialValue: mode,
          onSelected: (selected) {
            if (selected == mode) return;
            unawaited(context.read<TranslateCubit>().setQualityMode(selected));
          },
          itemBuilder: (context) => _menuItems(l10n, state),
          icon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(translateQualityIcon(mode), size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              // The tooltip names the button ("Quality mode: Fast"), as in
              // the app bar's menu; the engine is in its menu entries.
              Flexible(
                child: ExcludeSemantics(
                  child: Text.rich(
                    TextSpan(
                      text: label,
                      children: [
                        if (engine != null)
                          TextSpan(
                            text: ' · $engine',
                            style: TextStyle(
                              color: muted,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                      ],
                    ),
                    key: const Key('translate_quality_chip_label'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MenuEntry extends StatelessWidget {
  const new({required this.label, this.engine});

  final String label;
  final String? engine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final engine = this.engine;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        if (engine != null)
          Text(
            engine,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}
