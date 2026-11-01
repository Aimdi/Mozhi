import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/dictionary/cubit/dictionary_cubit.dart'
    show DictionaryCubit;
import 'package:mozhi/dictionary/data/default_dictionary_packs.dart'
    show maybeDictionaryPacks;
import 'package:mozhi/dictionary/data/dictionary_packs.dart'
    show DictionaryPacks;
import 'package:mozhi/dictionary/view/dictionary_page.dart'
    show DictionaryLaunch, dictionaryEngine, dictionaryUiLanguage;
import 'package:mozhi/dictionary/widgets/dictionary_attribution.dart'
    show DictionaryAttributionLink;
import 'package:mozhi/dictionary/widgets/dictionary_offline.dart'
    show DictionaryGetPacksButton, DictionaryOfflineNotice;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/phrasebook/models/phrase.dart' show PhraseOrigin;
import 'package:mozhi/phrasebook/models/phrase_draft.dart';
import 'package:mozhi/phrasebook/widgets/add_to_phrasebook.dart'
    show showAddToPhrasebook;
import 'package:mozhi/phrasebook/widgets/phrasebook_labels.dart'
    show maybePhrasebookRepository;
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/copy_action_button.dart';
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:mozhi/translate/widgets/listen_button.dart';
import 'package:mozhi/translate/widgets/status_announcer.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:mozhi/word_lookup/cubit/word_lookup_cubit.dart';
import 'package:mozhi/word_lookup/data/word_lookup_service.dart';
import 'package:mozhi/word_lookup/data/word_segmenter.dart';
import 'package:translation_repository/translation_repository.dart';

/// `SpeechService` clip id of the word card's Listen button.
const wordLookupSpeechId = 'wordLookup';

/// The [WordLookupService] of the app above [context]: its translation
/// repository, offline dictionaries ([maybeDictionaryPacks]) and usage
/// tracker, each when provided.
WordLookupService wordLookupServiceOf(BuildContext context) =>
    WordLookupService(
      repository: _maybeRead<TranslationRepository>(context),
      offlineDictionary: maybeDictionaryPacks(context),
      usageTracker: _maybeRead<UsageTracker>(context),
    );

T? _maybeRead<T>(BuildContext context) {
  try {
    return context.read<T>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// The dictionary engine of the word card: the Dictionary tab's AI model
/// (`dictionaryEngine` of the app's [TranslateCubit]), or null.
TranslationEngine? _engineOf(BuildContext context) {
  final translate = _maybeRead<TranslateCubit>(context);
  return translate == null ? null : dictionaryEngine(translate.state);
}

/// Shows the word card of [word] (in [language], the word's language) in
/// a bottom sheet: its entry in the installed offline dictionaries first,
/// with translations into [into] (the other side of the translation)
/// when they have them, the part of speech, a few senses and the credit
/// of the data; Listen, Copy, Open in Dictionary (the Dictionary tab with
/// the word and both languages) and Add to phrasebook.
///
/// A dictionary engine (the Dictionary tab's AI model) is asked only when
/// the user taps "Look up with …", with [sentence] as context, under the
/// privacy settings as every request (a consent prompt first where they
/// ask for one). Nothing is saved to the history.
Future<void> showWordLookupSheet(
  BuildContext context, {
  required String word,
  required Language language,
  Language? into,
  String? sentence,
}) {
  final service = wordLookupServiceOf(context);
  final engine = _engineOf(context);
  final uiLanguage = dictionaryUiLanguage(Localizations.localeOf(context));
  final router = GoRouter.maybeOf(context);
  final packs = maybeDictionaryPacks(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => WordLookupSheet(
      service: service,
      word: word,
      language: language,
      into: into,
      sentence: sentence ?? '',
      engine: engine,
      uiLanguage: uiLanguage,
      router: router,
      packs: packs,
    ),
  );
}

/// Opens the word card ([showWordLookupSheet]) for the word of [text] at
/// [offset] ([WordLookupService.wordAt]: in Chinese, Japanese, Thai, ...
/// the longest word of the installed dictionary of [language] there),
/// with its sentence. Nothing when there is no word at [offset].
Future<void> lookUpWordAt(
  BuildContext context, {
  required String text,
  required int offset,
  required Language language,
  Language? into,
}) async {
  final word = await wordLookupServiceOf(context)
      .wordAt(text, offset, language: language);
  if (word == null || !context.mounted) return;
  await showWordLookupSheet(
    context,
    word: word.text,
    language: language,
    into: into,
    sentence: WordSegmenter.sentenceAround(text, word),
  );
}

/// Provides the [WordLookupCubit] of the word card (and looks the word up
/// offline at once) above a [WordLookupView].
class WordLookupSheet extends StatelessWidget {
  const new({
    required this.service,
    required this.word,
    required this.language,
    this.into,
    this.sentence = '',
    this.engine,
    this.uiLanguage = 'English',
    this.router,
    this.packs,
    super.key,
  });

  final WordLookupService service;
  final String word;
  final Language language;
  final Language? into;
  final String sentence;
  final TranslationEngine? engine;
  final String uiLanguage;

  /// Opens the Dictionary tab; null hides "Open in Dictionary".
  final GoRouter? router;

  /// Offers "Get dictionaries" when no dictionary of [language] is
  /// installed; null hides it.
  final DictionaryPacks? packs;

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) {
      final cubit = WordLookupCubit(
        service: service,
        word: word,
        language: language,
        into: into,
        sentence: sentence,
        engine: engine,
        uiLanguage: uiLanguage,
      );
      unawaited(cubit.load());
      return cubit;
    },
    child: WordLookupView(router: router, packs: packs),
  );
}

/// The word card: the headword in its language with Listen and Copy, its
/// pronunciation and parts of speech, what the dictionaries said, the
/// credit of the data (or "AI-generated"), then "Look up with …", "Open
/// in Dictionary" and "Add to phrasebook…".
class WordLookupView extends StatelessWidget {
  const new({this.router, this.packs, super.key});

  /// Most senses shown; the rest are on the Dictionary tab.
  static const maxSenses = 3;

  final GoRouter? router;
  final DictionaryPacks? packs;

  /// [state]'s entry as a phrase: the headword with its first translation
  /// (else the entry's one-line summary); null without an entry.
  static PhraseDraft? phraseDraftOf(WordLookupState state) {
    final entry = state.entry;
    if (entry == null || state.isEmptyEntry) return null;
    String? translation;
    for (final sense in entry.senses) {
      for (final value in sense.translations) {
        if (value.trim().isNotEmpty) {
          translation = value.trim();
          break;
        }
      }
      if (translation != null) break;
    }
    final draft = PhraseDraft(
      text: _headword(state),
      translation: translation ?? DictionaryCubit.historySummary(entry),
      sourceCode: phraseLanguageOf(state.language),
      targetCode: phraseLanguageOf(state.into ?? Language.auto),
      origin: PhraseOrigin.dictionary,
    );
    return draft.isEmpty ? null : draft;
  }

  static String _headword(WordLookupState state) {
    final word = state.entry?.word.trim() ?? '';
    return word.isNotEmpty ? word : state.word;
  }

  void _openDictionary(BuildContext context, WordLookupState state) {
    final router = this.router;
    if (router == null) return;
    String? code(Language? language) =>
        language == null || language.isAuto || language.isCustom
        ? null
        : language.code;
    Navigator.of(context).pop();
    router.go(
      AppRoutes.dictionaryWord(
        word: state.word,
        from: code(state.language),
        to: code(state.into),
      ),
      extra: DictionaryLaunch.lookUp,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return BlocBuilder<WordLookupCubit, WordLookupState>(
      builder: (context, state) {
        final cubit = context.read<WordLookupCubit>();
        final answer = state.offlineAnswer;
        final draft = phraseDraftOf(state);
        final phrasebook = maybePhrasebookRepository(context) != null;
        return StatusAnnouncer(
          message: state.onlineStatus == WordLookupOnlineStatus.done
              ? l10n.translateDictionaryReady
              : null,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.75,
            ),
            child: SingleChildScrollView(
              key: const Key('word_lookup_sheet'),
              padding: const EdgeInsetsDirectional.fromSTEB(24, 0, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 8,
                children: [
                  _Header(state: state, headword: _headword(state)),
                  if (answer != null && !state.isOnlineEntry)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: DictionaryOfflineNotice(
                        answer: answer,
                        onWordTap: (word) => unawaited(cubit.lookUpWord(word)),
                      ),
                    ),
                  _Body(state: state, packs: packs),
                  if (state.isOnlineEntry)
                    const _AiGeneratedLabel()
                  else if (answer != null)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: DictionaryAttributionLink(
                        attribution: answer.attribution,
                      ),
                    ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (state.canLookUpOnline)
                        FilledButton.tonalIcon(
                          key: const Key('word_lookup_online'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: () => unawaited(cubit.lookUpOnline()),
                          icon: const Icon(Icons.auto_awesome_outlined),
                          label: Text(
                            l10n.wordLookupLookUpWith(state.engine!.name),
                          ),
                        ),
                      if (router != null)
                        TextButton.icon(
                          key: const Key('word_lookup_open_dictionary'),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: () => _openDictionary(context, state),
                          icon: const Icon(Icons.menu_book_outlined),
                          label: Text(l10n.translateShortOpenDictionary),
                        ),
                      if (phrasebook && draft != null)
                        TextButton.icon(
                          key: const Key('word_lookup_phrasebook'),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: () =>
                              unawaited(showAddToPhrasebook(context, draft)),
                          icon: const Icon(Icons.bookmark_add_outlined),
                          label: Text(l10n.phrasebookAdd),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The headword in its language (direction, locale, glyphs) with Listen
/// and Copy, then its pronunciation and parts of speech.
class _Header extends StatelessWidget {
  const new({required this.state, required this.headword});

  final WordLookupState state;
  final String headword;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    final language = state.language;
    final code = language.isAuto || language.isCustom ? null : language.code;
    final entry = state.entry;
    final details = [
      if (entry != null && entry.pronunciation.trim().isNotEmpty)
        entry.pronunciation.trim(),
      if (entry != null) ...entry.partsOfSpeech.where((p) => p.isNotEmpty),
    ].join(' · ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: [
              Semantics(
                header: true,
                child: Text.rich(
                  TextSpan(text: headword, locale: localeForCode(code)),
                  key: const Key('word_lookup_headword'),
                  style: theme.textTheme.headlineSmall,
                  textDirection:
                      textDirectionForCode(code) ??
                      textDirectionForText(headword),
                ),
              ),
              if (details.isNotEmpty)
                Text(
                  details,
                  key: const Key('word_lookup_details'),
                  style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                ),
            ],
          ),
        ),
        ListenButton(
          id: wordLookupSpeechId,
          text: headword,
          languageCode: code,
          tooltip: l10n.wordLookupListen(headword),
          quiet: true,
        ),
        CopyActionButton(
          key: const Key('word_lookup_copy'),
          text: headword,
          tooltip: l10n.wordLookupCopy(headword),
          quiet: true,
        ),
      ],
    );
  }
}

/// What the dictionaries said: progress, the senses, or why there are
/// none; then the explicit look-up's progress or error.
class _Body extends StatelessWidget {
  const new({required this.state, this.packs});

  final WordLookupState state;
  final DictionaryPacks? packs;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<WordLookupCubit>();
    final entry = state.entry;
    final message = theme.textTheme.bodyLarge;
    final packs = this.packs;
    final offline = switch (state.status) {
      _ when state.isOnlineEntry => null,
      WordLookupStatus.loading => _Progress(word: state.word),
      WordLookupStatus.found when entry != null && !state.isEmptyEntry =>
        _Senses(entry: entry, into: state.into),
      WordLookupStatus.found => Text(
        l10n.wordLookupNoEntry(state.word),
        style: message,
      ),
      WordLookupStatus.notFound => Text(
        state.engine == null
            ? l10n.dictionaryOfflineNotFoundBody
            : l10n.wordLookupNotFound(state.word),
        key: const Key('word_lookup_not_found'),
        style: message,
      ),
      WordLookupStatus.noDictionary => Column(
        key: const Key('word_lookup_no_dictionary'),
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Text(
            l10n.dictionaryOfflineNoPack(context.languageName(state.language)),
            style: message,
          ),
          if (packs != null && packs.isSupported)
            DictionaryGetPacksButton(packs: packs),
        ],
      ),
    };
    final online = switch (state.onlineStatus) {
      WordLookupOnlineStatus.idle => null,
      WordLookupOnlineStatus.loading => _Progress(word: state.word),
      WordLookupOnlineStatus.done when entry != null && !state.isEmptyEntry =>
        _Senses(entry: entry, into: state.into),
      WordLookupOnlineStatus.done => Text(
        l10n.wordLookupNoEntry(state.word),
        style: message,
      ),
      WordLookupOnlineStatus.failure => TranslateErrorView(
        key: const Key('word_lookup_error'),
        error: state.error,
        dense: true,
        onRetry: () => unawaited(cubit.lookUpOnline()),
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [?offline, ?online],
    );
  }
}

class _Progress extends StatelessWidget {
  const new({required this.word});

  final String word;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: LinearProgressIndicator(
      key: const Key('word_lookup_progress'),
      semanticsLabel: context.l10n.wordLookupLookingUp(word),
    ),
  );
}

/// The first [WordLookupView.maxSenses] senses of [entry], numbered, each
/// with its translations into [into], and how many more the Dictionary
/// tab has.
class _Senses extends StatelessWidget {
  const new({required this.entry, this.into});

  final DictionaryEntry entry;
  final Language? into;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    final senses = [
      for (final sense in entry.senses)
        if (sense.definition.trim().isNotEmpty || sense.translations.isNotEmpty)
          sense,
    ];
    final shown = senses.take(WordLookupView.maxSenses).toList();
    final into = this.into;
    return Column(
      key: const Key('word_lookup_senses'),
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        for (final (index, sense) in shown.indexed)
          Row(
            key: ValueKey('word_lookup_sense:$index'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 24,
                child: Text(
                  '${index + 1}.',
                  style: theme.textTheme.bodyLarge?.copyWith(color: muted),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    if (sense.definition.trim().isNotEmpty)
                      Text(
                        sense.definition.trim(),
                        style: theme.textTheme.bodyLarge,
                      ),
                    if (sense.translations.isNotEmpty)
                      Text(
                        into == null
                            ? sense.translations.join(', ')
                            : l10n.wordLookupTranslations(
                                context.languageName(into),
                                sense.translations.join(', '),
                              ),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        if (senses.length > shown.length)
          Text(
            l10n.wordLookupMoreMeanings(senses.length - shown.length),
            key: const Key('word_lookup_more'),
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
      ],
    );
  }
}

/// "AI-generated", small and muted, under an entry of the engine.
class _AiGeneratedLabel extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    return Row(
      key: const Key('word_lookup_ai_generated'),
      spacing: 6,
      children: [
        Icon(Icons.auto_awesome_outlined, size: 14, color: muted),
        Text(
          context.l10n.translateAiGenerated,
          style: theme.textTheme.labelSmall?.copyWith(color: muted),
        ),
      ],
    );
  }
}
