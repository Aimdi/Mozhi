import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/translate_link.dart'
    show TranslateLink, matchLanguage;
import 'package:mozhi/dictionary/cubit/dictionary_cubit.dart';
import 'package:mozhi/dictionary/widgets/widgets.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:translation_repository/translation_repository.dart';

/// Pass as the navigation's `extra` (`context.push(location, extra:
/// DictionaryLaunch.lookUp)`) to look the word up right away. Links from
/// outside the app cannot carry it.
enum DictionaryLaunch { lookUp }

/// The AI dictionary: definitions, pronunciation, examples and
/// translations of a word or phrase ([TranslationRepository.lookUp]).
///
/// Needs the app-wide [TranslateCubit] (for the AI engine: its assist
/// engine, else the first engine with AI extras) and a
/// [TranslationRepository] above it.
///
/// [word], [from] and [to] usually come from a link
/// (`/dictionary?word=…&from=…&to=…`): the word is cut to
/// [DictionaryCubit.maxWordLength] and unknown languages are ignored (the
/// translate screen's languages are used instead). The word is only looked
/// up right away with [autoLookUp] (navigation inside the app); a link
/// from outside the app never starts a (paid) AI request on its own, not
/// even with `instantTranslateAi`: the user presses Look up.
class DictionaryPage extends StatelessWidget {
  const new({
    this.word,
    this.from,
    this.to,
    this.autoLookUp = false,
    super.key,
  });

  final String? word;

  /// Language of [word] (code or name, `auto` to detect).
  final String? from;

  /// Language of the translations (code or name).
  final String? to;

  /// Look [word] up as soon as an AI engine is available.
  final bool autoLookUp;

  @override
  Widget build(BuildContext context) {
    final uiLanguage = dictionaryUiLanguage(Localizations.localeOf(context));
    return BlocProvider(
      create: (context) {
        final translate = context.read<TranslateCubit>().state;
        final cubit = DictionaryCubit(
          repository: context.read<TranslationRepository>(),
          engine: dictionaryEngine(translate),
          word: word?.trim() ?? '',
          source:
              _fromLink(from, DictionaryLanguageBar.sourceLanguages) ??
              _known(translate.source, DictionaryLanguageBar.sourceLanguages) ??
              Language.auto,
          target:
              _fromLink(to, DictionaryLanguageBar.targetLanguages) ??
              _known(translate.target, DictionaryLanguageBar.targetLanguages) ??
              const Language(code: 'en', name: 'English'),
          uiLanguage: uiLanguage,
          usageTracker: _usageTracker(context),
        );
        if (autoLookUp) unawaited(cubit.lookUp());
        return cubit;
      },
      child: DictionaryView(autofocus: word?.trim().isNotEmpty != true),
    );
  }

  /// The language a link names, when it is one of [available].
  static Language? _fromLink(String? value, List<Language> available) {
    final query = value?.trim();
    if (query == null ||
        query.isEmpty ||
        query.length > TranslateLink.maxLanguageLength) {
      return null;
    }
    final match = matchLanguage(query, available);
    return match == null || match.isCustom ? null : match;
  }

  /// [language] as listed in [available] (null for custom styles and
  /// languages that are not listed).
  static Language? _known(Language language, List<Language> available) =>
      language.isCustom ? null : LanguageMatcher.match(language, available);
}

/// English name of the UI language: definitions and notes are written in
/// it.
String dictionaryUiLanguage(Locale locale) {
  if (locale.languageCode == 'en') return 'English';
  return LanguageCatalog.byCode(locale.languageCode)?.name ?? 'English';
}

/// The AI engine the dictionary uses with [state]: its assist engine when
/// that can do AI extras, else the first engine that can, else null.
TranslationEngine? dictionaryEngine(TranslateState state) {
  final assist = state.assistEngine;
  if (assist != null && assist.supportsExtras) return assist;
  for (final engine in state.engines) {
    if (engine.supportsExtras) return engine;
  }
  return null;
}

/// The app's usage tracker, or null when none is provided (e.g. in tests).
UsageTracker? _usageTracker(BuildContext context) {
  try {
    return context.read<UsageTracker>();
  } on ProviderNotFoundException {
    return null;
  }
}

class DictionaryView extends StatelessWidget {
  const new({this.autofocus = false, super.key});

  /// Focus the search field on arrival.
  final bool autofocus;

  /// Width from which the search and the entry are side by side.
  static const wideBreakpoint = 840.0;

  /// Where the back button goes when there is nothing to go back to (the
  /// page was opened by a link).
  static const translateRoute = '/translate';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final router = GoRouter.maybeOf(context);
    final canPop = router?.canPop() ?? Navigator.of(context).canPop();
    final controls = _Controls(autofocus: autofocus);
    return BlocListener<TranslateCubit, TranslateState>(
      // Engine equality ignores details such as the model, so compare
      // instances to pick up edited providers.
      listenWhen: (previous, current) =>
          !identical(previous.engines, current.engines) ||
          !identical(previous.assistEngine, current.assistEngine),
      listener: (context, state) =>
          context.read<DictionaryCubit>().setEngine(dictionaryEngine(state)),
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.dictionaryTitle),
          leading: canPop || router == null
              ? null
              : IconButton(
                  key: const Key('dictionary_back'),
                  tooltip: l10n.dictionaryBack,
                  icon: const BackButtonIcon(),
                  onPressed: () => router.go(translateRoute),
                ),
        ),
        body: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= wideBreakpoint) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 400,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(24, 16, 12, 24),
                        child: controls,
                      ),
                    ),
                    const Expanded(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(12, 16, 24, 24),
                        child: DictionaryResult(),
                      ),
                    ),
                  ],
                );
              }
              return SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 16,
                      children: [controls, const DictionaryResult()],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Search field, languages and the engine in use.
class _Controls extends StatelessWidget {
  const new({required this.autofocus});

  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final engine = context.select<DictionaryCubit, TranslationEngine?>(
      (cubit) => cubit.state.engine,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        DictionarySearchField(autofocus: autofocus),
        const DictionaryLanguageBar(),
        if (engine != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 16, end: 16),
            child: Text(
              context.l10n.dictionaryEngine(engine.name),
              key: const Key('dictionary_engine'),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
