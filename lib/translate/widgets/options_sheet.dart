import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/presets/presets.dart' show PresetPicker, PresetsCubit;
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/engine_selector.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// Display name of a formality option.
String translateFormalityLabel(AppLocalizations l10n, Formality value) =>
    switch (value) {
      Formality.automatic => l10n.translateFormalityDefault,
      Formality.more => l10n.translateFormalityMore,
      Formality.less => l10n.translateFormalityLess,
      Formality.preferMore => l10n.translateFormalityPreferMore,
      Formality.preferLess => l10n.translateFormalityPreferLess,
    };

/// Display name of a gender option.
String translateGenderLabel(AppLocalizations l10n, Gender value) =>
    switch (value) {
      Gender.unknown => l10n.translateGenderUnknown,
      Gender.masculine => l10n.translateGenderMasculine,
      Gender.feminine => l10n.translateGenderFeminine,
      Gender.neutral => l10n.translateGenderNeutral,
    };

/// Display name of a reading level ("B1 · Intermediate").
String translateReadingLevelLabel(AppLocalizations l10n, ReadingLevel level) =>
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

/// Tune icon (at the start of the language bar) with a dot badge when
/// options differ from the defaults. Opens [TranslationOptionsSheet], for
/// every engine: the sheet says when the engine does not apply them.
class OptionsButton extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return BlocBuilder<TranslateCubit, TranslateState>(
      buildWhen: (previous, current) =>
          !identical(previous.options, current.options),
      builder: (context, state) {
        final modified = !optionsAreDefault(state.options);
        return IconButton(
          key: const Key('translate_options_button'),
          tooltip: modified
              ? l10n.translateOptionsModifiedTooltip
              : l10n.translateOptionsTooltip,
          color: Theme.of(context).colorScheme.primary,
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

/// Location of the presets page ("Manage presets" in the preset picker).
const String translatePresetsLocation = AppRoutes.presets;

/// Location of the AI provider settings ("Add AI provider" in the note of
/// the options sheet, like the engine picker's).
const String translateProvidersLocation = AppRoutes.providers;

/// What the options sheet asks [showOptionsSheet] to do once it is closed.
enum OptionsSheetAction {
  /// Open the engine picker (to choose an AI translator).
  chooseEngine,
}

/// The app-wide [PresetsCubit], or null when none is provided (the preset
/// picker is then not offered).
PresetsCubit? _presetsCubitOf(BuildContext context) {
  try {
    return context.read<PresetsCubit>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// Opens the translation options bottom sheet; when its note's "Choose an
/// AI translator" closed it, the engine picker follows ([showEngineSheet]).
Future<void> showOptionsSheet(BuildContext context) async {
  final cubit = context.read<TranslateCubit>();
  final presets = _presetsCubitOf(context);
  final action = await showModalBottomSheet<OptionsSheetAction>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => BlocProvider.value(
      value: cubit,
      child: presets == null
          ? const TranslationOptionsSheet()
          : BlocProvider.value(
              value: presets,
              child: const TranslationOptionsSheet(),
            ),
    ),
  );
  if (action == OptionsSheetAction.chooseEngine && context.mounted) {
    await showEngineSheet(context);
  }
}

/// The note of the options sheet for [engine], or null when it applies
/// every option: AI engines with the general prompt profile do; DeepL
/// (`TranslationEngine.supportsFormality`) applies the formality, the
/// context, the formatting and the glossary; other engines none.
String? translateOptionsNote(AppLocalizations l10n, TranslationEngine engine) {
  if (engine.supportsOptions) return null;
  return engine.supportsFormality
      ? l10n.translateOptionsDeeplNeedAi(engine.name)
      : l10n.translateOptionsNeedAi(engine.name);
}

/// Preset, style, formality (with free-text formality notes while a
/// formality is chosen), reading level, genders, context, formatting and
/// glossary (Kagi translation settings), for every engine. Every change
/// calls `TranslateCubit.setOptions` (which saves it); the text fields are
/// debounced. "Done" (at the top end of the header, as on Kagi
/// Translate) closes the sheet; "Reset to defaults" is at the bottom.
///
/// When the engine does not apply every option ([translateOptionsNote]:
/// Mozhi, offline and most machine translation engines translate plainly),
/// a note at the top says which options need an AI translator; the
/// choices are kept and apply once one is used. Its action opens the
/// engine picker ([OptionsSheetAction.chooseEngine]) or, while no engine
/// applies the options, the AI provider settings.
///
/// The preset picker ([PresetPicker]) is shown when a [PresetsCubit] is
/// provided above; choosing a preset replaces the settings (the glossary
/// is kept).
class TranslationOptionsSheet extends StatefulWidget {
  const new({super.key});

  /// Longest formality notes (`TranslationOptions.formalityContext`).
  static const formalityNotesMaxLength = 2000;

  @override
  State<TranslationOptionsSheet> createState() =>
      _TranslationOptionsSheetState();
}

class _TranslationOptionsSheetState extends State<TranslationOptionsSheet> {
  late final TranslateCubit _cubit = context.read<TranslateCubit>();
  late final TextEditingController _context = TextEditingController(
    text: _cubit.state.options.context,
  );
  late final TextEditingController _formalityNotes = TextEditingController(
    text: _cubit.state.options.formalityContext,
  );
  final _term = TextEditingController();
  final _termTarget = TextEditingController();
  Timer? _contextDebounce;
  Timer? _formalityNotesDebounce;

  @override
  void dispose() {
    _flushContext();
    _flushFormalityNotes();
    _context.dispose();
    _formalityNotes.dispose();
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

  void _onFormalityNotesChanged(String _) {
    _formalityNotesDebounce?.cancel();
    _formalityNotesDebounce = Timer(
      const Duration(milliseconds: 800),
      _flushFormalityNotes,
    );
  }

  void _flushFormalityNotes() {
    _formalityNotesDebounce?.cancel();
    _formalityNotesDebounce = null;
    if (_cubit.isClosed) return;
    final value = _formalityNotes.text.trim();
    if (value != _options.formalityContext) {
      _set(_options.copyWith(formalityContext: value));
    }
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
    _formalityNotesDebounce?.cancel();
    _context.clear();
    _formalityNotes.clear();
    _set(TranslationOptions(instructions: _options.instructions));
  }

  /// A preset replaces every setting, including a context or formality
  /// notes still being typed.
  void _applyPreset(TranslationOptions options) {
    _contextDebounce?.cancel();
    _contextDebounce = null;
    _formalityNotesDebounce?.cancel();
    _formalityNotesDebounce = null;
    if (_context.text.trim() != options.context) {
      _context.text = options.context;
    }
    if (_formalityNotes.text.trim() != options.formalityContext) {
      _formalityNotes.text = options.formalityContext;
    }
    _set(options);
  }

  void _managePresets(GoRouter router) {
    Navigator.of(context).pop();
    unawaited(router.push<void>(translatePresetsLocation));
  }

  void _chooseAiEngine() =>
      Navigator.of(context).pop(OptionsSheetAction.chooseEngine);

  void _addAiProvider(GoRouter router) {
    Navigator.of(context).pop();
    unawaited(router.push<void>(translateProvidersLocation));
  }

  /// Saves what is still being typed and closes the sheet.
  void _done() {
    _flushContext();
    _flushFormalityNotes();
    Navigator.of(context).maybePop();
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
        builder: (context, controller) => Column(
          children: [
            // Kagi's header: the title and "Done", always in view.
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(24, 0, 12, 4),
              child: Row(
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
                    key: const Key('translate_options_done'),
                    onPressed: _done,
                    style: TextButton.styleFrom(
                      textStyle: theme.textTheme.titleMedium,
                    ),
                    child: Text(l10n.translateOptionsDone),
                  ),
                ],
              ),
            ),
            Expanded(
              child: BlocBuilder<TranslateCubit, TranslateState>(
                buildWhen: (previous, current) =>
                    !identical(previous.options, current.options) ||
                    previous.engine != current.engine ||
                    previous.engines != current.engines,
                builder: (context, state) {
                  final options = state.options;
                  final presets = _presetsCubitOf(context);
                  final router = GoRouter.maybeOf(context);
                  final engine = state.engine;
                  final note = engine == null
                      ? null
                      : translateOptionsNote(l10n, engine);
                  return ListView(
                    controller: controller,
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                    children: [
                      if (note != null)
                        _AiNote(
                          message: note,
                          action: state.engines.any((e) => e.supportsOptions)
                              ? (
                                  label: l10n.translateOptionsChooseAi,
                                  onPressed: _chooseAiEngine,
                                )
                              : router == null
                              ? null
                              : (
                                  label: l10n.translateAddAiProvider,
                                  onPressed: () => _addAiProvider(router),
                                ),
                        ),
                      if (presets != null) ...[
                        _Label(l10n.translateOptionsPreset),
                        PresetPicker(
                          key: const Key('translate_options_presets'),
                          value: options,
                          onChanged: _applyPreset,
                          onManagePresets: router == null
                              ? null
                              : () => _managePresets(router),
                        ),
                      ],
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
                        label: (value) => translateFormalityLabel(l10n, value),
                        onSelected: (value) =>
                            _set(options.copyWith(formality: value)),
                      ),
                      if (options.formality != Formality.automatic) ...[
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('translate_options_formality_notes'),
                          controller: _formalityNotes,
                          enableIMEPersonalizedLearning: imeLearningAllowed(
                            context,
                          ),
                          minLines: 1,
                          maxLines: 3,
                          maxLength:
                              TranslationOptionsSheet.formalityNotesMaxLength,
                          onChanged: _onFormalityNotesChanged,
                          onSubmitted: (_) => _flushFormalityNotes(),
                          onTapOutside: (_) => _flushFormalityNotes(),
                          decoration: InputDecoration(
                            labelText: l10n.translateOptionsFormalityNotes,
                            hintText: l10n.translateOptionsFormalityNotesHint,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ],
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
                                key: const Key(
                                  'translate_options_reading_level',
                                ),
                                isExpanded: true,
                                value: options.readingLevel,
                                items: [
                                  for (final level in ReadingLevel.values)
                                    DropdownMenuItem(
                                      value: level,
                                      child: Text(
                                        translateReadingLevelLabel(l10n, level),
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
                        label: (value) => translateGenderLabel(l10n, value),
                        onSelected: (value) =>
                            _set(options.copyWith(speakerGender: value)),
                      ),
                      _Label(l10n.translateOptionsAddresseeGender),
                      _Choices<Gender>(
                        groupLabel: l10n.translateOptionsAddresseeGender,
                        values: Gender.values,
                        selected: options.addresseeGender,
                        label: (value) => translateGenderLabel(l10n, value),
                        onSelected: (value) =>
                            _set(options.copyWith(addresseeGender: value)),
                      ),
                      _Label(l10n.translateOptionsContext),
                      Semantics(
                        label: l10n.translateOptionsContext,
                        child: TextField(
                          key: const Key('translate_options_context'),
                          controller: _context,
                          enableIMEPersonalizedLearning: imeLearningAllowed(
                            context,
                          ),
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
                            semanticsLabel: l10n
                                .translateGlossaryEntrySemantics(key, value),
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
                              enableIMEPersonalizedLearning: imeLearningAllowed(
                                context,
                              ),
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
                              enableIMEPersonalizedLearning: imeLearningAllowed(
                                context,
                              ),
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
                      const SizedBox(height: 24),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton.icon(
                          key: const Key('translate_options_reset'),
                          onPressed: optionsAreDefault(options) ? null : _reset,
                          icon: const Icon(Icons.restart_alt),
                          label: Text(l10n.translateOptionsReset),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The note at the top of the options sheet when the engine does not
/// apply every option, with an [action] (choose or add an AI translator).
class _AiNote extends StatelessWidget {
  const new({required this.message, this.action});

  final String message;
  final ({String label, VoidCallback onPressed})? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final action = this.action;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: DecoratedBox(
        key: const Key('translate_options_ai_note'),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.08),
          borderRadius: TranslateLayout.cardBorderRadius,
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 8, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.auto_awesome_outlined,
                    size: 20,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(end: 8),
                      child: Text(message, style: theme.textTheme.bodyMedium),
                    ),
                  ),
                ],
              ),
              if (action != null)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    key: const Key('translate_options_ai_action'),
                    onPressed: action.onPressed,
                    child: Text(action.label),
                  ),
                )
              else
                const SizedBox(height: 8),
            ],
          ),
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
    // A bold section heading, as on the translate screen.
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 10),
        child: Text(
          text,
          style: TranslateLayout.headingStyle(context)
              ?.copyWith(color: theme.colorScheme.onSurface),
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
