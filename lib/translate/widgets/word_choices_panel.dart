import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/tool_chip.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// Compact "Definitions" for Mozhi results that carry word choices or
/// synonyms (Google engine), in the "Tools" area: a row like the tools
/// ([TranslateToolRow]) that unfolds them in place. Nothing for short
/// inputs: the panel under the translation shows them at a glance there
/// (`ShortQueryPanel`).
class WordChoicesPanel extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TranslateCubit, TranslateState>(
      buildWhen: (previous, current) =>
          previous.result != current.result ||
          previous.isShortInput != current.isShortInput,
      builder: (context, state) {
        final result = state.result;
        if (result == null ||
            state.isShortInput ||
            !result.isComplete ||
            (result.wordChoices.isEmpty &&
                result.sourceSynonyms.isEmpty &&
                result.targetSynonyms.isEmpty)) {
          return const SizedBox.shrink();
        }
        return _Panel(result: result);
      },
    );
  }
}

class _Panel extends StatefulWidget {
  const new({required this.result});

  final TranslationResult result;

  @override
  State<_Panel> createState() => _PanelState();
}

class _PanelState extends State<_Panel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final result = widget.result;
    final muted = theme.colorScheme.onSurfaceVariant;
    final label = theme.textTheme.titleSmall?.copyWith(color: muted);
    final synonyms = {...result.sourceSynonyms, ...result.targetSynonyms};
    return Padding(
      key: const Key('translate_word_choices'),
      padding: const EdgeInsetsDirectional.only(start: 4, end: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TranslateToolRow(
            key: const Key('translate_word_choices_button'),
            icon: Icons.menu_book_outlined,
            label: l10n.translateDefinitions,
            expanded: _expanded,
            onPressed: () => setState(() => _expanded = !_expanded),
          ),
          AnimatedSize(
            duration: TranslateLayout.motion(context),
            curve: Curves.easeOutCubic,
            alignment: AlignmentDirectional.topStart,
            child: !_expanded
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(44, 0, 8, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final choice in result.wordChoices)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _Choice(choice: choice, muted: muted),
                          ),
                        if (synonyms.isNotEmpty) ...[
                          Semantics(
                            header: true,
                            child: Text(
                              l10n.translateDictionarySynonyms,
                              style: label,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(synonyms.join(', ')),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const new({required this.choice, required this.muted});

  final WordChoice choice;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(choice.word, style: theme.textTheme.titleSmall),
        if (choice.definition.isNotEmpty) Text(choice.definition),
        for (final (index, example) in choice.examplesSource.indexed)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: example,
                    style: const TextStyle(fontStyle: FontStyle.italic),
                  ),
                  if (index < choice.examplesTarget.length)
                    TextSpan(
                      text: '\n${choice.examplesTarget[index]}',
                      style: TextStyle(color: muted),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
