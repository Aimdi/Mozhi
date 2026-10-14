import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/dictionary/cubit/dictionary_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/ai_generated_header.dart';
import 'package:mozhi/translate/widgets/dictionary_card.dart';
import 'package:mozhi/translate/widgets/status_announcer.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';

/// What the dictionary shows below the search: the entry, or the loading,
/// error, empty and "no AI provider" states.
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
              iconColor: Theme.of(context).colorScheme.error,
              title: l10n.dictionaryEnginesErrorTitle,
              body: l10n.dictionaryEnginesErrorBody,
              action: FilledButton.icon(
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

class _EntryCard extends StatelessWidget {
  const new({required this.state});

  final DictionaryState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('dictionary_entry'),
      margin: EdgeInsets.zero,
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
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
            ),
          ],
        ),
      ),
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
    this.iconColor,
    super.key,
  });

  final IconData icon;
  final Color? iconColor;
  final String title;
  final String? body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = this.body;
    final action = this.action;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Semantics(
            liveRegion: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 16,
              children: [
                Icon(
                  icon,
                  size: 56,
                  color: iconColor ?? theme.colorScheme.primary,
                ),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge,
                ),
                if (body != null)
                  Text(
                    body,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ?action,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
