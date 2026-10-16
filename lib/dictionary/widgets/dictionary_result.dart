import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/dictionary/cubit/dictionary_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/view/widgets/empty_state_view.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/ai_generated_header.dart';
import 'package:mozhi/translate/widgets/dictionary_card.dart';
import 'package:mozhi/translate/widgets/status_announcer.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';

/// What the dictionary shows below the search: the entry, or the loading,
/// error, empty and "no AI provider" states.
///
/// The entry's related words (chips) and "Did you mean …?" (a link) look
/// that word up ([DictionaryCubit.lookUpWord]).
class DictionaryResult extends StatelessWidget {
  const new({super.key});

  /// Route of the AI provider settings.
  static const providersRoute = '/settings/providers';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final enginesStatus = context.select<TranslateCubit, EnginesStatus>(
      (cubit) => cubit.state.enginesStatus,
    );
    return BlocBuilder<DictionaryCubit, DictionaryState>(
      builder: (context, state) {
        final cubit = context.read<DictionaryCubit>();
        final entry = state.entry;
        final Widget body;
        if (!state.hasEngine) {
          body = switch (enginesStatus) {
            EnginesStatus.initial || EnginesStatus.loading => Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: CircularProgressIndicator(
                  semanticsLabel: l10n.translateLoading,
                ),
              ),
            ),
            EnginesStatus.failure => _Message(
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
            EnginesStatus.ready => _Message(
              key: const Key('dictionary_no_engine'),
              icon: Icons.menu_book_outlined,
              title: l10n.dictionaryNoEngineTitle,
              body: l10n.dictionaryNoEngineBody,
              action: FilledButton.icon(
                key: const Key('dictionary_set_up_providers'),
                style: FilledButton.styleFrom(shape: const StadiumBorder()),
                onPressed: () => GoRouter.maybeOf(context)?.go(providersRoute),
                icon: const Icon(Icons.add),
                label: Text(l10n.dictionaryNoEngineAction),
              ),
            ),
          };
        } else {
          body = switch (state.status) {
            DictionaryStatus.idle => _Message(
              key: const Key('dictionary_empty'),
              icon: Icons.menu_book_outlined,
              title: l10n.dictionaryEmptyTitle,
              body: l10n.dictionaryEmptyBody,
            ),
            DictionaryStatus.loading => Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: LinearProgressIndicator(
                semanticsLabel: l10n.dictionaryLoading,
              ),
            ),
            DictionaryStatus.failure => TranslateErrorView(
              error: state.error,
              onRetry: () => unawaited(cubit.lookUp()),
            ),
            DictionaryStatus.success when entry == null || state.isEmptyEntry =>
              _Message(
                key: const Key('dictionary_not_found'),
                icon: Icons.search_off,
                title: l10n.dictionaryNotFound(state.lookedUp),
              ),
            DictionaryStatus.success => _EntryCard(state: state),
          };
        }
        return StatusAnnouncer(
          message:
              state.status == DictionaryStatus.success &&
                  state.hasEngine &&
                  !state.isEmptyEntry
              ? l10n.dictionaryReady
              : null,
          child: body,
        );
      },
    );
  }
}

/// The entry as a flat section between hairlines (no tinted card).
class _EntryCard extends StatelessWidget {
  const new({required this.state});

  final DictionaryState state;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('dictionary_entry'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Hairline(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AiGeneratedHeader(
                icon: Icons.menu_book_outlined,
                title: context.l10n.dictionaryTitle,
              ),
              const SizedBox(height: 12),
              DictionaryEntryView(
                entry: state.entry!,
                sourceLanguage: state.source.isAuto ? null : state.source,
                targetLanguage: state.target,
                query: state.lookedUp,
                onWordTap: (word) =>
                    unawaited(context.read<DictionaryCubit>().lookUpWord(word)),
              ),
            ],
          ),
        ),
        const Hairline(),
      ],
    );
  }
}

/// An icon, a title, an optional explanation and an optional action.
class _Message extends StatelessWidget {
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
