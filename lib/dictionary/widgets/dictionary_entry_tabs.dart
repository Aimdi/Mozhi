import 'dart:math' as math;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/translate/widgets/dictionary_card.dart'
    show didYouMeanSpan;
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:mozhi/translate/widgets/listen_button.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// A [DictionaryEntry] on its own screen, in tabs (like Kagi Translate's
/// dictionary):
///
/// * **Meaning**: centred, the part of speech, the headword (very large),
///   its IPA, the synonyms as accent words that look that word up, the
///   first definition with its usage and translations, and a large listen
///   button (with [actions] beside it, e.g. the favorite heart); "Did you
///   mean …?" above them for a misspelled word.
/// * **Usage** (when there is more): the other senses, the related words
///   (chips that look the word up), the etymology and the notes.
/// * **Examples** (when there are some): the example sentences with their
///   translations.
///
/// The tabs are `titleSmall` text tabs; every page starts at the top. The
/// tab bar is left out when there is only the meaning. [onWordTap] looks a
/// synonym, related word or suggested spelling up.
///
/// Listen reads the headword in [sourceLanguage], else in [speechLanguage]
/// (the detected language of the entry, see
/// `DictionaryState.entryLanguage`); it is disabled, saying why, while
/// neither is known.
///
/// The meaning page ends with [footer], by default "AI-generated" (an
/// entry from an offline dictionary credits its source instead) and, for
/// an AI entry whose look-up kept personal data on the device
/// ([DictionaryEntry.maskedPersonalData]), how many items it kept, as
/// the translation's notes say it; [header] goes above the part of speech
/// (e.g. "“went” is a form of “go”").
class DictionaryEntryTabs extends StatelessWidget {
  const new({
    required this.entry,
    required this.onWordTap,
    this.sourceLanguage,
    this.targetLanguage,
    this.query,
    this.speechLanguage,
    this.actions = const [],
    this.header,
    this.footer,
    super.key,
  });

  /// Above the part of speech on the meaning page.
  final Widget? header;

  /// The end of the meaning page; null shows "AI-generated".
  final Widget? footer;

  final DictionaryEntry entry;

  /// Code of the entry's language when [sourceLanguage] is not set (it
  /// was detected), for Listen; null while unknown.
  final String? speechLanguage;

  /// Shown beside Listen on the meaning page (e.g. the favorite heart).
  final List<Widget> actions;

  /// Language of the word and the example sentences (null: detected).
  final Language? sourceLanguage;

  /// Language of the translations.
  final Language? targetLanguage;

  /// The text that was looked up; "Did you mean …?" is not offered for it.
  final String? query;

  final ValueChanged<String> onWordTap;

  /// Whether [entry] has anything for the "Usage" tab.
  static bool hasMore(DictionaryEntry entry) =>
      entry.senses.length > 1 ||
      _related(entry).isNotEmpty ||
      entry.etymology.trim().isNotEmpty ||
      entry.notes.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final pages = <(String, Widget)>[
      (
        l10n.dictionaryTabMeaning,
        _MeaningPage(
          entry: entry,
          sourceLanguage: sourceLanguage,
          targetLanguage: targetLanguage,
          query: query,
          onWordTap: onWordTap,
          speechLanguage: speechLanguage,
          actions: actions,
          header: header,
          footer: footer,
        ),
      ),
      if (hasMore(entry))
        (
          l10n.dictionaryTabUsage,
          _MorePage(
            entry: entry,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            onWordTap: onWordTap,
          ),
        ),
      if (entry.examples.isNotEmpty)
        (
          l10n.dictionaryTabExamples,
          _ExamplesPage(
            entry: entry,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
          ),
        ),
    ];
    return DefaultTabController(
      // A new entry starts on its meaning.
      key: ValueKey(entry),
      length: pages.length,
      child: Column(
        key: const Key('dictionary_entry'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (pages.length > 1)
            _EntryTabBar(labels: [for (final (label, _) in pages) label]),
          Expanded(
            child: pages.length > 1
                ? TabBarView(children: [for (final (_, page) in pages) page])
                : pages.first.$2,
          ),
        ],
      ),
    );
  }
}

/// The related words of [entry] (trimmed, without blanks).
List<String> _related(DictionaryEntry entry) => [
  for (final word in entry.relatedWords)
    if (word.trim().isNotEmpty) word.trim(),
];

/// Text tabs at `titleSmall` in the accent colour (the others quieter),
/// with a short accent underline under the selected one so it is not told
/// by colour alone.
class _EntryTabBar extends StatelessWidget {
  const new({required this.labels});

  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w700,
    );
    // A 48 dp target, taller with large text.
    final height = math
        .max(
          48,
          MediaQuery.textScalerOf(context)
                  .scale((style?.fontSize ?? 14) * 1.4) +
              16,
        )
        .toDouble();
    return TabBar(
      key: const Key('dictionary_tabs'),
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      padding: const EdgeInsetsDirectional.only(start: 8, end: 8),
      labelPadding: const EdgeInsets.symmetric(horizontal: 12),
      labelStyle: style,
      unselectedLabelStyle: style,
      labelColor: scheme.primary,
      unselectedLabelColor: AppPalette.of(context).secondaryText,
      indicatorSize: TabBarIndicatorSize.label,
      indicator: UnderlineTabIndicator(
        borderSide: BorderSide(width: 3, color: scheme.primary),
        borderRadius: BorderRadius.circular(
          AppLook.of(context).controlRadius(2),
        ),
      ),
      dividerColor: Colors.transparent,
      tabs: [for (final label in labels) Tab(height: height, text: label)],
    );
  }
}

/// The app-wide [SpeechService], or null when none is provided (the
/// listen button is then left out).
SpeechService? _speechServiceOf(BuildContext context) {
  try {
    return context.read<SpeechService>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// Scrolls [child], from the top of the page (no blank space above a
/// short entry).
class _Page extends StatelessWidget {
  const new({required this.child});

  final Widget child;

  static const EdgeInsets padding = EdgeInsets.fromLTRB(24, 16, 24, 24);

  @override
  Widget build(BuildContext context) =>
      SingleChildScrollView(padding: padding, child: child);
}

/// The "Meaning" tab of [DictionaryEntryTabs].
class _MeaningPage extends StatelessWidget {
  const new({
    required this.entry,
    required this.onWordTap,
    this.sourceLanguage,
    this.targetLanguage,
    this.query,
    this.speechLanguage,
    this.actions = const [],
    this.header,
    this.footer,
  });

  final DictionaryEntry entry;
  final Language? sourceLanguage;
  final Language? targetLanguage;
  final String? query;
  final ValueChanged<String> onWordTap;
  final String? speechLanguage;
  final List<Widget> actions;
  final Widget? header;
  final Widget? footer;

  /// The headword's style: the theme's display sizes, smaller for long
  /// words and phrases.
  static TextStyle? headwordStyle(BuildContext context, String word) {
    final textTheme = Theme.of(context).textTheme;
    final length = word.characters.length;
    final style = length <= 12
        ? textTheme.displayMedium
        : length <= 24
        ? textTheme.displaySmall
        : textTheme.headlineLarge;
    return style?.copyWith(
      color: Theme.of(context).colorScheme.onSurface,
      fontWeight: FontWeight.w800,
      height: 1.1,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = AppPalette.of(context).secondaryText;
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
    final sense = entry.senses.isEmpty ? null : entry.senses.first;
    final partOfSpeech = sense != null && sense.partOfSpeech.trim().isNotEmpty
        ? sense.partOfSpeech.trim()
        : entry.partsOfSpeech.join(' · ');
    final didYouMean = entry.didYouMean?.trim() ?? '';
    final suggestSpelling =
        didYouMean.isNotEmpty &&
        didYouMean.toLowerCase() != query?.trim().toLowerCase();
    final synonyms = [
      for (final word in entry.synonyms)
        if (word.trim().isNotEmpty) word.trim(),
    ];
    final ipa = entry.pronunciation.replaceAll('/', '').trim();
    final speech = _speechServiceOf(context);
    final speakCode = source != null && !source.isAuto && !source.isCustom
        ? source.code
        : speechLanguage;
    return _Page(
      child: SelectionArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (suggestSpelling) ...[
              SelectionContainer.disabled(
                child: TextButton.icon(
                  key: const Key('dictionary_did_you_mean'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onPressed: () => onWordTap(didYouMean),
                  icon: const Icon(Icons.spellcheck),
                  label: Text.rich(
                    didYouMeanSpan(l10n, didYouMean, wordLocale: sourceLocale),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (header case final header?) ...[
              SelectionContainer.disabled(child: header),
              const SizedBox(height: 12),
            ],
            if (partOfSpeech.isNotEmpty)
              Text(
                partOfSpeech,
                key: const Key('dictionary_part_of_speech'),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: muted,
                  fontWeight: FontWeight.w500,
                ),
              ),
            Semantics(
              header: true,
              child: Text.rich(
                TextSpan(text: entry.word, locale: sourceLocale),
                key: const Key('dictionary_headword'),
                textAlign: TextAlign.center,
                textDirection: sourceDirection,
                style: headwordStyle(context, entry.word),
              ),
            ),
            if (ipa.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '/$ipa/',
                key: const Key('dictionary_ipa'),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: muted,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
            if (synonyms.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectionContainer.disabled(
                child: Semantics(
                  container: true,
                  explicitChildNodes: true,
                  label: l10n.translateDictionarySynonyms,
                  child: Wrap(
                    key: const Key('dictionary_synonyms'),
                    alignment: WrapAlignment.center,
                    spacing: 4,
                    children: [
                      for (final word in synonyms)
                        Tooltip(
                          message: l10n.translateDictionaryLookUp(word),
                          child: TextButton(
                            key: ValueKey('dictionary_synonym:$word'),
                            style: TextButton.styleFrom(
                              minimumSize: const Size(48, 48),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              foregroundColor: scheme.primary,
                              textStyle: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            onPressed: () => onWordTap(word),
                            child: Text.rich(
                              TextSpan(text: word, locale: sourceLocale),
                              textDirection: sourceDirection,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            if (sense != null) ...[
              const SizedBox(height: 12),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: sense.definition),
                    if (sense.usage.trim().isNotEmpty)
                      TextSpan(
                        text: '  (${sense.usage.trim()})',
                        style: TextStyle(color: muted),
                      ),
                  ],
                ),
                key: const Key('dictionary_definition'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontSize: 19,
                  height: 1.45,
                ),
              ),
              if (sense.translations.isNotEmpty && target != null) ...[
                const SizedBox(height: 12),
                Text(
                  l10n.dictionaryTranslationsIn(target.name),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelMedium?.copyWith(color: muted),
                ),
                Text.rich(
                  TextSpan(
                    text: sense.translations.join(', '),
                    locale: targetLocale,
                  ),
                  key: const Key('dictionary_translations'),
                  textAlign: TextAlign.center,
                  textDirection: targetDirection,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
            if (speech != null || actions.isNotEmpty) ...[
              const SizedBox(height: 20),
              SelectionContainer.disabled(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 12,
                  children: [
                    if (speech != null)
                      IconButtonTheme(
                        data: IconButtonThemeData(
                          style: IconButton.styleFrom(
                            iconSize: 32,
                            minimumSize: const Size.square(56),
                            foregroundColor: scheme.primary,
                          ),
                        ),
                        child: ListenButton(
                          key: const Key('dictionary_listen'),
                          id: 'dictionary_word',
                          text: entry.word,
                          languageCode: speakCode,
                          // Without the word's language there is no voice
                          // to pick: say how to get one.
                          tooltip: speakCode != null
                              ? null
                              : l10n.dictionaryListenNeedsLanguage,
                        ),
                      ),
                    ...actions,
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (footer case final footer?)
              SelectionContainer.disabled(child: footer)
            else
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_awesome_outlined, size: 14, color: muted),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      l10n.translateAiGenerated,
                      style: theme.textTheme.labelSmall?.copyWith(color: muted),
                    ),
                  ),
                ],
              ),
            // Personal data the shield kept on the device (AI entries only:
            // entries of offline dictionaries never leave it).
            if (footer == null && entry.maskedPersonalData > 0)
              Padding(
                key: const Key('dictionary_personal_data'),
                padding: const EdgeInsets.only(top: 4),
                child: MergeSemantics(
                  child: Semantics(
                    hint: l10n.translatePersonalDataKeptHint,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsetsDirectional.only(
                            top: 1,
                            end: 6,
                          ),
                          child: ExcludeSemantics(
                            child: Icon(
                              Icons.shield_outlined,
                              size: 16,
                              color: muted,
                            ),
                          ),
                        ),
                        Flexible(
                          child: Text(
                            l10n.translatePersonalDataKept(
                              entry.maskedPersonalData,
                            ),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A bold heading of the "Usage" tab.
class _Heading extends StatelessWidget {
  const new(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Semantics(
      header: true,
      child: Text(text, style: TranslateLayout.headingStyle(context)),
    ),
  );
}

/// The "Usage" tab of [DictionaryEntryTabs]: the other senses, related
/// words, etymology and notes.
class _MorePage extends StatelessWidget {
  const new({
    required this.entry,
    required this.onWordTap,
    this.sourceLanguage,
    this.targetLanguage,
  });

  final DictionaryEntry entry;
  final Language? sourceLanguage;
  final Language? targetLanguage;
  final ValueChanged<String> onWordTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final muted = AppPalette.of(context).secondaryText;
    final source = sourceLanguage;
    final target = targetLanguage;
    final sourceLocale = source == null ? null : localeForLanguage(source);
    final sourceDirection = source == null
        ? null
        : textDirectionForLanguage(source);
    final related = _related(entry);
    final sections = <Widget>[
      if (entry.senses.length > 1)
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Heading(l10n.dictionaryOtherMeanings),
            for (final (index, sense) in entry.senses.indexed.skip(1))
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _Sense(
                  number: index + 1,
                  sense: sense,
                  translationLocale: target == null
                      ? null
                      : localeForLanguage(target),
                  translationDirection: target == null
                      ? null
                      : textDirectionForLanguage(target),
                ),
              ),
          ],
        ),
      if (related.isNotEmpty)
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Heading(l10n.translateDictionaryRelated),
            SelectionContainer.disabled(
              child: TranslatePills(
                child: Wrap(
                  key: const Key('dictionary_related'),
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final word in related)
                      ActionChip(
                        key: ValueKey('dictionary_related:$word'),
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
            ),
          ],
        ),
      if (entry.etymology.trim().isNotEmpty)
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Heading(l10n.translateDictionaryEtymology),
            Text(entry.etymology.trim(), style: TextStyle(color: muted)),
          ],
        ),
      if (entry.notes.trim().isNotEmpty)
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Heading(l10n.dictionaryNotes),
            Text(entry.notes.trim(), style: TextStyle(color: muted)),
          ],
        ),
    ];
    return _Page(
      child: SelectionArea(
        child: Column(
          key: const Key('dictionary_more'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, section) in sections.indexed) ...[
              if (index > 0) ...[
                const SizedBox(height: 8),
                const Hairline(),
                const SizedBox(height: 16),
              ],
              section,
            ],
          ],
        ),
      ),
    );
  }
}

/// A numbered sense: its part of speech, definition and usage, and its
/// translations in the accent colour.
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
    final muted = AppPalette.of(context).secondaryText;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // A minimum (not fixed) width: "10." at 200 % text must not clip.
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 28),
          child: Padding(
            padding: const EdgeInsetsDirectional.only(end: 4),
            child: Text(
              '$number.',
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
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
                      fontWeight: FontWeight.w700,
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

/// The "Examples" tab of [DictionaryEntryTabs].
class _ExamplesPage extends StatelessWidget {
  const new({required this.entry, this.sourceLanguage, this.targetLanguage});

  final DictionaryEntry entry;
  final Language? sourceLanguage;
  final Language? targetLanguage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    final source = sourceLanguage;
    final target = targetLanguage;
    return _Page(
      child: SelectionArea(
        child: Column(
          key: const Key('dictionary_examples'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, example) in entry.examples.indexed) ...[
              if (index > 0) const Hairline(),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    Text.rich(
                      TextSpan(
                        text: example.source,
                        locale: source == null
                            ? null
                            : localeForLanguage(source),
                      ),
                      textDirection: source == null
                          ? null
                          : textDirectionForLanguage(source),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    if (example.translation.isNotEmpty)
                      Text.rich(
                        TextSpan(
                          text: example.translation,
                          locale: target == null
                              ? null
                              : localeForLanguage(target),
                        ),
                        textDirection: target == null
                            ? null
                            : textDirectionForLanguage(target),
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: muted,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
