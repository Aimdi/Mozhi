import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/clipboard_service.dart';
import 'package:mozhi/proofread/cubit/proofread_cubit.dart';
import 'package:mozhi/proofread/models/proofread_diff.dart';
import 'package:mozhi/proofread/models/proofread_rephrasing.dart';
import 'package:mozhi/proofread/models/sentence_segmenter.dart';
import 'package:mozhi/proofread/widgets/proofread_edit_tile.dart';
import 'package:mozhi/proofread/widgets/proofread_labels.dart';
import 'package:mozhi/proofread/widgets/proofread_output_text.dart';
import 'package:mozhi/proofread/widgets/proofread_rephrase_sheet.dart';
import 'package:mozhi/proofread/widgets/proofread_stats_panel.dart';
import 'package:mozhi/translate/widgets/on_device_ai_loading.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
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
      // Proofreading is always the user's own action: ask right away.
      child: ConsentDialogListener<ProofreadCubit, ProofreadState>(
        consentOf: (state) => state.status == ProofreadStatus.failure
            ? switch (state.error) {
                final ConsentRequiredException consent => consent,
                _ => null,
              }
            : null,
        onGranted: (context) =>
            unawaited(context.read<ProofreadCubit>().proofread()),
        child: _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    return BlocBuilder<ProofreadCubit, ProofreadState>(
      buildWhen: (previous, current) =>
          previous.status != current.status ||
          previous.result != current.result ||
          previous.acceptedEdits != current.acceptedEdits ||
          previous.rephrasings != current.rephrasings ||
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
            if (result == null && state.isLoading)
              OnDeviceAiExtraLoading(
                engine: state.engine,
                child: const _LoadingCard(),
              ),
            if (result == null &&
                state.status == ProofreadStatus.idle &&
                showPlaceholder)
              const _PlaceholderCard(),
            if (result != null) ...[
              if (state.isLoading)
                OnDeviceAiExtraLoading(
                  engine: state.engine,
                  child: const LinearProgressIndicator(),
                ),
              if (state.isStale && !state.isLoading)
                _StaleNotice(canProofread: state.canProofread),
              // A clean text can still be rephrased, sentence by sentence.
              if (state.isClean) ...[
                _NoIssuesCard(summary: result.summary),
                ProofreadResultCard(
                  key: const Key('proofread_clean_text'),
                  state: state,
                  clean: true,
                ),
              ] else
                ProofreadResultCard(state: state),
              // Flat sections divided by hairlines, X style.
              const Hairline(),
              ProofreadStatsPanel(
                original: state.proofreadInput,
                corrected: state.finalText,
                languageCode: state.textLanguage,
              ),
              if (!state.isClean && result.edits.isNotEmpty) ...[
                const Hairline(),
                ProofreadEditsList(state: state),
              ],
            ],
          ],
        );
      },
    );
  }
}

/// The corrected text (with or without highlighted changes, toggled with
/// the eye button) at the input's text size, the summary, and the actions:
/// "Copy corrected text" first, then share and "Use as input".
///
/// For a [clean] result (nothing to fix, see [ProofreadState.isClean]) it
/// is the user's own text ("Your text", "Copy text") without the summary,
/// which the "no issues" notice above it shows.
///
/// Every sentence can be tapped (or, with the changes shown, long-pressed)
/// for alternative phrasings ([showProofreadRephraseSheet]); the chosen
/// ones are shown in place of their sentences and are part of what is
/// copied, shared and used as input ([ProofreadState.finalText]).
class ProofreadResultCard extends StatefulWidget {
  const new({required this.state, this.clean = false, super.key});

  final ProofreadState state;

  /// Whether the result found nothing to fix.
  final bool clean;

  @override
  State<ProofreadResultCard> createState() => _ProofreadResultCardState();
}

class _ProofreadResultCardState extends State<ProofreadResultCard> {
  bool _showChanges = true;

  ProofreadResult? _cachedResult;
  String? _cachedInput;
  Set<int>? _cachedAccepted;
  List<DiffSegment> _segments = const [];

  String? _cachedBase;
  List<SentenceRange> _sentences = const [];

  /// The sentences of the corrected text (segmented once per text).
  List<SentenceRange> _sentencesFor(ProofreadState state) {
    final base = state.outputText;
    if (base == _cachedBase) return _sentences;
    _cachedBase = base;
    return _sentences = SentenceSegmenter.split(base);
  }

  /// The text as shown: the diff ([_segmentsFor]) or the plain corrected
  /// text, split into sentences, with the rephrasings in place.
  List<OutputSegment> _outputSegmentsFor(ProofreadState state) {
    final base = state.outputText;
    return ProofreadRephrasings.overlay(
      _showChanges ? _segmentsFor(state) : [DiffSegment.unchanged(base)],
      base,
      _sentencesFor(state),
      state.rephrasings,
    );
  }

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
    await copyText(text);
    // Android 13+ confirms copies itself.
    if (systemShowsCopyConfirmation) return;
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
    final output = state.finalText;
    final clean = widget.clean;
    // A clean result's summary is in the "no issues" notice.
    final summary = clean ? '' : state.result?.summary.trim() ?? '';
    // The input's size; taller lines keep the highlighted changes from
    // touching.
    final textStyle = TranslateLayout.textStyle(
      context,
      state.proofreadInput.length,
    )?.copyWith(height: 1.45);
    final colors = theme.colorScheme;

    final palette = AppPalette.of(context);

    // A flat section (no card); as a semantics container it reads as one
    // group named by its heading.
    return Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            spacing: 8,
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      clean
                          ? l10n.proofreadCleanTextTitle
                          : l10n.proofreadResultTitle,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                      ),
                    ),
                    // Screen readers hear the count with the edits list
                    // ("2 of 2 applied") and in the announcement.
                    if (state.edits.isNotEmpty)
                      ExcludeSemantics(
                        child: ProofreadPill(
                          key: const Key('proofread_suggestion_count'),
                          label: l10n.proofreadSuggestionCount(
                            state.edits.length,
                          ),
                          filled: true,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                key: const Key('proofread_show_changes'),
                tooltip: _showChanges
                    ? l10n.proofreadHideChanges
                    : l10n.proofreadShowChanges,
                isSelected: _showChanges,
                color: colors.primary,
                onPressed: () => setState(() => _showChanges = !_showChanges),
                icon: const Icon(Icons.visibility_off_outlined),
                selectedIcon: const Icon(Icons.visibility_outlined),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 12),
            child: ProofreadOutputText(
              key: Key(_showChanges ? 'proofread_diff' : 'proofread_output'),
              segments: _outputSegmentsFor(state),
              showChanges: _showChanges,
              style: textStyle,
              onEditTap: (index) => showProofreadEditSheet(context, index),
              onSentenceTap: state.engine == null
                  ? null
                  : (index) => showProofreadRephraseSheet(context, index),
            ),
          ),
          if (state.engine != null && output.trim().isNotEmpty)
            Padding(
              key: const Key('proofread_rephrase_hint'),
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                spacing: 8,
                children: [
                  Icon(
                    Icons.touch_app_outlined,
                    size: 16,
                    color: palette.secondaryText,
                  ),
                  Expanded(
                    child: Text(
                      l10n.proofreadRephraseHint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: palette.secondaryText,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (summary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              // Quoted like a linked post: a hairline box, no fill.
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: palette.hairline),
                  borderRadius: AppLook.of(context).cardRadius,
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
                        color: colors.primary,
                      ),
                      Expanded(
                        child: Text(
                          summary,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: palette.secondaryText,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // Personal data the shield kept on this device, like a
          // translation's note.
          if ((state.result?.maskedPersonalData ?? 0) > 0)
            Padding(
              key: const Key('proofread_personal_data_kept'),
              padding: const EdgeInsets.only(bottom: 8),
              child: Semantics(
                container: true,
                hint: l10n.translatePersonalDataKeptHint,
                child: Row(
                  spacing: 8,
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      size: 18,
                      color: palette.secondaryText,
                    ),
                    Expanded(
                      child: Text(
                        l10n.translatePersonalDataKept(
                          state.result!.maskedPersonalData,
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: palette.secondaryText,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // The actions wrap below each other when they do not fit
          // (narrow screens, large text).
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                key: const Key('proofread_copy_corrected'),
                onPressed: output.isEmpty ? null : () => _copy(output),
                icon: const Icon(Icons.copy_rounded),
                label: Text(
                  clean ? l10n.proofreadCopyText : l10n.proofreadCopyCorrected,
                ),
              ),
              Builder(
                builder: (buttonContext) => XActionButton(
                  icon: Icons.ios_share_rounded,
                  tooltip: l10n.commonShare,
                  onPressed: output.isEmpty
                      ? null
                      : () => unawaited(_share(buttonContext, output)),
                ),
              ),
              OutlinedButton.icon(
                // Replacing newer input with an older result would silently
                // discard what the user typed since.
                onPressed: output.isEmpty || state.isStale
                    ? null
                    : context.read<ProofreadCubit>().useOutputAsInput,
                style: OutlinedButton.styleFrom(
                  shape: AppLook.of(context).control,
                ),
                icon: const Icon(Icons.input),
                label: Text(l10n.proofreadUseAsInput),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A small pill label: outlined, or [filled] in the primary container.
class ProofreadPill extends StatelessWidget {
  const new({required this.label, this.icon, this.filled = false, super.key});

  final String label;
  final IconData? icon;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final foreground = filled
        ? colors.onPrimaryContainer
        : AppPalette.of(context).secondaryText;
    final icon = this.icon;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: filled ? colors.primaryContainer : null,
        shape: AppLook.of(context).control.copyWith(
          side: filled ? BorderSide.none : BorderSide(color: colors.outline),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            if (icon != null) Icon(icon, size: 14, color: foreground),
            Flexible(
              child: Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w700,
                ),
              ),
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

/// The suggested edits: a header with how many apply and, once one was
/// rejected, "Reset" (every suggestion again), then one tile per edit with
/// its own accept and reject buttons.
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
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  l10n.proofreadEditsApplied(accepted, edits.length),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: AppPalette.of(context).secondaryText,
                  ),
                ),
              ],
            ),
            if (accepted < edits.length)
              Tooltip(
                message: l10n.proofreadEditsResetTooltip,
                excludeFromSemantics: true,
                child: TextButton(
                  key: const Key('proofread_edits_reset'),
                  onPressed: cubit.acceptAll,
                  child: Text(l10n.proofreadEditsReset),
                ),
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
            divider: i < edits.length - 1,
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
    final scheme = Theme.of(context).colorScheme;
    final consent = error;
    if (consent is ConsentRequiredException) {
      return ConsentInlinePrompt(
        key: const Key('proofread_consent'),
        consent: consent,
        onGranted: () => unawaited(context.read<ProofreadCubit>().proofread()),
      );
    }
    return _FlatNotice(
      icon: Icons.error_outline,
      iconColor: scheme.error,
      title: l10n.proofreadErrorTitle,
      body: l10n.proofreadError(error),
      action: TextButton(
        onPressed: canRetry ? context.read<ProofreadCubit>().proofread : null,
        child: Text(l10n.commonRetry),
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
    return _FlatNotice(
      key: const Key('proofread_stale'),
      icon: Icons.edit_note,
      body: l10n.proofreadStaleNotice,
      action: TextButton(
        onPressed: canProofread
            ? context.read<ProofreadCubit>().proofread
            : null,
        child: Text(l10n.proofreadStaleAction),
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    return _FlatNotice(
      leading: const SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      body: context.l10n.proofreadLoading,
    );
  }
}

class _PlaceholderCard extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Icon(Icons.spellcheck, size: 32, color: palette.secondaryText),
          Text(
            context.l10n.proofreadPlaceholder,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: palette.secondaryText,
            ),
          ),
        ],
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
    return _FlatNotice(
      icon: Icons.check_circle_outline,
      iconColor: AppPalette.of(context).success,
      title: l10n.proofreadNoIssuesTitle,
      body: summary.trim().isEmpty
          ? l10n.proofreadNoIssuesBody
          : summary.trim(),
    );
  }
}

/// A flat notice: a hairline-bordered box (radius 16, no fill) with an
/// icon, an optional bold title, a body and an optional trailing action.
class _FlatNotice extends StatelessWidget {
  const new({
    required this.body,
    this.icon,
    this.iconColor,
    this.leading,
    this.title,
    this.action,
    super.key,
  });

  final IconData? icon;
  final Color? iconColor;
  final Widget? leading;
  final String? title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final title = this.title;
    final icon = this.icon;
    final action = this.action;
    return Semantics(
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: palette.hairline),
          borderRadius: AppLook.of(context).cardRadius,
        ),
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            16,
            12,
            action == null ? 16 : 8,
            12,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              if (leading != null)
                leading!
              else if (icon != null)
                Icon(icon, color: iconColor ?? palette.secondaryText),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    if (title != null)
                      Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    Text(
                      body,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: title == null
                            ? palette.secondaryText
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
              ?action,
            ],
          ),
        ),
      ),
    );
  }
}
