import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/cubit/proofread_cubit.dart';
import 'package:mozhi/proofread/widgets/proofread_labels.dart';
import 'package:translation_repository/translation_repository.dart';

/// Correction level, writing style, formality, reading level, regional
/// variety, engine and context controls.
///
/// The options sit in a collapsible "Options" card whose subtitle sums up
/// the current choices; menus are laid out as a grid of equal tiles.
class ProofreadControls extends StatefulWidget {
  const new({this.initiallyExpanded = false, super.key});

  /// Whether the options start expanded (they always do while a context is
  /// set).
  final bool initiallyExpanded;

  @override
  State<ProofreadControls> createState() => _ProofreadControlsState();
}

class _ProofreadControlsState extends State<ProofreadControls> {
  late final TextEditingController _contextController;
  late bool _showContext;

  @override
  void initState() {
    super.initState();
    final initial = context.read<ProofreadCubit>().state.context;
    _contextController = TextEditingController(text: initial);
    _showContext = initial.isNotEmpty;
  }

  @override
  void dispose() {
    _contextController.dispose();
    super.dispose();
  }

  /// Whether every correction level label fits in its segment of a
  /// [SegmentedButton] that is [width] wide, at the current text scale.
  bool _levelLabelsFit(BuildContext context, double width) {
    final l10n = context.l10n;
    final textScaler = MediaQuery.textScalerOf(context);
    final style = Theme.of(context).textTheme.labelLarge;
    final textDirection = Directionality.of(context);
    var widest = 0.0;
    for (final level in CorrectionLevel.values) {
      final painter = TextPainter(
        text: TextSpan(
          text: l10n.proofreadCorrectionLevel(level),
          style: style,
        ),
        textDirection: textDirection,
        textScaler: textScaler,
        maxLines: 1,
      )..layout();
      if (painter.width > widest) widest = painter.width;
      painter.dispose();
    }
    // Segment padding (12 per side at most) plus the dividing border.
    const segmentChrome = 26.0;
    return (widest + segmentChrome) * CorrectionLevel.values.length <= width;
  }

  /// One line naming the current choices: the correction level and style,
  /// plus every option that differs from its default.
  String _summary(BuildContext context, ProofreadState state) {
    final l10n = context.l10n;
    return [
      l10n.proofreadCorrectionLevel(state.correctionLevel),
      l10n.proofreadWritingStyle(state.writingStyle),
      if (state.formality != Formality.automatic)
        l10n.proofreadFormality(state.formality),
      if (state.readingLevel != ReadingLevel.standard)
        l10n.proofreadReadingLevel(state.readingLevel),
      if (state.variety != null) l10n.proofreadVariety(state.variety),
      if (state.context.trim().isNotEmpty) l10n.proofreadContextLabel,
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final cubit = context.read<ProofreadCubit>();

    return BlocBuilder<ProofreadCubit, ProofreadState>(
      buildWhen: (previous, current) =>
          previous.correctionLevel != current.correctionLevel ||
          previous.writingStyle != current.writingStyle ||
          previous.formality != current.formality ||
          previous.readingLevel != current.readingLevel ||
          previous.variety != current.variety ||
          previous.context.trim().isEmpty != current.context.trim().isEmpty ||
          // Engine equality ignores the model and locality badge.
          !identical(previous.engine, current.engine) ||
          !identical(previous.availableEngines, current.availableEngines),
      builder: (context, state) => Card.filled(
        margin: EdgeInsets.zero,
        color: colors.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: ExpansionTile(
          key: const Key('proofread_options'),
          initiallyExpanded: widget.initiallyExpanded || _showContext,
          maintainState: true,
          shape: const Border(),
          collapsedShape: const Border(),
          tilePadding: const EdgeInsetsDirectional.fromSTEB(16, 4, 12, 4),
          leading: Icon(Icons.tune, color: colors.primary),
          title: Text(l10n.proofreadOptionsTitle),
          subtitle: Text(
            _summary(context, state),
            key: const Key('proofread_options_summary'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          childrenPadding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 16),
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                // Narrow screens or large text: a menu instead of truncated
                // segment labels.
                final segmented = _levelLabelsFit(
                  context,
                  constraints.maxWidth,
                );
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 12,
                  children: [
                    if (segmented)
                      Semantics(
                        label: l10n.proofreadLevelLabel,
                        container: true,
                        child: SegmentedButton<CorrectionLevel>(
                          showSelectedIcon: false,
                          segments: [
                            for (final level in CorrectionLevel.values)
                              ButtonSegment(
                                value: level,
                                tooltip: l10n.proofreadLevelDescription(level),
                                label: Text(
                                  l10n.proofreadCorrectionLevel(level),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          selected: {state.correctionLevel},
                          onSelectionChanged: (selection) =>
                              cubit.setLevel(selection.first),
                        ),
                      ),
                    _buildMenus(
                      context,
                      state,
                      showLevel: !segmented,
                      width: constraints.maxWidth,
                    ),
                    if (_showContext) _buildContextField(context),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMenus(
    BuildContext context,
    ProofreadState state, {
    required bool showLevel,
    required double width,
  }) {
    final l10n = context.l10n;
    final cubit = context.read<ProofreadCubit>();
    final tiles = <Widget>[
      if (showLevel)
        ProofreadMenuButton<CorrectionLevel>(
          key: const Key('proofread_level_menu'),
          icon: Icons.tune,
          label: l10n.proofreadLevelLabel,
          value: state.correctionLevel,
          values: CorrectionLevel.values,
          labelOf: l10n.proofreadCorrectionLevel,
          subtitleOf: l10n.proofreadLevelDescription,
          onSelected: cubit.setLevel,
        ),
      ProofreadMenuButton<WritingStyle>(
        key: const Key('proofread_style_menu'),
        icon: Icons.history_edu_outlined,
        label: l10n.proofreadStyleLabel,
        value: state.writingStyle,
        values: WritingStyle.values,
        labelOf: l10n.proofreadWritingStyle,
        onSelected: cubit.setStyle,
      ),
      ProofreadMenuButton<Formality>(
        key: const Key('proofread_formality_menu'),
        icon: Icons.business_center_outlined,
        label: l10n.proofreadFormalityLabel,
        value: state.formality,
        values: Formality.values,
        labelOf: l10n.proofreadFormality,
        onSelected: cubit.setFormality,
      ),
      ProofreadMenuButton<ReadingLevel>(
        key: const Key('proofread_reading_level_menu'),
        icon: Icons.school_outlined,
        label: l10n.proofreadReadingLevelLabel,
        value: state.readingLevel,
        values: ReadingLevel.values,
        labelOf: l10n.proofreadReadingLevel,
        subtitleOf: l10n.proofreadReadingLevelDescription,
        onSelected: cubit.setReadingLevel,
      ),
      ProofreadMenuButton<ProofreadVariety?>(
        key: const Key('proofread_variety_menu'),
        icon: Icons.public,
        label: l10n.proofreadVarietyLabel,
        value: state.variety,
        values: const [null, ...ProofreadVariety.values],
        labelOf: l10n.proofreadVariety,
        subtitleOf: (variety) =>
            variety == null ? l10n.proofreadVarietyKeepDescription : null,
        onSelected: cubit.setVariety,
      ),
      if (state.availableEngines.length > 1 && state.engine != null)
        ProofreadMenuButton<TranslationEngine>(
          key: const Key('proofread_engine_menu'),
          icon: Icons.auto_awesome_outlined,
          label: l10n.proofreadEngineLabel,
          value: state.engine!,
          values: state.availableEngines,
          labelOf: (engine) => engine.name,
          subtitleOf: (engine) => engine.subtitle,
          trailingOf: (engine) => engine.isLocal
              ? Tooltip(
                  message: l10n.proofreadLocalEngine,
                  child: const Icon(Icons.lan_outlined, size: 18),
                )
              : null,
          onSelected: cubit.setEngine,
        ),
      if (!_showContext)
        ProofreadOptionTile(
          key: const Key('proofread_context_add'),
          icon: Icons.add_comment_outlined,
          title: l10n.proofreadContextAdd,
          onPressed: () => setState(() => _showContext = true),
        ),
    ];
    // Two equal columns when both fit (also at large text sizes), else one.
    final minTileWidth = MediaQuery.textScalerOf(context).scale(180);
    const gap = 8.0;
    final columns = width >= minTileWidth * 2 + gap ? 2 : 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: gap,
      children: [
        for (var i = 0; i < tiles.length; i += columns)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: gap,
              children: [
                for (var j = i; j < i + columns; j++)
                  Expanded(
                    child: j < tiles.length ? tiles[j] : const SizedBox(),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildContextField(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<ProofreadCubit>();
    return TextField(
      key: const Key('proofread_context'),
      controller: _contextController,
      onChanged: cubit.setContext,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(
        labelText: l10n.proofreadContextLabel,
        hintText: l10n.proofreadContextHint,
        prefixIcon: const Icon(Icons.comment_outlined),
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          tooltip: l10n.commonClear,
          icon: const Icon(Icons.clear),
          onPressed: () {
            _contextController.clear();
            cubit.setContext('');
            setState(() => _showContext = false);
          },
        ),
      ),
    );
  }
}

/// A compact "Label: value" button that opens a menu of [values].
class ProofreadMenuButton<T> extends StatelessWidget {
  const new({
    required this.icon,
    required this.label,
    required this.value,
    required this.values,
    required this.labelOf,
    required this.onSelected,
    this.subtitleOf,
    this.trailingOf,
    super.key,
  });

  final IconData icon;
  final String label;
  final T value;
  final List<T> values;
  final String Function(T value) labelOf;
  final String? Function(T value)? subtitleOf;
  final Widget? Function(T value)? trailingOf;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MenuAnchor(
      menuChildren: [
        for (final option in values)
          MenuItemButton(
            leadingIcon: Icon(
              Icons.check,
              color: option == value ? null : Colors.transparent,
            ),
            trailingIcon: trailingOf?.call(option),
            onPressed: () => onSelected(option),
            // The check mark is decorative: expose the choice as state.
            child: Semantics(
              selected: option == value,
              inMutuallyExclusiveGroup: true,
              child: _MenuLabel(
                title: labelOf(option),
                subtitle: subtitleOf?.call(option),
              ),
            ),
          ),
      ],
      builder: (context, controller, child) => ProofreadOptionTile(
        icon: icon,
        label: label,
        title: labelOf(value),
        trailing: Icon(
          Icons.arrow_drop_down,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// A uniform option tile: an [icon], an optional small [label] above the
/// [title] (the current value) and an optional [trailing] widget.
///
/// Texts wrap rather than being cut off at large text sizes or on narrow
/// screens (WCAG 1.4.4, 1.4.10).
class ProofreadOptionTile extends StatelessWidget {
  const new({
    required this.icon,
    required this.title,
    required this.onPressed,
    this.label,
    this.trailing,
    super.key,
  });

  final IconData icon;
  final String? label;
  final String title;
  final Widget? trailing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final label = this.label;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(color: colors.outlineVariant),
    );
    return Material(
      color: colors.surface,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        customBorder: shape,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 8, 8),
            child: Row(
              spacing: 12,
              children: [
                Icon(icon, size: 20, color: colors.primary),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (label != null)
                        Text(
                          label,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      Text(
                        title,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: colors.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuLabel extends StatelessWidget {
  const new({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    if (subtitle == null || subtitle.isEmpty) return Text(title);
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title),
        Text(
          subtitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
