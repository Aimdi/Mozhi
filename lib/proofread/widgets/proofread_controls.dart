import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/cubit/proofread_cubit.dart';
import 'package:mozhi/proofread/widgets/proofread_labels.dart';
import 'package:translation_repository/translation_repository.dart';

/// Correction level, writing style, formality, engine and context controls.
class ProofreadControls extends StatefulWidget {
  const new({super.key});

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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<ProofreadCubit>();
    final state = context.watch<ProofreadCubit>().state;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
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
            onSelectionChanged: (selection) => cubit.setLevel(selection.first),
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
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
              ActionChip(
                avatar: const Icon(Icons.add_comment_outlined),
                label: Text(l10n.proofreadContextAdd),
                onPressed: () => setState(() => _showContext = true),
              ),
          ],
        ),
        if (_showContext)
          TextField(
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
          ),
      ],
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
            child: _MenuLabel(
              title: labelOf(option),
              subtitle: subtitleOf?.call(option),
            ),
          ),
      ],
      builder: (context, controller, child) => OutlinedButton.icon(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: Icon(icon, size: 18),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '$label: ',
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    TextSpan(text: labelOf(value)),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
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
