import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// Compact "Definitions" list for Mozhi results that carry word choices or
/// synonyms (Google engine).
class WordChoicesPanel extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TranslateCubit, TranslateState>(
      buildWhen: (previous, current) => previous.result != current.result,
      builder: (context, state) {
        final result = state.result;
        if (result == null ||
            !result.isComplete ||
            (result.wordChoices.isEmpty &&
                result.sourceSynonyms.isEmpty &&
                result.targetSynonyms.isEmpty)) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: TranslateLayout.gap),
          child: _Panel(result: result),
        );
      },
    );
  }
}

class _Panel extends StatelessWidget {
  const new({required this.result});

  final TranslationResult result;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final label = theme.textTheme.labelLarge?.copyWith(
      color: theme.colorScheme.primary,
    );
    final synonyms = {...result.sourceSynonyms, ...result.targetSynonyms};
    return Card(
      key: const Key('translate_word_choices'),
      margin: EdgeInsets.zero,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      color: theme.colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: TranslateLayout.cardBorderRadius,
      ),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(Icons.menu_book_outlined),
          title: Text(l10n.translateDefinitions),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            for (final choice in result.wordChoices)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(choice.word, style: theme.textTheme.titleSmall),
                    if (choice.definition.isNotEmpty) Text(choice.definition),
                    for (final (index, example)
                        in choice.examplesSource.indexed)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: example,
                                style: const TextStyle(
                                  fontStyle: FontStyle.italic,
                                ),
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
                ),
              ),
            if (synonyms.isNotEmpty) ...[
              Semantics(
                header: true,
                child: Text(l10n.translateDictionarySynonyms, style: label),
              ),
              const SizedBox(height: 4),
              Text(synonyms.join(', ')),
            ],
          ],
        ),
      ),
    );
  }
}
