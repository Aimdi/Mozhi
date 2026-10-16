import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/cubit/proofread_cubit.dart';
import 'package:mozhi/proofread/models/proofread_diff.dart';
import 'package:mozhi/proofread/widgets/proofread_diff_colors.dart';
import 'package:mozhi/proofread/widgets/proofread_diff_text.dart';
import 'package:mozhi/proofread/widgets/proofread_edit_tile.dart';
import 'package:mozhi/proofread/widgets/proofread_labels.dart';
import 'package:mozhi/proofread/widgets/proofread_stats_panel.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart'
    show StatusBadge;
import 'package:share_plus/share_plus.dart';
import 'package:translation_repository/translation_repository.dart';

/// Result area: loading/error states, the corrected text with an inline
/// diff, the summary, the writing statistics and the list of edits.
class ProofreadResultSection extends StatelessWidget {
  const new({this.showPlaceholder = false, super.key});

  /// Show a hint card before the first result (wide layouts).
  final bool showPlaceholder;

  /// Announces the outcome of a request to assistive technology, since the
  /// result may appear off screen (WCAG 4.1.3).
  void _announce(BuildContext context, ProofreadState state) {
    final l10n = context.l10n;
    final String message;
    if (state.status == ProofreadStatus.failure) {
      message = l10n.proofreadAnnounceFailed(l10n.proofreadError(state.error));
    } else if (state.isClean) {
      message = l10n.proofreadNoIssuesBody;
    } else {
      message = l10n.proofreadAnnounceDone(state.edits.length);
    }
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        message,
        Directionality.of(context),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<ProofreadCubit, ProofreadState>(
      listenWhen: (previous, current) =>
          previous.isLoading &&
          (current.status == ProofreadStatus.success ||
              current.status == ProofreadStatus.failure),
      listener: _announce,
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    return BlocBuilder<ProofreadCubit, ProofreadState>(
      buildWhen: (previous, current) =>
          previous.status != current.status ||
          previous.result != current.result ||
          previous.acceptedEdits != current.acceptedEdits ||
          previous.proofreadInput != current.proofreadInput ||
          previous.error != current.error ||
          previous.engine != current.engine ||
          previous.input != current.input ||
          // The statistics fall back to the variety's language.
          previous.variety != current.variety,
      builder: (context, state) {
        final result = state.result;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 16,
          children: [
            if (state.status == ProofreadStatus.failure)
              _ErrorCard(error: state.error, canRetry: state.canProofread),
            if (result == null && state.isLoading) const _LoadingCard(),
            if (result == null &&
                state.status == ProofreadStatus.idle &&
                showPlaceholder)
              const _PlaceholderCard(),
            if (result != null) ...[
              if (state.isLoading) const LinearProgressIndicator(),
              if (state.isStale && !state.isLoading)
                _StaleNotice(canProofread: state.canProofread),
              if (state.isClean)
                _NoIssuesCard(summary: result.summary)
              else
                ProofreadResultCard(state: state),
              ProofreadStatsPanel(
                original: state.proofreadInput,
                corrected: state.outputText,
                languageCode: state.textLanguage,
              ),
              if (!state.isClean && result.edits.isNotEmpty)
                ProofreadEditsList(state: state),
            ],
          ],
        );
      },
    );
  }
}

/// The corrected text (with or without highlighted changes), summary and
/// copy/share/"use as input" actions.
class ProofreadResultCard extends StatefulWidget {
  const new({required this.state, super.key});

  final ProofreadState state;

  @override
  State<ProofreadResultCard> createState() => _ProofreadResultCardState();
}

class _ProofreadResultCardState extends State<ProofreadResultCard> {
  bool _showChanges = true;

  ProofreadResult? _cachedResult;
  String? _cachedInput;
  Set<int>? _cachedAccepted;
  List<DiffSegment> _segments = const [];

  /// Edit-based segments when they reproduce the output exactly, else a
  /// word-level diff of input vs output (e.g. when `correctedText` contains
  /// changes not listed as edits).
  List<DiffSegment> _segmentsFor(ProofreadState state) {
    if (identical(state.result, _cachedResult) &&
        state.proofreadInput == _cachedInput &&
        identical(state.acceptedEdits, _cachedAccepted)) {
      return _segments;
    }
    _cachedResult = state.result;
    _cachedInput = state.proofreadInput;
    _cachedAccepted = state.acceptedEdits;
    final input = state.proofreadInput;
    final applied = ProofreadDiff.apply(
      input,
      state.edits,
      state.acceptedEdits,
    );
    final output = state.outputText;
    return _segments = applied == output
        ? ProofreadDiff.editSegments(input, state.edits, state.acceptedEdits)
        : ProofreadDiff.wordDiff(input, output);
  }

  Future<void> _copy(String text) async {
    final messenger = ScaffoldMessenger.of(context);
    final message = context.l10n.commonCopied;
    await Clipboard.setData(ClipboardData(text: text));
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _share(BuildContext buttonContext, String text) async {
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box != null && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    try {
      await SharePlus.instance.share(
        ShareParams(text: text, sharePositionOrigin: origin),
      );
    } on Object {
      // Sharing is best effort; nothing useful to report.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = widget.state;
    final output = state.outputText;
    final summary = state.result?.summary.trim() ?? '';
    // Taller lines keep the highlighted changes from touching.
    final textStyle = theme.textTheme.bodyLarge?.copyWith(height: 1.45);
    final colors = theme.colorScheme;

    return Card.filled(
      margin: EdgeInsets.zero,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              spacing: 8,
              children: [
                Icon(Icons.fact_check_outlined, color: colors.primary),
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        l10n.proofreadResultTitle,
                        style: theme.textTheme.titleMedium,
                      ),
                      // Screen readers hear the count with the edits list
                      // ("2 of 2 applied") and in the announcement.
                      if (state.edits.isNotEmpty)
                        ExcludeSemantics(
                          child: StatusBadge(
                            key: const Key('proofread_suggestion_count'),
                            label: l10n.proofreadSuggestionCount(
                              state.edits.length,
                            ),
                            color: colors.primary,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: _showChanges
                      ? l10n.proofreadHideChanges
                      : l10n.proofreadShowChanges,
                  isSelected: _showChanges,
                  onPressed: () => setState(() => _showChanges = !_showChanges),
                  icon: const Icon(Icons.difference_outlined),
                  selectedIcon: const Icon(Icons.difference),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8, bottom: 12),
              child: _showChanges
                  ? ProofreadDiffText(
                      key: const Key('proofread_diff'),
                      segments: _segmentsFor(state),
                      style: textStyle,
                      onEditTap: (index) =>
                          showProofreadEditSheet(context, index),
                    )
                  : SelectableText(
                      output,
                      key: const Key('proofread_output'),
                      style: textStyle,
                    ),
            ),
            if (summary.isNotEmpty)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8, bottom: 4),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.secondaryContainer.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 8,
                      children: [
                        Icon(
                          Icons.auto_awesome_outlined,
                          size: 18,
                          color: colors.onSecondaryContainer,
                        ),
                        Expanded(
                          child: Text(
                            summary,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.onSecondaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // "Use as input" moves below the icons when it does not fit
            // beside them (narrow screens, large text).
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: l10n.commonCopy,
                      onPressed: output.isEmpty ? null : () => _copy(output),
                      icon: const Icon(Icons.copy_outlined),
                    ),
                    Builder(
                      builder: (buttonContext) => IconButton(
                        tooltip: l10n.commonShare,
                        onPressed: output.isEmpty
                            ? null
                            : () => unawaited(_share(buttonContext, output)),
                        icon: const Icon(Icons.share_outlined),
                      ),
                    ),
                  ],
                ),
                TextButton.icon(
                  // Replacing newer input with an older result would silently
                  // discard what the user typed since.
                  onPressed: output.isEmpty || state.isStale
                      ? null
                      : context.read<ProofreadCubit>().useOutputAsInput,
                  icon: const Icon(Icons.input),
                  label: Text(l10n.proofreadUseAsInput),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows the details of edit [index] with an apply/revert action.
///
/// The sheet belongs to the result it was opened for: it closes when a new
/// result replaces it, and its action never toggles an edit of another one.
Future<void> showProofreadEditSheet(BuildContext context, int index) {
  final cubit = context.read<ProofreadCubit>();
  final result = cubit.state.result;
  final edits = cubit.state.edits;
  if (result == null || index < 0 || index >= edits.length) {
    return Future.value();
  }
  final edit = edits[index];
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      final l10n = sheetContext.l10n;
      final theme = Theme.of(sheetContext);
      final navigator = Navigator.of(sheetContext);
      final route = ModalRoute.of(sheetContext);
      void close() {
        if (route?.isCurrent ?? false) navigator.pop();
      }

      return BlocConsumer<ProofreadCubit, ProofreadState>(
        bloc: cubit,
        listenWhen: (previous, current) => !identical(current.result, result),
        listener: (_, _) => close(),
        buildWhen: (previous, current) =>
            identical(current.result, result) &&
            previous.acceptedEdits != current.acceptedEdits,
        builder: (context, state) {
          final accepted = state.acceptedEdits.contains(index);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 12,
                children: [
                  ProofreadCategoryChip(category: edit.category),
                  ProofreadEditChange(
                    edit: edit,
                    style: theme.textTheme.titleMedium,
                  ),
                  if (edit.explanation.trim().isNotEmpty)
                    Text(
                      edit.explanation.trim(),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: FilledButton.tonalIcon(
                      onPressed: () {
                        if (identical(cubit.state.result, result)) {
                          cubit.toggleEdit(index);
                        }
                        close();
                      },
                      icon: Icon(accepted ? Icons.undo : Icons.check),
                      label: Text(
                        accepted
                            ? l10n.proofreadEditRevert
                            : l10n.proofreadEditApply,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

/// Header with accept/reject all, followed by one tile per edit.
class ProofreadEditsList extends StatelessWidget {
  const new({required this.state, super.key});

  final ProofreadState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<ProofreadCubit>();
    final edits = state.edits;
    final locations = ProofreadDiff.locate(state.proofreadInput, edits);
    final accepted = state.acceptedCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        // The buttons move below the title when they do not fit beside it
        // (narrow screens, large text).
        Wrap(
          key: const Key('proofread_edits_header'),
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.proofreadEditsTitle,
                  style: theme.textTheme.titleMedium,
                ),
                Text(
                  l10n.proofreadEditsApplied(accepted, edits.length),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: accepted == edits.length ? null : cubit.acceptAll,
                  child: Text(l10n.proofreadAcceptAll),
                ),
                TextButton(
                  onPressed: accepted == 0 ? null : cubit.rejectAll,
                  child: Text(l10n.proofreadRejectAll),
                ),
              ],
            ),
          ],
        ),
        for (var i = 0; i < edits.length; i++)
          ProofreadEditTile(
            key: ValueKey('proofread_edit_$i'),
            edit: edits[i],
            accepted: state.acceptedEdits.contains(i),
            located: locations[i] != null,
            onToggle: () => cubit.toggleEdit(i),
          ),
      ],
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const new({required this.error, required this.canRetry});

  final Object? error;
  final bool canRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 12,
              children: [
                Icon(Icons.error_outline, color: scheme.onErrorContainer),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 4,
                    children: [
                      Text(
                        l10n.proofreadErrorTitle,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: scheme.onErrorContainer,
                        ),
                      ),
                      Text(
                        l10n.proofreadError(error),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onErrorContainer,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onErrorContainer,
                ),
                onPressed: canRetry
                    ? context.read<ProofreadCubit>().proofread
                    : null,
                child: Text(l10n.commonRetry),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when the input changed after the result was computed.
class _StaleNotice extends StatelessWidget {
  const new({required this.canProofread});

  final bool canProofread;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card.outlined(
      key: const Key('proofread_stale'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 8),
        child: Row(
          spacing: 12,
          children: [
            Icon(Icons.edit_note, color: scheme.onSurfaceVariant),
            Expanded(
              child: Text(
                l10n.proofreadStaleNotice,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            TextButton(
              onPressed: canProofread
                  ? context.read<ProofreadCubit>().proofread
                  : null,
              child: Text(l10n.proofreadStaleAction),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          spacing: 16,
          children: [
            const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            Expanded(
              child: Text(
                context.l10n.proofreadLoading,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaceholderCard extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          spacing: 12,
          children: [
            Icon(
              Icons.spellcheck,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            Text(
              context.l10n.proofreadPlaceholder,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoIssuesCard extends StatelessWidget {
  const new({required this.summary});

  final String summary;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = ProofreadDiffColors.of(context);
    final foreground = colors.insertedForeground;
    return Card(
      margin: EdgeInsets.zero,
      color: colors.insertedBackground,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Icon(Icons.check_circle_outline, color: foreground),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Text(
                    l10n.proofreadNoIssuesTitle,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: foreground,
                    ),
                  ),
                  Text(
                    summary.trim().isEmpty
                        ? l10n.proofreadNoIssuesBody
                        : summary.trim(),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: foreground,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
