import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/explain_sheet.dart';
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:mozhi/translate/widgets/status_announcer.dart';
import 'package:mozhi/translate/widgets/tool_chip.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

export 'package:mozhi/translate/widgets/refine_chips.dart';

/// "Learn": the AI extras under a finished translation in the "Tools" area,
/// as rows like the tools above them ([TranslateToolRow]): "Alternatives"
/// (unfolds the alternatives in place) and "Explain" (opens the
/// explanation). Hidden while the translation belongs to text the user has
/// since edited, and while not [expanded] (the translate screen's "Tools"
/// area is closed).
///
/// The refinement chips are with the translation's actions (see
/// `OutputCard`) and the AI dictionary with the short-input panel
/// (`ShortQueryPanel`); a failed refinement is reported here, as a snack
/// bar, whether the area is open or not.
class ExtrasSection extends StatelessWidget {
  const new({this.expanded = true, super.key});

  /// Whether the section is shown (when there is something to show).
  final bool expanded;

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
        builder: (context, state) => AnimatedSize(
          duration: TranslateLayout.motion(context),
          curve: Curves.easeOutCubic,
          alignment: AlignmentDirectional.topStart,
          child: _section(context, state),
        ),
      ),
    );
  }

  Widget _section(BuildContext context, TranslateState state) {
    if (!expanded ||
        !state.hasExtras ||
        state.output.trim().isEmpty ||
        state.status != TranslateStatus.success ||
        state.isResultStale) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Padding(
      key: const Key('translate_refine_and_learn'),
      padding: const EdgeInsetsDirectional.only(start: 4, end: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(
              start: 8,
              top: 8,
              bottom: 4,
            ),
            child: Semantics(
              header: true,
              child: Text(
                context.l10n.translateToolsLearn,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: AppPalette.of(context).secondaryText,
                ),
              ),
            ),
          ),
          _ExtrasRows(state: state),
        ],
      ),
    );
  }

  static void _showRefinementError(BuildContext context, TranslateState state) {
    final l10n = context.l10n;
    final error = state.refinementError;
    final reason = describeTranslateError(l10n, error).message;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const Key('translate_refinement_error'),
          content: Text(
            error is ConsentRequiredException
                ? reason
                : l10n.translateRefinementFailed(reason),
          ),
          // Nothing was sent: the user may allow it, then tap the chip
          // again.
          action: error is ConsentRequiredException
              ? SnackBarAction(
                  label: l10n.commonConsentReview,
                  onPressed: () => unawaited(askConsent(context, error)),
                )
              : null,
        ),
      );
  }
}

/// "Alternatives" (unfolds in place) and "Explain" (opens the sheet).
/// The alternatives fold up again whenever the translation changes.
class _ExtrasRows extends StatefulWidget {
  const new({required this.state});

  final TranslateState state;

  @override
  State<_ExtrasRows> createState() => _ExtrasRowsState();
}

class _ExtrasRowsState extends State<_ExtrasRows> {
  bool _alternatives = false;

  @override
  void didUpdateWidget(_ExtrasRows oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.output != widget.state.output) _alternatives = false;
  }

  void _toggleAlternatives() {
    final state = widget.state;
    setState(() => _alternatives = !_alternatives);
    // Alternatives for a selected part (see showSpanAlternativesSheet) are
    // replaced by ones for the whole translation.
    if (_alternatives &&
        (state.alternativesStatus == ExtraStatus.idle ||
            state.alternativesStatus == ExtraStatus.failure ||
            state.alternativesSpan != null)) {
      unawaited(context.read<TranslateCubit>().loadAlternatives());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = widget.state;
    final cubit = context.read<TranslateCubit>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TranslateToolRow(
          key: const Key('translate_alternatives_button'),
          icon: Icons.alt_route,
          label: l10n.translateAlternatives,
          expanded: _alternatives,
          onPressed: _toggleAlternatives,
        ),
        AnimatedSize(
          duration: TranslateLayout.motion(context),
          curve: Curves.easeOutCubic,
          alignment: AlignmentDirectional.topStart,
          child: _alternatives
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: AlternativesList(state: state),
                )
              : const SizedBox(width: double.infinity),
        ),
        TranslateToolRow(
          key: const Key('translate_explain_button'),
          icon: Icons.school_outlined,
          label: l10n.translateExplain,
          opens: true,
          onPressed: () {
            if (state.explainStatus == ExtraStatus.idle ||
                state.explainStatus == ExtraStatus.failure) {
              unawaited(cubit.explain());
            }
            unawaited(showExplainSheet(context));
          },
        ),
      ],
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
