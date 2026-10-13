import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/ai_generated_header.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// AI dictionary entry for short (1-3 word) inputs, loaded on demand.
class DictionaryCard extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return BlocBuilder<TranslateCubit, TranslateState>(
      buildWhen: (previous, current) =>
          previous.dictionaryStatus != current.dictionaryStatus ||
          previous.dictionary != current.dictionary ||
          previous.input != current.input,
      builder: (context, state) {
        final cubit = context.read<TranslateCubit>();
        final entry = state.dictionary;
        final body = switch (state.dictionaryStatus) {
          ExtraStatus.idle => Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const Key('translate_dictionary_lookup'),
              onPressed: () => unawaited(cubit.lookUp()),
              icon: const Icon(Icons.search),
              label: Text(l10n.translateDictionaryLookUp(state.input.trim())),
            ),
          ),
          ExtraStatus.loading => const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          ),
          ExtraStatus.failure => TranslateErrorView(
            error: state.extraError,
            dense: true,
            onRetry: () => unawaited(cubit.lookUp()),
          ),
          ExtraStatus.ready when entry != null => DictionaryEntryView(
            entry: entry,
          ),
          ExtraStatus.ready => const SizedBox.shrink(),
        };
        return Card(
          key: const Key('translate_dictionary_card'),
          margin: EdgeInsets.zero,
          elevation: 0,
          color: theme.colorScheme.surfaceContainerLow,
          shape: const RoundedRectangleBorder(
            borderRadius: TranslateLayout.cardBorderRadius,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AiGeneratedHeader(
                  icon: Icons.menu_book_outlined,
                  title: l10n.translateDictionary,
                ),
                const SizedBox(height: 8),
                body,
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Word, IPA, senses, examples and synonyms of a [DictionaryEntry].
class DictionaryEntryView extends StatelessWidget {
  const new({required this.entry, super.key});

  final DictionaryEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final label = theme.textTheme.labelLarge?.copyWith(
      color: theme.colorScheme.primary,
    );
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              Text(entry.word, style: theme.textTheme.headlineSmall),
              if (entry.pronunciation.isNotEmpty)
                Text(
                  '/${entry.pronunciation.replaceAll('/', '')}/',
                  style: theme.textTheme.bodyLarge?.copyWith(color: muted),
                ),
            ],
          ),
          if (entry.partsOfSpeech.isNotEmpty)
            Text(
              entry.partsOfSpeech.join(' · '),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: muted,
                fontStyle: FontStyle.italic,
              ),
            ),
          for (final (index, sense) in entry.senses.indexed) ...[
            const SizedBox(height: 12),
            _Sense(number: index + 1, sense: sense),
          ],
          if (entry.examples.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(l10n.translateDictionaryExamples, style: label),
            for (final example in entry.examples)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      example.source,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    if (example.translation.isNotEmpty)
                      Text(
                        example.translation,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: muted,
                        ),
                      ),
                  ],
                ),
              ),
          ],
          if (entry.synonyms.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(l10n.translateDictionarySynonyms, style: label),
            const SizedBox(height: 4),
            Text(entry.synonyms.join(', ')),
          ],
          if (entry.etymology.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(l10n.translateDictionaryEtymology, style: label),
            const SizedBox(height: 4),
            Text(entry.etymology, style: TextStyle(color: muted)),
          ],
          if (entry.notes.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(entry.notes, style: TextStyle(color: muted)),
          ],
        ],
      ),
    );
  }
}

class _Sense extends StatelessWidget {
  const new({required this.number, required this.sense});

  final int number;
  final DictionarySense sense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 24,
          child: Text('$number.', style: theme.textTheme.bodyLarge),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    if (sense.partOfSpeech.isNotEmpty)
                      TextSpan(
                        text: '${sense.partOfSpeech}  ',
                        style: TextStyle(
                          color: muted,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    TextSpan(text: sense.definition),
                    if (sense.usage.isNotEmpty)
                      TextSpan(
                        text: '  (${sense.usage})',
                        style: TextStyle(color: muted),
                      ),
                  ],
                ),
                style: theme.textTheme.bodyLarge,
              ),
              if (sense.translations.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    sense.translations.join(', '),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
