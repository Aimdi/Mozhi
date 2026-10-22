import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/composer_card.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/dictionary/cubit/dictionary_cubit.dart';
import 'package:mozhi/dictionary/widgets/dictionary_composer.dart';
import 'package:mozhi/dictionary/widgets/dictionary_entry_tabs.dart';
import 'package:mozhi/dictionary/widgets/dictionary_favorite_button.dart';
import 'package:mozhi/dictionary/widgets/dictionary_search_field.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/view/widgets/empty_state_view.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/status_announcer.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';

/// Route of the AI provider settings.
const dictionaryProvidersRoute = '/settings/providers';

/// What the empty dictionary shows above its composer while it has no AI
/// engine: a spinner while the engines load, a retry when they failed to
/// load, else "The dictionary needs an AI provider" with a link to the
/// provider settings. Nothing ([SizedBox.shrink]) with an engine.
class DictionaryEngineMessage extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final hasEngine = context.select<DictionaryCubit, bool>(
      (cubit) => cubit.state.hasEngine,
    );
    final enginesStatus = context.select<TranslateCubit, EnginesStatus>(
      (cubit) => cubit.state.enginesStatus,
    );
    if (hasEngine) return const SizedBox.shrink();
    return switch (enginesStatus) {
      EnginesStatus.initial || EnginesStatus.loading => Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: CircularProgressIndicator(
            semanticsLabel: l10n.translateLoading,
          ),
        ),
      ),
      EnginesStatus.failure => DictionaryMessage(
        key: const Key('dictionary_engines_error'),
        icon: Icons.cloud_off_outlined,
        error: true,
        title: l10n.dictionaryEnginesErrorTitle,
        body: l10n.dictionaryEnginesErrorBody,
        action: FilledButton.icon(
          style: FilledButton.styleFrom(shape: const StadiumBorder()),
          onPressed: () => unawaited(
            context.read<TranslateCubit>().loadEngines(refresh: true),
          ),
          icon: const Icon(Icons.refresh),
          label: Text(l10n.commonRetry),
        ),
      ),
      EnginesStatus.ready => DictionaryMessage(
        key: const Key('dictionary_no_engine'),
        icon: Icons.menu_book_outlined,
        title: l10n.dictionaryNoEngineTitle,
        body: l10n.dictionaryNoEngineBody,
        action: FilledButton.icon(
          key: const Key('dictionary_set_up_providers'),
          style: FilledButton.styleFrom(shape: const StadiumBorder()),
          // Above the tabs: back returns to the dictionary.
          onPressed: () => unawaited(
            GoRouter.maybeOf(context)?.push<void>(dictionaryProvidersRoute),
          ),
          icon: const Icon(Icons.add),
          label: Text(l10n.dictionaryNoEngineAction),
        ),
      ),
    };
  }
}

/// The dictionary once a word is looked up (the status is not idle): the
/// search bar stays on top ([DictionarySearchBar]: the word, its languages
/// and Look up, so the next word is one edit away), above the entry in
/// tabs ([DictionaryEntryTabs], with the favorite heart
/// [DictionaryFavoriteButton] beside Listen), or the look-up in progress,
/// its error (with Retry, or the consent prompt) or "No entry found", all
/// from the top of the page. Synonyms, related words and "Did you mean
/// …?" look that word up ([DictionaryCubit.lookUpWord]). Screen readers
/// hear "Dictionary entry ready".
///
/// [focusNode] is the search field's.
class DictionaryResultView extends StatelessWidget {
  const new({this.focusNode, super.key});

  final FocusNode? focusNode;

  /// Max width of the entry on large screens.
  static const double maxWidth = 720;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return BlocBuilder<DictionaryCubit, DictionaryState>(
      buildWhen: (previous, current) =>
          previous.status != current.status ||
          previous.entry != current.entry ||
          previous.error != current.error ||
          previous.lookedUp != current.lookedUp ||
          previous.source != current.source ||
          previous.target != current.target ||
          previous.entryLanguage != current.entryLanguage,
      builder: (context, state) {
        final cubit = context.read<DictionaryCubit>();
        final entry = state.entry;
        final body = switch (state.status) {
          DictionaryStatus.idle => const SizedBox.shrink(),
          DictionaryStatus.loading => _LoadingEntry(word: state.lookedUp),
          DictionaryStatus.failure => _TopAligned(
            child: TranslateErrorView(
              error: state.error,
              onRetry: () => unawaited(cubit.lookUp()),
            ),
          ),
          DictionaryStatus.success when entry == null || state.isEmptyEntry =>
            _TopAligned(
              child: DictionaryMessage(
                key: const Key('dictionary_not_found'),
                icon: Icons.search_off,
                title: l10n.dictionaryNotFound(state.lookedUp),
              ),
            ),
          DictionaryStatus.success => DictionaryEntryTabs(
            entry: entry!,
            sourceLanguage: state.source.isAuto ? null : state.source,
            targetLanguage: state.target,
            query: state.lookedUp,
            speechLanguage: state.entryLanguage,
            onWordTap: (word) => unawaited(cubit.lookUpWord(word)),
            actions: const [DictionaryFavoriteButton()],
          ),
        };
        return StatusAnnouncer(
          message:
              state.status == DictionaryStatus.success && !state.isEmptyEntry
              ? l10n.dictionaryReady
              : null,
          child: Column(
            key: const Key('dictionary_result'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: maxWidth),
                    child: DictionarySearchBar(focusNode: focusNode),
                  ),
                ),
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: maxWidth),
                    child: SizedBox.expand(child: body),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The search bar above an entry: a hairline pill ([ComposerBar]) with the
/// word ([DictionarySearchField], `dense`), Clear and the go button
/// ([DictionaryGoButton]), and the languages ([DictionaryLanguagePair])
/// inline on wide windows (from [inlineBreakpoint]) or just below the
/// pill on narrow ones. Enter or the go button looks the edited word up.
///
/// For keyboard users (the focus highlight is on) the field takes the
/// focus when the bar appears, so the next word can be typed right away;
/// on touch screens it does not, so no keyboard covers the entry.
class DictionarySearchBar extends StatelessWidget {
  const new({this.focusNode, super.key});

  /// Width from which the languages sit inside the pill.
  static const double inlineBreakpoint = 560;

  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final field = Row(
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 12, end: 4),
          child: Icon(
            Icons.search,
            size: 20,
            color: AppPalette.of(context).secondaryText,
          ),
        ),
        Expanded(
          child: DictionarySearchField(
            focusNode: focusNode,
            dense: true,
            autofocus:
                FocusManager.instance.highlightMode ==
                FocusHighlightMode.traditional,
          ),
        ),
        DictionaryClearButton(focusNode: focusNode),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= inlineBreakpoint) {
          return ComposerBar(
            key: const Key('dictionary_search_bar'),
            children: [
              Expanded(flex: 3, child: field),
              const Expanded(flex: 2, child: DictionaryLanguagePair()),
              const DictionaryGoButton(),
            ],
          );
        }
        return Column(
          key: const Key('dictionary_search_bar'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ComposerBar(
              children: [
                Expanded(child: field),
                const DictionaryGoButton(),
              ],
            ),
            const SizedBox(height: 4),
            const Align(
              alignment: AlignmentDirectional.centerStart,
              child: SizedBox(width: 320, child: DictionaryLanguagePair()),
            ),
          ],
        );
      },
    );
  }
}

/// Scrolls [child] from the top of the page.
class _TopAligned extends StatelessWidget {
  const new({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    child: child,
  );
}

/// The word being looked up, large, above a progress bar.
class _LoadingEntry extends StatelessWidget {
  const new({required this.word});

  final String word;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _TopAligned(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            word,
            textAlign: TextAlign.center,
            style: theme.textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: 160,
            child: LinearProgressIndicator(
              key: const Key('dictionary_loading'),
              semanticsLabel: context.l10n.dictionaryLoading,
              borderRadius: const BorderRadius.all(Radius.circular(2)),
            ),
          ),
        ],
      ),
    );
  }
}

/// An icon, a title, an optional explanation and an optional action.
class DictionaryMessage extends StatelessWidget {
  const new({
    required this.icon,
    required this.title,
    this.body,
    this.action,
    this.error = false,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;

  /// Whether this reports a failure (error-tinted icon).
  final bool error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: EmptyStateView(
        icon: icon,
        title: title,
        body: body,
        action: action,
        tone: error ? EmptyStateTone.error : EmptyStateTone.neutral,
        announce: true,
        compact: true,
      ),
    );
  }
}
