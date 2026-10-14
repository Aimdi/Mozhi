import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/dictionary_card.dart';
import 'package:mozhi/translate/widgets/explain_sheet.dart';
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:mozhi/translate/widgets/refine_chips.dart';
import 'package:mozhi/translate/widgets/status_announcer.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

export 'package:mozhi/translate/widgets/refine_chips.dart';

/// AI extras under a finished translation: refinement chips (AI engines),
/// alternatives, explain and (short inputs) a dictionary card. Hidden while
/// the translation belongs to text the user has since edited.
class ExtrasSection extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocListener<TranslateCubit, TranslateState>(
      // A failed refinement keeps the translation; say why it did not
      // change.
      listenWhen: (previous, current) =>
          current.refinementError != null &&
          current.refinementError != previous.refinementError,
      listener: _showRefinementError,
      child: BlocBuilder<TranslateCubit, TranslateState>(
        builder: (context, state) {
          if (!state.hasExtras ||
              state.output.trim().isEmpty ||
              state.status != TranslateStatus.success ||
              state.isResultStale) {
            return const SizedBox.shrink();
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (state.isAiEngine) ...[
                const SizedBox(height: TranslateLayout.gap),
                RefinementChips(state: state),
              ],
              const SizedBox(height: TranslateLayout.gap),
              _ExtrasCard(state: state),
              if (state.isShortInput) ...[
                const SizedBox(height: TranslateLayout.gap),
                const DictionaryCard(),
              ],
            ],
          );
        },
      ),
    );
  }

  static void _showRefinementError(BuildContext context, TranslateState state) {
    final l10n = context.l10n;
    final reason = describeTranslateError(l10n, state.refinementError).message;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const Key('translate_refinement_error'),
          content: Text(l10n.translateRefinementFailed(reason)),
        ),
      );
  }
}

class _ExtrasCard extends StatelessWidget {
  const new({required this.state});

  final TranslateState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<TranslateCubit>();
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      color: theme.colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: TranslateLayout.cardBorderRadius,
      ),
      child: Column(
        children: [
          Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              // Collapse whenever the translation changes.
              key: ValueKey('alternatives:${state.output}'),
              leading: const Icon(Icons.alt_route),
              title: Text(l10n.translateAlternatives),
              onExpansionChanged: (expanded) {
                // Alternatives for a selected part (see
                // showSpanAlternativesSheet) are replaced by ones for the
                // whole translation.
                if (expanded &&
                    (state.alternativesStatus == ExtraStatus.idle ||
                        state.alternativesStatus == ExtraStatus.failure ||
                        state.alternativesSpan != null)) {
                  unawaited(cubit.loadAlternatives());
                }
              },
              childrenPadding: const EdgeInsets.only(bottom: 8),
              children: [AlternativesList(state: state)],
            ),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            key: const Key('translate_explain_button'),
            leading: const Icon(Icons.school_outlined),
            title: Text(l10n.translateExplain),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              if (state.explainStatus == ExtraStatus.idle ||
                  state.explainStatus == ExtraStatus.failure) {
                unawaited(cubit.explain());
              }
              unawaited(showExplainSheet(context));
            },
          ),
        ],
      ),
    );
  }
}

/// Opens a sheet with the alternatives for a selected part of the
/// translation (`TranslateState.alternativesSpan`), as requested with
/// `TranslateCubit.loadAlternatives(span: ..., spanStart: ...)`. Using one
/// replaces that part of the translation and closes the sheet.
Future<void> showSpanAlternativesSheet(BuildContext context) {
  final cubit = context.read<TranslateCubit>();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetContext) => BlocProvider.value(
      value: cubit,
      child: SpanAlternativesSheet(
        onUsed: () => Navigator.of(sheetContext).pop(),
      ),
    ),
  );
}

/// Title and [AlternativesList] for the selected part of the translation.
class SpanAlternativesSheet extends StatelessWidget {
  const new({this.onUsed, super.key});

  /// Called after an alternative was used.
  final VoidCallback? onUsed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return BlocBuilder<TranslateCubit, TranslateState>(
      builder: (context, state) {
        final span = state.alternativesSpan?.trim() ?? '';
        return SingleChildScrollView(
          key: const Key('translate_span_alternatives_sheet'),
          padding: const EdgeInsets.only(bottom: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Semantics(
                  header: true,
                  child: Text(
                    span.isEmpty
                        ? l10n.translateAlternatives
                        : l10n.translateSpanAlternativesTitle(span),
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ),
              AlternativesList(state: state, onUsed: onUsed),
            ],
          ),
        );
      },
    );
  }
}

/// Body of the "Alternatives" panel. Screen readers hear how many
/// alternatives arrived (or that there are none).
class AlternativesList extends StatelessWidget {
  const new({required this.state, this.onUsed, super.key});

  final TranslateState state;

  /// Called after an alternative was used.
  final VoidCallback? onUsed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final count = state.alternatives?.alternatives.length ?? 0;
    return StatusAnnouncer(
      message: state.alternativesStatus == ExtraStatus.ready
          ? (count == 0
                ? l10n.translateAlternativesEmpty
                : l10n.translateAlternativesLoaded(count))
          : null,
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<TranslateCubit>();
    final alternatives = state.alternatives;
    final locale = localeForLanguage(state.target);
    final direction = textDirectionForLanguage(state.target);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    const padding = EdgeInsets.symmetric(horizontal: 16, vertical: 8);
    switch (state.alternativesStatus) {
      case ExtraStatus.idle:
        return const SizedBox.shrink();
      case ExtraStatus.loading:
        return Padding(
          padding: padding,
          child: LinearProgressIndicator(
            key: const Key('translate_alternatives_progress'),
            semanticsLabel: l10n.translateLoading,
          ),
        );
      case ExtraStatus.failure:
        return Padding(
          padding: padding,
          child: TranslateErrorView(
            error: state.extraError,
            dense: true,
            onRetry: () => unawaited(
              cubit.loadAlternatives(
                span: state.alternativesSpan,
                spanStart: state.alternativesSpanStart,
              ),
            ),
          ),
        );
      case ExtraStatus.ready:
        if (alternatives == null || alternatives.alternatives.isEmpty) {
          return Padding(
            padding: padding,
            child: Text(l10n.translateAlternativesEmpty),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (alternatives.description.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  alternatives.description,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            for (final Alternative(:text, :explanation)
                in alternatives.alternatives)
              ListTile(
                title: Text.rich(
                  TextSpan(text: text, locale: locale),
                  textDirection: direction ?? textDirectionForText(text),
                ),
                subtitle: explanation.isEmpty ? null : Text(explanation),
                // "Move up into the output": points to the start edge.
                trailing: Icon(rtl ? Icons.north_east : Icons.north_west),
                onTap: () {
                  cubit.useAlternative(text);
                  onUsed?.call();
                },
              ),
          ],
        );
    }
  }
}
