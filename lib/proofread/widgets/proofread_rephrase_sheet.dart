import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/cubit/proofread_cubit.dart';
import 'package:mozhi/proofread/models/sentence_segmenter.dart';
import 'package:mozhi/proofread/widgets/proofread_labels.dart';
import 'package:translation_repository/translation_repository.dart';

/// Shows alternative phrasings of sentence [index] (of
/// [ProofreadState.sentences]) in a bottom sheet, like DeepL Write's: the
/// sentence as it is shown, then the alternatives (loading, an error with
/// a retry, or none with a retry); choosing one replaces the sentence in
/// the result, and a rephrased sentence can be restored.
///
/// The sheet belongs to the corrected text it was opened for: it closes
/// when a new result or another edit choice changes that text, and it
/// never changes a sentence of another one.
Future<void> showProofreadRephraseSheet(BuildContext context, int index) {
  final cubit = context.read<ProofreadCubit>();
  final state = cubit.state;
  final result = state.result;
  final sentences = state.sentences;
  if (result == null ||
      state.engine == null ||
      index < 0 ||
      index >= sentences.length) {
    return Future.value();
  }
  final sentence = sentences[index];
  final base = state.outputText;
  unawaited(cubit.loadAlternatives(sentence));
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => ProofreadRephraseSheet(
      cubit: cubit,
      result: result,
      base: base,
      sentence: sentence,
    ),
  ).whenComplete(() => cubit.closeAlternatives(sentence));
}

/// The content of [showProofreadRephraseSheet].
class ProofreadRephraseSheet extends StatelessWidget {
  const new({
    required this.cubit,
    required this.result,
    required this.base,
    required this.sentence,
    super.key,
  });

  final ProofreadCubit cubit;

  /// The result and corrected text the sheet was opened for.
  final ProofreadResult result;
  final String base;
  final SentenceRange sentence;

  bool _isCurrent(ProofreadState state) =>
      identical(state.result, result) && state.outputText == base;

  void _close(BuildContext context) {
    final route = ModalRoute.of(context);
    if (route?.isCurrent ?? false) Navigator.of(context).pop();
  }

  void _announce(BuildContext context, String message) => unawaited(
    SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      Directionality.of(context),
    ),
  );

  void _choose(BuildContext context, String replacement) {
    if (_isCurrent(cubit.state)) {
      cubit.rephraseSentence(sentence, replacement);
      _announce(context, context.l10n.proofreadRephraseReplaced);
    }
    _close(context);
  }

  void _restore(BuildContext context) {
    if (_isCurrent(cubit.state)) {
      cubit.restoreSentence(sentence);
      _announce(context, context.l10n.proofreadRephraseRestored);
    }
    _close(context);
  }

  void _retry() {
    if (_isCurrent(cubit.state)) unawaited(cubit.loadAlternatives(sentence));
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<ProofreadCubit, ProofreadState>(
      bloc: cubit,
      listenWhen: (previous, current) => !_isCurrent(current),
      listener: (context, _) => _close(context),
      buildWhen: (previous, current) =>
          _isCurrent(current) &&
          (previous.alternatives != current.alternatives ||
              previous.rephrasings != current.rephrasings),
      builder: (context, state) {
        final l10n = context.l10n;
        final theme = Theme.of(context);
        final palette = AppPalette.of(context);
        final rephrasing = state.rephrasingOf(sentence);
        final shown = rephrasing?.replacement ?? sentence.of(base);
        final lookup = state.alternatives;
        final alternatives =
            lookup != null && lookup.sentence == sentence && lookup.base == base
            ? lookup
            : null;
        return SingleChildScrollView(
          key: const Key('proofread_rephrase_sheet'),
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              Semantics(
                header: true,
                child: Text(
                  l10n.proofreadRephraseTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              // The sentence as it is shown now: a hairline box, no fill.
              DecoratedBox(
                key: const Key('proofread_rephrase_current'),
                decoration: BoxDecoration(
                  border: Border.all(color: palette.hairline),
                  borderRadius: AppLook.of(context).cardRadius,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(shown, style: theme.textTheme.bodyLarge),
                ),
              ),
              if (rephrasing != null)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const Key('proofread_rephrase_restore'),
                    onPressed: () => _restore(context),
                    icon: const Icon(Icons.undo),
                    label: Text(l10n.proofreadRephraseRestore),
                  ),
                ),
              Semantics(
                header: true,
                child: Text(
                  l10n.proofreadRephraseAlternatives,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: palette.secondaryText,
                  ),
                ),
              ),
              ..._buildAlternatives(context, alternatives),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _buildAlternatives(
    BuildContext context,
    ProofreadAlternatives? lookup,
  ) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final retry = TextButton(
      key: const Key('proofread_rephrase_retry'),
      onPressed: _retry,
      child: Text(l10n.commonRetry),
    );
    if (lookup == null || lookup.isLoading) {
      return [
        Semantics(
          key: const Key('proofread_rephrase_loading'),
          liveRegion: true,
          child: Row(
            spacing: 12,
            children: [
              const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              Expanded(
                child: Text(
                  l10n.proofreadRephraseLoading,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: palette.secondaryText,
                  ),
                ),
              ),
            ],
          ),
        ),
      ];
    }
    if (lookup.status == ProofreadAlternativesStatus.failure) {
      final error = lookup.error;
      if (error is ConsentRequiredException) {
        return [
          ConsentInlinePrompt(
            key: const Key('proofread_rephrase_consent'),
            consent: error,
            onGranted: _retry,
          ),
        ];
      }
      return [
        Semantics(
          key: const Key('proofread_rephrase_error'),
          container: true,
          liveRegion: true,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              Icon(Icons.error_outline, color: theme.colorScheme.error),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    Text(
                      l10n.proofreadRephraseErrorTitle,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      l10n.proofreadError(error),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: palette.secondaryText,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Align(alignment: AlignmentDirectional.centerEnd, child: retry),
      ];
    }
    if (lookup.alternatives.isEmpty) {
      return [
        Semantics(
          key: const Key('proofread_rephrase_empty'),
          liveRegion: true,
          child: Text(
            l10n.proofreadRephraseEmpty,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.secondaryText,
            ),
          ),
        ),
        Align(alignment: AlignmentDirectional.centerEnd, child: retry),
      ];
    }
    return [
      for (final (i, alternative) in lookup.alternatives.indexed)
        _AlternativeTile(
          key: ValueKey('proofread_rephrase_alternative_$i'),
          text: alternative,
          onTap: () => _choose(context, alternative),
        ),
    ];
  }
}

/// One alternative: a hairline-bordered tile (at least 48 high) that
/// replaces the sentence when tapped.
class _AlternativeTile extends StatelessWidget {
  const new({required this.text, required this.onTap, super.key});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: AppLook.of(context).cardRadius,
      side: BorderSide(color: theme.colorScheme.outline),
    );
    return Semantics(
      button: true,
      hint: context.l10n.proofreadRephraseUseHint,
      excludeSemantics: true,
      label: text,
      child: Material(
        type: MaterialType.transparency,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          customBorder: shape,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 12, 12),
              child: Row(
                spacing: 12,
                children: [
                  Expanded(child: Text(text, style: theme.textTheme.bodyLarge)),
                  Icon(
                    Icons.swap_horiz,
                    size: 20,
                    color: palette.secondaryText,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
