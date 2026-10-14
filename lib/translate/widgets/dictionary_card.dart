import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart';
import 'package:mozhi/dictionary/view/dictionary_page.dart'
    show DictionaryLaunch;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/ai_generated_header.dart';
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:mozhi/translate/widgets/status_announcer.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// AI dictionary entry for short (1-3 word) inputs, loaded on demand.
///
/// The detail level (concise, standard, detailed) can be picked before and
/// after looking up; related words and "Did you mean …?" look that word up
/// instead ([TranslateCubit.lookUpWord]). "Open dictionary" shows the word
/// in the full-screen dictionary and looks it up there.
class DictionaryCard extends StatelessWidget {
  const new({super.key});

  /// The word "Open dictionary" opens: the shown (or loading) word, else
  /// the input.
  static String wordOf(TranslateState state) {
    final query = state.dictionaryQuery?.trim() ?? '';
    return query.isNotEmpty ? query : state.input.trim();
  }

  /// Opens the full-screen dictionary for [word] in the languages of
  /// [state] (the detected source when it is auto) and looks it up.
  static Future<void> openDictionary(
    BuildContext context,
    TranslateState state,
    String word,
  ) async {
    final source = state.source;
    final detected = state.result?.detectedSource?.trim() ?? '';
    final from = source.isCustom
        ? null
        : source.isAuto
        ? (detected.isEmpty ? null : detected)
        : source.code;
    final target = state.target;
    await context.push<Object?>(
      AppRoutes.dictionaryWord(
        word: word,
        from: from,
        to: target.isCustom ? null : target.code,
      ),
      extra: DictionaryLaunch.lookUp,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return BlocBuilder<TranslateCubit, TranslateState>(
      buildWhen: (previous, current) =>
          previous.dictionaryStatus != current.dictionaryStatus ||
          previous.dictionary != current.dictionary ||
          previous.dictionaryVerbosity != current.dictionaryVerbosity ||
          previous.dictionaryQuery != current.dictionaryQuery ||
          previous.input != current.input ||
          previous.source != current.source ||
          previous.target != current.target ||
          previous.result?.detectedSource != current.result?.detectedSource,
      builder: (context, state) {
        final cubit = context.read<TranslateCubit>();
        final entry = state.dictionary;
        final word = wordOf(state);
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
          ExtraStatus.loading => Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(
              semanticsLabel: l10n.translateLoading,
            ),
          ),
          ExtraStatus.failure => TranslateErrorView(
            error: state.extraError,
            dense: true,
            onRetry: () => unawaited(cubit.lookUp()),
          ),
          ExtraStatus.ready when entry != null => DictionaryEntryView(
            entry: entry,
            sourceLanguage: state.source.isAuto
                ? _detected(state.result?.detectedSource)
                : state.source,
            targetLanguage: state.target,
            query: state.dictionaryQuery,
            onWordTap: (word) => unawaited(cubit.lookUpWord(word)),
          ),
          ExtraStatus.ready => const SizedBox.shrink(),
        };
        return StatusAnnouncer(
          message: state.dictionaryStatus == ExtraStatus.ready && entry != null
              ? l10n.translateDictionaryReady
              : null,
          child: Card(
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
                  DictionaryVerbosityChips(
                    value: state.dictionaryVerbosity,
                    onChanged: (verbosity) =>
                        unawaited(cubit.setDictionaryVerbosity(verbosity)),
                  ),
                  const SizedBox(height: 8),
                  body,
                  if (word.isNotEmpty)
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: TextButton.icon(
                        key: const Key('translate_dictionary_open'),
                        onPressed: () =>
                            unawaited(openDictionary(context, state, word)),
                        icon: const Icon(Icons.open_in_new),
                        label: Text(l10n.translateDictionaryOpen),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static Language? _detected(String? code) =>
      code == null || code.isEmpty ? null : Language(code: code, name: code);
}

/// Concise / Standard / Detailed: how much a dictionary look-up asks for
/// (choice chips with a check mark, in a named group).
class DictionaryVerbosityChips extends StatelessWidget {
  const new({required this.value, this.onChanged, super.key});

  final DictionaryVerbosity value;

  /// Called with a newly chosen level; null disables the chips.
  final ValueChanged<DictionaryVerbosity>? onChanged;

  /// Name of [verbosity] in the UI.
  static String label(AppLocalizations l10n, DictionaryVerbosity verbosity) =>
      switch (verbosity) {
        DictionaryVerbosity.concise => l10n.translateDictionaryConcise,
        DictionaryVerbosity.standard => l10n.translateDictionaryStandard,
        DictionaryVerbosity.comprehensive => l10n.translateDictionaryDetailed,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final onChanged = this.onChanged;
    return Semantics(
      key: const Key('translate_dictionary_verbosity'),
      container: true,
      explicitChildNodes: true,
      label: l10n.translateDictionaryDetailLevel,
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final verbosity in DictionaryVerbosity.values)
            ChoiceChip(
              key: ValueKey('translate_dictionary_verbosity:${verbosity.name}'),
              label: Text(label(l10n, verbosity)),
              selected: verbosity == value,
              onSelected: onChanged == null
                  ? null
                  : (_) {
                      if (verbosity != value) onChanged(verbosity);
                    },
            ),
        ],
      ),
    );
  }
}

/// "Did you mean “[word]”?" (`translateDictionaryDidYouMean`) as a span in
/// which only [word] carries [wordLocale] (the language of the looked-up
/// text): screen readers read the UI-language words with the UI voice and
/// the word with its language's, and CJK glyphs are picked per part.
TextSpan didYouMeanSpan(
  AppLocalizations l10n,
  String word, {
  Locale? wordLocale,
}) {
  // A private-use character no translation contains.
  const marker = '\u{E000}';
  final template = l10n.translateDictionaryDidYouMean(marker);
  final at = template.indexOf(marker);
  if (wordLocale == null || at < 0) {
    return TextSpan(text: l10n.translateDictionaryDidYouMean(word));
  }
  final before = template.substring(0, at);
  final after = template.substring(at + marker.length);
  return TextSpan(
    children: [
      if (before.isNotEmpty) TextSpan(text: before),
      TextSpan(text: word, locale: wordLocale),
      if (after.isNotEmpty) TextSpan(text: after),
    ],
  );
}

/// Word, IPA, senses, examples, synonyms and related words of a
/// [DictionaryEntry], with "Did you mean …?" for a misspelled word.
///
/// With [onWordTap], related words are chips and "Did you mean …?" is a
/// link that look the word up; without it they are plain text.
class DictionaryEntryView extends StatelessWidget {
  const new({
    required this.entry,
    this.sourceLanguage,
    this.targetLanguage,
    this.query,
    this.onWordTap,
    super.key,
  });

  final DictionaryEntry entry;

  /// The text that was looked up; "Did you mean …?" is not offered for it.
  final String? query;

  /// Looks a related word or the suggested spelling up.
  final ValueChanged<String>? onWordTap;

  /// Language of the word and the example sentences.
  final Language? sourceLanguage;

  /// Language of the translations.
  final Language? targetLanguage;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final label = theme.textTheme.labelLarge?.copyWith(
      color: theme.colorScheme.primary,
    );
    final source = sourceLanguage;
    final target = targetLanguage;
    final sourceLocale = source == null ? null : localeForLanguage(source);
    final targetLocale = target == null ? null : localeForLanguage(target);
    final sourceDirection = source == null
        ? null
        : textDirectionForLanguage(source);
    final targetDirection = target == null
        ? null
        : textDirectionForLanguage(target);
    Widget heading(String text) =>
        Semantics(header: true, child: Text(text, style: label));
    final onWordTap = this.onWordTap;
    final didYouMean = entry.didYouMean?.trim() ?? '';
    final suggestSpelling =
        didYouMean.isNotEmpty &&
        didYouMean.toLowerCase() != query?.trim().toLowerCase();
    final related = [
      for (final word in entry.relatedWords)
        if (word.trim().isNotEmpty) word.trim(),
    ];
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (suggestSpelling) ...[
            SelectionContainer.disabled(
              child: onWordTap == null
                  ? Text.rich(
                      didYouMeanSpan(
                        l10n,
                        didYouMean,
                        wordLocale: sourceLocale,
                      ),
                      key: const Key('translate_dictionary_did_you_mean'),
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontStyle: FontStyle.italic,
                      ),
                    )
                  : TextButton.icon(
                      key: const Key('translate_dictionary_did_you_mean'),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: () => onWordTap(didYouMean),
                      icon: const Icon(Icons.spellcheck),
                      label: Text.rich(
                        didYouMeanSpan(
                          l10n,
                          didYouMean,
                          wordLocale: sourceLocale,
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 4),
          ],
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              Text.rich(
                TextSpan(text: entry.word, locale: sourceLocale),
                textDirection: sourceDirection,
                style: theme.textTheme.headlineSmall,
              ),
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
            _Sense(
              number: index + 1,
              sense: sense,
              translationLocale: targetLocale,
              translationDirection: targetDirection,
            ),
          ],
          if (entry.examples.isNotEmpty) ...[
            const SizedBox(height: 16),
            heading(l10n.translateDictionaryExamples),
            for (final example in entry.examples)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(text: example.source, locale: sourceLocale),
                      textDirection: sourceDirection,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    if (example.translation.isNotEmpty)
                      Text.rich(
                        TextSpan(
                          text: example.translation,
                          locale: targetLocale,
                        ),
                        textDirection: targetDirection,
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
            heading(l10n.translateDictionarySynonyms),
            const SizedBox(height: 4),
            Text(entry.synonyms.join(', ')),
          ],
          if (related.isNotEmpty) ...[
            const SizedBox(height: 16),
            heading(l10n.translateDictionaryRelated),
            const SizedBox(height: 4),
            if (onWordTap == null)
              Text.rich(
                TextSpan(text: related.join(', '), locale: sourceLocale),
                textDirection: sourceDirection,
              )
            else
              SelectionContainer.disabled(
                child: Wrap(
                  key: const Key('translate_dictionary_related'),
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final word in related)
                      ActionChip(
                        key: ValueKey('translate_dictionary_related:$word'),
                        label: Text.rich(
                          TextSpan(text: word, locale: sourceLocale),
                          textDirection: sourceDirection,
                        ),
                        tooltip: l10n.translateDictionaryLookUp(word),
                        onPressed: () => onWordTap(word),
                      ),
                  ],
                ),
              ),
          ],
          if (entry.etymology.isNotEmpty) ...[
            const SizedBox(height: 16),
            heading(l10n.translateDictionaryEtymology),
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
  const new({
    required this.number,
    required this.sense,
    this.translationLocale,
    this.translationDirection,
  });

  final int number;
  final DictionarySense sense;
  final Locale? translationLocale;
  final TextDirection? translationDirection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // A minimum (not fixed) width: "10." at 200 % text must not clip.
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 24),
          child: Padding(
            padding: const EdgeInsetsDirectional.only(end: 4),
            child: Text('$number.', style: theme.textTheme.bodyLarge),
          ),
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
                  child: Text.rich(
                    TextSpan(
                      text: sense.translations.join(', '),
                      locale: translationLocale,
                    ),
                    textDirection: translationDirection,
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
