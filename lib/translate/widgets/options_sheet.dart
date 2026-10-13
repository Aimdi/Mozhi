import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// Display name of a formality option.
String formalityLabel(AppLocalizations l10n, Formality value) =>
    switch (value) {
      Formality.automatic => l10n.translateFormalityDefault,
      Formality.more => l10n.translateFormalityMore,
      Formality.less => l10n.translateFormalityLess,
      Formality.preferMore => l10n.translateFormalityPreferMore,
      Formality.preferLess => l10n.translateFormalityPreferLess,
    };

/// Display name of a gender option.
String genderLabel(AppLocalizations l10n, Gender value) => switch (value) {
  Gender.unknown => l10n.translateGenderUnknown,
  Gender.masculine => l10n.translateGenderMasculine,
  Gender.feminine => l10n.translateGenderFeminine,
  Gender.neutral => l10n.translateGenderNeutral,
};

/// Display name of a reading level ("B1 · Intermediate").
String readingLevelLabel(AppLocalizations l10n, ReadingLevel level) =>
    switch (level) {
      ReadingLevel.standard =>
        '${l10n.translateReadingStandard} · '
            '${l10n.translateReadingStandardDescription}',
      ReadingLevel.a1 => 'A1 · ${l10n.translateReadingA1Description}',
      ReadingLevel.a2 => 'A2 · ${l10n.translateReadingA2Description}',
      ReadingLevel.b1 => 'B1 · ${l10n.translateReadingB1Description}',
      ReadingLevel.b2 => 'B2 · ${l10n.translateReadingB2Description}',
      ReadingLevel.c1 => 'C1 · ${l10n.translateReadingC1Description}',
      ReadingLevel.c2 => 'C2 · ${l10n.translateReadingC2Description}',
    };

/// Tune icon (AI engines only) with a dot badge when options differ from
/// the defaults. Opens [TranslationOptionsSheet].
class OptionsButton extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return BlocBuilder<TranslateCubit, TranslateState>(
      buildWhen: (previous, current) =>
          previous.engine != current.engine ||
          !identical(previous.options, current.options),
      builder: (context, state) {
        if (!(state.engine?.supportsOptions ?? false)) {
          return const SizedBox.shrink();
        }
        final modified = !optionsAreDefault(state.options);
        return IconButton(
          key: const Key('translate_options_button'),
          tooltip: modified
              ? l10n.translateOptionsModifiedTooltip
              : l10n.translateOptionsTooltip,
          icon: Badge(
            isLabelVisible: modified,
            smallSize: 8,
            child: const Icon(Icons.tune),
          ),
          onPressed: () => unawaited(showOptionsSheet(context)),
        );
      },
    );
  }
}

/// Opens the translation options bottom sheet.
Future<void> showOptionsSheet(BuildContext context) {
  final cubit = context.read<TranslateCubit>();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => BlocProvider.value(
      value: cubit,
      child: const TranslationOptionsSheet(),
    ),
  );
}

/// Style, formality, reading level, genders, context, formatting and
/// glossary (Kagi translation settings). Every change calls
/// `TranslateCubit.setOptions`.
class TranslationOptionsSheet extends StatefulWidget {
  const new({super.key});

  @override
  State<TranslationOptionsSheet> createState() =>
      _TranslationOptionsSheetState();
}

class _TranslationOptionsSheetState extends State<TranslationOptionsSheet> {
  late final TranslateCubit _cubit = context.read<TranslateCubit>();
  late final TextEditingController _context = TextEditingController(
    text: _cubit.state.options.context,
  );
  final _term = TextEditingController();
  final _termTarget = TextEditingController();
  Timer? _contextDebounce;

  @override
  void dispose() {
    _flushContext();
    _context.dispose();
    _term.dispose();
    _termTarget.dispose();
    super.dispose();
  }

  TranslationOptions get _options => _cubit.state.options;

  void _set(TranslationOptions options) => _cubit.setOptions(options);

  void _onContextChanged(String _) {
    _contextDebounce?.cancel();
    _contextDebounce = Timer(const Duration(milliseconds: 800), _flushContext);
  }

  void _flushContext() {
    _contextDebounce?.cancel();
    _contextDebounce = null;
    if (_cubit.isClosed) return;
    final value = _context.text.trim();
    if (value != _options.context) _set(_options.copyWith(context: value));
  }

  void _addTerm() {
    final term = _term.text.trim();
    final target = _termTarget.text.trim();
    if (term.isEmpty || target.isEmpty) return;
    _set(_options.copyWith(glossary: {..._options.glossary, term: target}));
    _term.clear();
    _termTarget.clear();
  }

  void _removeTerm(String term) {
    _set(_options.copyWith(glossary: Map.of(_options.glossary)..remove(term)));
  }

  void _reset() {
    _contextDebounce?.cancel();
    _context.clear();
    _set(TranslationOptions(instructions: _options.instructions));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        minChildSize: 0.4,
        builder: (context, controller) =>
            BlocBuilder<TranslateCubit, TranslateState>(
              buildWhen: (previous, current) =>
                  !identical(previous.options, current.options),
              builder: (context, state) {
                final options = state.options;
                return ListView(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Semantics(
                            header: true,
                            child: Text(
                              l10n.translateOptionsTitle,
                              style: theme.textTheme.titleLarge,
                            ),
                          ),
                        ),
                        TextButton(
                          key: const Key('translate_options_reset'),
                          onPressed: optionsAreDefault(options) ? null : _reset,
                          child: Text(l10n.translateOptionsReset),
                        ),
                      ],
                    ),
                    _Label(l10n.translateOptionsStyle),
                    // The default check icon marks the selected segment
                    // without relying on colour alone.
                    SegmentedButton<TranslationStyle>(
                      key: const Key('translate_options_style'),
                      segments: [
                        ButtonSegment(
                          value: TranslationStyle.natural,
                          label: Text(l10n.translateStyleNatural),
                        ),
                        ButtonSegment(
                          value: TranslationStyle.literal,
                          label: Text(l10n.translateStyleLiteral),
                        ),
                      ],
                      selected: {options.style},
                      onSelectionChanged: (selection) =>
                          _set(options.copyWith(style: selection.first)),
                    ),
                    _Label(l10n.translateOptionsFormality),
                    _Choices<Formality>(
                      groupLabel: l10n.translateOptionsFormality,
                      values: Formality.values,
                      selected: options.formality,
                      label: (value) => formalityLabel(l10n, value),
                      onSelected: (value) =>
                          _set(options.copyWith(formality: value)),
                    ),
                    _Label(l10n.translateOptionsReadingLevel),
                    MergeSemantics(
                      child: Semantics(
                        label: l10n.translateOptionsReadingLevel,
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 12,
                            ),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<ReadingLevel>(
                              key: const Key('translate_options_reading_level'),
                              isExpanded: true,
                              value: options.readingLevel,
                              items: [
                                for (final level in ReadingLevel.values)
                                  DropdownMenuItem(
                                    value: level,
                                    child: Text(
                                      readingLevelLabel(l10n, level),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (value) {
                                if (value == null) return;
                                _set(options.copyWith(readingLevel: value));
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                    _Label(l10n.translateOptionsSpeakerGender),
                    _Choices<Gender>(
                      groupLabel: l10n.translateOptionsSpeakerGender,
                      values: Gender.values,
                      selected: options.speakerGender,
                      label: (value) => genderLabel(l10n, value),
                      onSelected: (value) =>
                          _set(options.copyWith(speakerGender: value)),
                    ),
                    _Label(l10n.translateOptionsAddresseeGender),
                    _Choices<Gender>(
                      groupLabel: l10n.translateOptionsAddresseeGender,
                      values: Gender.values,
                      selected: options.addresseeGender,
                      label: (value) => genderLabel(l10n, value),
                      onSelected: (value) =>
                          _set(options.copyWith(addresseeGender: value)),
                    ),
                    _Label(l10n.translateOptionsContext),
                    Semantics(
                      label: l10n.translateOptionsContext,
                      child: TextField(
                        key: const Key('translate_options_context'),
                        controller: _context,
                        minLines: 1,
                        maxLines: 4,
                        onChanged: _onContextChanged,
                        onSubmitted: (_) => _flushContext(),
                        onTapOutside: (_) => _flushContext(),
                        decoration: InputDecoration(
                          hintText: l10n.translateOptionsContextHint,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      key: const Key('translate_options_formatting'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(l10n.translateOptionsPreserveFormatting),
                      subtitle: Text(
                        l10n.translateOptionsPreserveFormattingDescription,
                      ),
                      value: options.preserveFormatting,
                      onChanged: (value) =>
                          _set(options.copyWith(preserveFormatting: value)),
                    ),
                    _Label(l10n.translateOptionsGlossary),
                    Text(
                      l10n.translateOptionsGlossaryDescription,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    for (final MapEntry(:key, :value)
                        in options.glossary.entries)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          l10n.translateGlossaryEntry(key, value),
                          semanticsLabel: l10n.translateGlossaryEntrySemantics(
                            key,
                            value,
                          ),
                        ),
                        trailing: IconButton(
                          tooltip: l10n.translateGlossaryRemove(key),
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _removeTerm(key),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const Key('translate_glossary_source'),
                            controller: _term,
                            textInputAction: TextInputAction.next,
                            decoration: InputDecoration(
                              labelText: l10n.translateGlossarySource,
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 4),
                          child: Icon(Icons.arrow_forward, size: 18),
                        ),
                        Expanded(
                          child: TextField(
                            key: const Key('translate_glossary_target'),
                            controller: _termTarget,
                            onSubmitted: (_) => _addTerm(),
                            decoration: InputDecoration(
                              labelText: l10n.translateGlossaryTarget,
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                        IconButton(
                          key: const Key('translate_glossary_add'),
                          tooltip: l10n.translateGlossaryAdd,
                          icon: const Icon(Icons.add),
                          onPressed: _addTerm,
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const new(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(
          text,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

class _Choices<T> extends StatelessWidget {
  const new({
    required this.groupLabel,
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
  });

  /// Names the group for screen readers (the visible label above it is
  /// not associated with the chips).
  final String groupLabel;
  final List<T> values;
  final T selected;
  final String Function(T value) label;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: groupLabel,
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final value in values)
            // The check mark shows the selection without relying on colour.
            ChoiceChip(
              label: Text(label(value)),
              selected: value == selected,
              showCheckmark: true,
              onSelected: (_) => onSelected(value),
            ),
        ],
      ),
    );
  }
}
