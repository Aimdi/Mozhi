import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/dictionary/data/default_dictionary_packs.dart'
    show maybeDictionaryPacks;
import 'package:mozhi/dictionary/widgets/dictionary_attribution.dart'
    show DictionaryAttributionLink;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/dictionary_card.dart';
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// Under the translation of a short input (1-3 words,
/// [TranslateState.isShortInput]): what the engine returned with it, at a
/// glance, without a new request (`TranslationResult.targetSynonyms`,
/// `wordChoices`, `sourceSynonyms`; Google through Mozhi has them):
///
/// * up to [maxOtherTranslations] other translations; tapping one makes it
///   the translation (`TranslateCubit.useOtherTranslation`);
/// * up to [maxDefinitions] definitions, each with an example; when the
///   engine returned none, the installed offline dictionaries' (looked up
///   on the device, nothing is sent; with their source and licence);
/// * synonyms of the input;
/// * "Open in Dictionary" (the Dictionary tab, [DictionaryCard.openDictionary])
///   and, with an AI engine for extras, "More detail": the AI dictionary
///   entry ([DictionaryCard], an AI request on that tap only).
///
/// Nothing unless [shows].
class ShortQueryPanel extends StatelessWidget {
  const new({required this.state, super.key});

  final TranslateState state;

  /// Most other translations shown.
  static const maxOtherTranslations = 4;

  /// Most definitions shown.
  static const maxDefinitions = 2;

  /// Most synonyms shown.
  static const maxSynonyms = 8;

  /// Whether the panel shows for [state]: a short input with a finished,
  /// current translation (not in compare mode).
  static bool shows(TranslateState state) {
    final result = state.result;
    return state.isShortInput &&
        !state.compareMode &&
        result != null &&
        result.isComplete &&
        state.status == TranslateStatus.success &&
        !state.isResultStale &&
        result.text.trim().isNotEmpty;
  }

  /// Other translations of the input the engine returned (its target
  /// synonyms), without blanks, duplicates and the translation itself; at
  /// most [maxOtherTranslations].
  static List<String> otherTranslations(TranslateState state) {
    final result = state.result;
    if (result == null) return const [];
    final seen = {result.text.trim().toLowerCase()};
    return [
      for (final synonym in result.targetSynonyms)
        if (synonym.trim().isNotEmpty && seen.add(synonym.trim().toLowerCase()))
          synonym.trim(),
    ].take(maxOtherTranslations).toList();
  }

  /// The word choices with a definition; at most [maxDefinitions].
  static List<WordChoice> definitions(TranslateState state) => [
    for (final choice in state.result?.wordChoices ?? const <WordChoice>[])
      if (choice.definition.trim().isNotEmpty) choice,
  ].take(maxDefinitions).toList();

  /// Synonyms of the input; at most [maxSynonyms].
  static List<String> synonyms(TranslateState state) {
    final input = state.input.trim().toLowerCase();
    final seen = {input};
    return [
      for (final synonym in state.result?.sourceSynonyms ?? const <String>[])
        if (synonym.trim().isNotEmpty && seen.add(synonym.trim().toLowerCase()))
          synonym.trim(),
    ].take(maxSynonyms).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (!shows(state)) return const SizedBox.shrink();
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<TranslateCubit>();
    final muted = AppPalette.of(context).secondaryText;
    final others = otherTranslations(state);
    final choices = definitions(state);
    final similar = synonyms(state);
    final sourceCode = state.effectiveSourceCode;
    final source = sourceCode == null || state.source.isCustom
        ? null
        : Language(code: sourceCode, name: sourceCode);
    final sourceLocale = source == null ? null : localeForLanguage(source);
    final sourceDirection = source == null
        ? null
        : textDirectionForLanguage(source);
    final targetLocale = localeForLanguage(state.target);
    final targetDirection = textDirectionForLanguage(state.target);
    final word = DictionaryCard.wordOf(state);
    final detail = state.hasExtras;
    final dictionaryShown = state.dictionaryStatus != ExtraStatus.idle;

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: theme.textTheme.titleSmall?.copyWith(color: muted),
        ),
      ),
    );

    return Padding(
      key: const Key('translate_short_query'),
      padding: const EdgeInsetsDirectional.only(top: 4, end: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (others.isNotEmpty) ...[
            heading(l10n.translateShortOtherTranslations),
            TranslatePills(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final other in others)
                    ActionChip(
                      key: ValueKey('translate_short_other:$other'),
                      label: Text.rich(
                        TextSpan(text: other, locale: targetLocale),
                        textDirection:
                            targetDirection ?? textDirectionForText(other),
                      ),
                      tooltip: l10n.translateShortUseTranslation,
                      onPressed: () => cubit.useOtherTranslation(other),
                    ),
                ],
              ),
            ),
          ],
          if (choices.isNotEmpty) ...[
            heading(l10n.translateDefinitions),
            for (final choice in choices)
              _Definition(
                key: ValueKey('translate_short_definition:${choice.word}'),
                choice: choice,
                input: state.input.trim(),
                sourceLocale: sourceLocale,
                sourceDirection: sourceDirection,
                targetLocale: targetLocale,
                targetDirection: targetDirection,
              ),
          ] else if (maybeDictionaryPacks(context) case final packs?
              when word.isNotEmpty)
            OfflineDefinitions(
              key: const Key('translate_short_offline_definitions'),
              dictionary: packs,
              word: word,
              language: state.source.isCustom ? null : sourceCode,
              target: state.target.isCustom ? null : state.target.code,
              heading: heading(l10n.translateDefinitions),
              sourceLocale: sourceLocale,
              sourceDirection: sourceDirection,
            ),
          if (similar.isNotEmpty) ...[
            heading(l10n.translateDictionarySynonyms),
            Text.rich(
              TextSpan(text: similar.join(', '), locale: sourceLocale),
              key: const Key('translate_short_synonyms'),
              textDirection: sourceDirection,
              style: theme.textTheme.bodyMedium,
            ),
          ],
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (word.isNotEmpty)
                TextButton.icon(
                  key: const Key('translate_short_open_dictionary'),
                  icon: const Icon(Icons.menu_book_outlined),
                  label: Text(l10n.translateShortOpenDictionary),
                  onPressed: () =>
                      DictionaryCard.openDictionary(context, state, word),
                ),
              if (detail && !dictionaryShown)
                TextButton.icon(
                  key: const Key('translate_short_more_detail'),
                  icon: const Icon(Icons.auto_awesome_outlined),
                  label: Text(l10n.translateShortMoreDetail),
                  onPressed: () => unawaited(cubit.lookUp()),
                ),
            ],
          ),
          // The AI entry, once asked for.
          if (detail && dictionaryShown)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: DictionaryCard(showOpenLink: false),
            ),
        ],
      ),
    );
  }
}

/// Up to [ShortQueryPanel.maxDefinitions] senses of [word] from the
/// offline [dictionary] (the dictionary of [language], or every installed
/// one when it is unknown), each with its part of speech and first
/// example, under [heading], ending with the source and licence of the
/// data. Nothing while it looks or when the dictionaries do not have the
/// word. Looked up again when the word or a language changes, or
/// dictionaries are installed or removed.
class OfflineDefinitions extends StatefulWidget {
  const new({
    required this.dictionary,
    required this.word,
    required this.heading,
    this.language,
    this.target,
    this.sourceLocale,
    this.sourceDirection,
    super.key,
  });

  final OfflineDictionary dictionary;
  final String word;

  /// Language code of [word]; null when it is unknown.
  final String? language;

  /// Language code of the translation.
  final String? target;
  final Widget heading;
  final Locale? sourceLocale;
  final TextDirection? sourceDirection;

  @override
  State<OfflineDefinitions> createState() => _OfflineDefinitionsState();
}

class _OfflineDefinitionsState extends State<OfflineDefinitions> {
  OfflineDictionaryAnswer? _answer;
  StreamSubscription<void>? _changes;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _changes = widget.dictionary.changes.listen((_) => _lookUp());
    _lookUp();
  }

  @override
  void didUpdateWidget(OfflineDefinitions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.word != widget.word ||
        oldWidget.language != widget.language ||
        oldWidget.target != widget.target ||
        !identical(oldWidget.dictionary, widget.dictionary)) {
      unawaited(_changes?.cancel());
      _changes = widget.dictionary.changes.listen((_) => _lookUp());
      _lookUp();
    }
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  void _lookUp() {
    final request = ++_request;
    unawaited(
      widget.dictionary
          .lookUp(widget.word, language: widget.language, target: widget.target)
          .then(
            (answer) {
              if (mounted && request == _request) {
                setState(() => _answer = answer);
              }
            },
            onError: (Object _) {
              // Definitions are extra: a failing dictionary shows none.
              if (mounted && request == _request) {
                setState(() => _answer = null);
              }
            },
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final answer = _answer;
    final senses = [
      for (final sense in answer?.entry.senses ?? const <DictionarySense>[])
        if (sense.definition.trim().isNotEmpty) sense,
    ].take(ShortQueryPanel.maxDefinitions).toList();
    if (answer == null || senses.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    final examples = answer.entry.examples;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        widget.heading,
        for (final (index, sense) in senses.indexed)
          Padding(
            key: ValueKey('translate_short_offline_sense:$index'),
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      if (sense.partOfSpeech.trim().isNotEmpty)
                        TextSpan(
                          text: '${sense.partOfSpeech.trim()}  ',
                          style: TextStyle(
                            color: muted,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      TextSpan(text: sense.definition.trim()),
                    ],
                  ),
                  style: theme.textTheme.bodyMedium,
                ),
                if (index < examples.length &&
                    examples[index].source.trim().isNotEmpty)
                  Text.rich(
                    TextSpan(
                      text: examples[index].source.trim(),
                      locale: widget.sourceLocale,
                    ),
                    textDirection: widget.sourceDirection,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
                  ),
              ],
            ),
          ),
        DictionaryAttributionLink(attribution: answer.attribution),
      ],
    );
  }
}

/// A definition: the word (when it is not the whole input), the
/// definition and its first example with its translation.
class _Definition extends StatelessWidget {
  const new({
    required this.choice,
    required this.input,
    this.sourceLocale,
    this.sourceDirection,
    this.targetLocale,
    this.targetDirection,
    super.key,
  });

  final WordChoice choice;
  final String input;
  final Locale? sourceLocale;
  final TextDirection? sourceDirection;
  final Locale? targetLocale;
  final TextDirection? targetDirection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    final word = choice.word.trim();
    final example = choice.examplesSource.isEmpty
        ? ''
        : choice.examplesSource.first.trim();
    final translated = choice.examplesTarget.isEmpty
        ? ''
        : choice.examplesTarget.first.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (word.isNotEmpty && word.toLowerCase() != input.toLowerCase())
            Text.rich(
              TextSpan(text: word, locale: sourceLocale),
              textDirection: sourceDirection,
              style: theme.textTheme.labelLarge,
            ),
          Text(choice.definition.trim(), style: theme.textTheme.bodyMedium),
          if (example.isNotEmpty)
            Text.rich(
              TextSpan(text: example, locale: sourceLocale),
              textDirection: sourceDirection,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontStyle: FontStyle.italic,
              ),
            ),
          if (example.isNotEmpty && translated.isNotEmpty)
            Text.rich(
              TextSpan(text: translated, locale: targetLocale),
              textDirection: targetDirection,
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
        ],
      ),
    );
  }
}
