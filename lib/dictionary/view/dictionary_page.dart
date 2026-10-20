import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/translate_link.dart'
    show TranslateLink, matchLanguage;
import 'package:mozhi/app/view/top_level_actions.dart';
import 'package:mozhi/core/widgets/composer_card.dart';
import 'package:mozhi/core/widgets/tab_hero.dart';
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
/// translations of a word or phrase ([TranslationRepository.lookUp]). A
/// tab of the app; the translate screen also pushes it with a word.
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
/// even with `instantTranslateAi`: the user presses Look up. The detail
/// level starts as the translate screen's dictionary card has it
/// ([TranslateState.dictionaryVerbosity]).
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
          verbosity: translate.dictionaryVerbosity,
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

/// The dictionary screen, like Kagi Translate's.
///
/// Without an entry (the status is idle): the greeting ([DictionaryHero])
/// or, without an AI engine, why there is none
/// ([DictionaryEngineMessage]), above the composer docked at the bottom
/// ([DictionaryComposer]: the search field, the microphone and the bar
/// [options | go | languages]). Enter or the go button looks the word up.
///
/// Once a word is looked up: the entry in tabs ([DictionaryResultView]),
/// with a back arrow in the app bar (system back does the same) that
/// returns to the search with the word kept, the options button beside
/// History and Settings, and "New look-up", which clears the word and
/// focuses the search.
///
/// On large screens the composer and the entry are centred columns.
class DictionaryView extends StatefulWidget {
  const new({this.autofocus = false, super.key});

  /// Focus the search field on arrival.
  final bool autofocus;

  /// Width from which the composer uses the large-screen layout.
  static const double wideBreakpoint = ComposerLayout.wideBreakpoint;

  @override
  State<DictionaryView> createState() => _DictionaryViewState();
}

class _DictionaryViewState extends State<DictionaryView> {
  final _searchFocus = FocusNode(debugLabel: 'dictionary_search_field');

  /// Whether the search field takes the focus when it shows: only on
  /// arrival, not when back from an entry.
  late bool _autofocus = widget.autofocus;

  @override
  void dispose() {
    _searchFocus.dispose();
    super.dispose();
  }

  /// Clears the word and focuses the search field once it is back.
  void _newLookUp() {
    context.read<DictionaryCubit>().clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<DictionaryCubit>();
    final showEntry = context.select<DictionaryCubit, bool>(
      (cubit) => cubit.state.status != DictionaryStatus.idle,
    );
    if (showEntry) _autofocus = false;
    return BlocListener<TranslateCubit, TranslateState>(
      // Engine equality ignores details such as the model, so compare
      // instances to pick up edited providers.
      listenWhen: (previous, current) =>
          !identical(previous.engines, current.engines) ||
          !identical(previous.assistEngine, current.assistEngine),
      listener: (context, state) =>
          context.read<DictionaryCubit>().setEngine(dictionaryEngine(state)),
      child: PopScope(
        // Back from an entry returns to the search first.
        canPop: !showEntry,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && showEntry) cubit.closeEntry();
        },
        child: Scaffold(
          appBar: AppBar(
            leading: showEntry
                ? IconButton(
                    key: const Key('dictionary_back'),
                    tooltip: MaterialLocalizations.of(context)
                        .backButtonTooltip,
                    icon: const BackButtonIcon(),
                    onPressed: cubit.closeEntry,
                  )
                : null,
            title: Text(l10n.dictionaryTitle),
            actions: [
              if (showEntry)
                const DictionaryOptionsButton(
                  key: Key('dictionary_result_options'),
                ),
              const TopLevelActions(),
              const SizedBox(width: 4),
            ],
          ),
          body: SafeArea(
            top: false,
            child: showEntry
                ? DictionaryResultView(onNewLookUp: _newLookUp)
                : _SearchLayout(focusNode: _searchFocus, autofocus: _autofocus),
          ),
        ),
      ),
    );
  }
}

/// The dictionary without an entry: the greeting (or the engine message)
/// above the docked composer. A window too low for both
/// ([ComposerLayout.heroMinHeight]) shows the composer alone, at the
/// bottom.
class _SearchLayout extends StatelessWidget {
  const new({required this.focusNode, required this.autofocus});

  final FocusNode focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final hasEngine = context.select<DictionaryCubit, bool>(
      (cubit) => cubit.state.hasEngine,
    );
    final composer = DictionaryComposer(
      focusNode: focusNode,
      autofocus: autofocus,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= DictionaryView.wideBreakpoint;
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        if (constraints.maxHeight < ComposerLayout.heroMinHeight(textScale)) {
          return Align(
            alignment: Alignment.bottomCenter,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(ComposerLayout.margin),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: ComposerLayout.maxColumnWidth,
                ),
                child: composer,
              ),
            ),
          );
        }
        return ComposerLayout(
          wide: wide,
          hero: hasEngine
              ? const DictionaryHero()
              : const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: DictionaryEngineMessage(),
                ),
          composer: composer,
        );
      },
    );
  }
}

/// "What does this mean?" with what the dictionary does, above the
/// composer until a word is looked up.
class DictionaryHero extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      key: const Key('dictionary_hero'),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: TabHero(
        icon: Icons.menu_book_rounded,
        title: l10n.dictionaryHeroTitle,
        body: l10n.dictionaryEmptyBody,
      ),
    );
  }
}
