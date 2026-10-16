import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/history/data/translation_memory.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart'
    show StatusBadge;
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:mozhi/translate/widgets/output_card.dart' show copyToClipboard;
import 'package:mozhi/translate/widgets/translate_layout.dart';

/// "From your history" / "Similar text in your history": the earlier
/// translation of the input that the translation memory found
/// ([TranslateState.visibleMemoryMatch]), shown while the engine
/// translates (offline and free).
///
/// "Use" shows it as the output (`TranslateCubit.useMemoryMatch`), the copy
/// button copies it, the close button hides it. For similar text the
/// earlier source text is shown with the differences marked (struck
/// through: only in the earlier text; underlined: new in the input).
/// Nothing is shown without a match.
class TranslationMemoryCard extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TranslateCubit, TranslateState>(
      buildWhen: (previous, current) =>
          previous.visibleMemoryMatch != current.visibleMemoryMatch ||
          previous.target != current.target,
      builder: (context, state) {
        final match = state.visibleMemoryMatch;
        if (match == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: TranslateLayout.gap),
          child: _MemoryCard(
            key: const Key('translate_memory_card'),
            match: match,
            state: state,
          ),
        );
      },
    );
  }
}

class _MemoryCard extends StatelessWidget {
  const new({required this.match, required this.state, super.key});

  final MemoryMatch match;
  final TranslateState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final cubit = context.read<TranslateCubit>();
    final entry = match.entry;
    final title = match.isExact
        ? l10n.translateMemoryExactTitle
        : l10n.translateMemorySimilarTitle;
    final muted = colors.onSurfaceVariant;
    final similarity = l10n.translateMemorySimilarity(match.percent);
    final date = MaterialLocalizations.of(context)
        .formatMediumDate(entry.createdAt);
    // An earlier translation, quoted like a post inside a post.
    return TranslateFlatCard(
      look: TranslateCardLook.quote,
      semanticContainer: false,
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: title,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 4, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  ExcludeSemantics(
                    child: Icon(Icons.history, size: 20, color: muted),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: title),
                          if (!match.isExact)
                            TextSpan(
                              text: ' · $similarity',
                              style: TextStyle(color: muted),
                            ),
                        ],
                      ),
                      key: const Key('translate_memory_title'),
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('translate_memory_dismiss'),
                    tooltip: l10n.translateMemoryDismiss,
                    icon: const Icon(Icons.close),
                    onPressed: cubit.dismissMemoryMatch,
                  ),
                ],
              ),
              if (!match.isExact) ...[
                _SourceDiff(match: match),
                const SizedBox(height: 8),
              ],
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 12),
                child: Text.rich(
                  TextSpan(
                    text: entry.translation,
                    locale: localeForLanguage(state.target),
                  ),
                  key: const Key('translate_memory_translation'),
                  style: theme.textTheme.bodyLarge,
                  textDirection:
                      textDirectionForLanguage(state.target) ??
                      textDirectionForText(entry.translation),
                ),
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 12),
                child: Text(
                  l10n.translateMemoryMeta(entry.engineName, date),
                  key: const Key('translate_memory_meta'),
                  style: theme.textTheme.labelMedium?.copyWith(color: muted),
                ),
              ),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 4,
                children: [
                  Tooltip(
                    message: l10n.translateMemoryUseLabel,
                    excludeFromSemantics: true,
                    child: TextButton.icon(
                      key: const Key('translate_memory_use'),
                      icon: const Icon(Icons.south),
                      label: Text(
                        l10n.translateMemoryUse,
                        semanticsLabel: l10n.translateMemoryUseLabel,
                      ),
                      onPressed: cubit.useMemoryMatch,
                    ),
                  ),
                  IconButton(
                    key: const Key('translate_memory_copy'),
                    tooltip: l10n.translateMemoryCopy,
                    icon: const Icon(Icons.copy_outlined),
                    onPressed: () =>
                        unawaited(copyToClipboard(context, entry.translation)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The earlier source text with the differences from the input marked.
class _SourceDiff extends StatelessWidget {
  const new({required this.match});

  final MemoryMatch match;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final muted = colors.onSurfaceVariant;
    final base = theme.textTheme.bodyMedium?.copyWith(color: muted);
    final text = match.entry.text.trim();
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 12, top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            label: l10n.translateMemoryEarlierText(text),
            excludeSemantics: true,
            child: Text.rich(
              TextSpan(
                children: [
                  for (final segment in match.diff)
                    TextSpan(
                      text: segment.text,
                      style: switch (segment.op) {
                        MemoryDiffOp.equal => null,
                        MemoryDiffOp.removed => TextStyle(
                          color: colors.error,
                          decoration: TextDecoration.lineThrough,
                          decorationColor: colors.error,
                        ),
                        MemoryDiffOp.added => TextStyle(
                          color: colors.primary,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                          decorationColor: colors.primary,
                        ),
                      },
                    ),
                ],
              ),
              key: const Key('translate_memory_diff'),
              style: base,
              textDirection: textDirectionForText(text),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            l10n.translateMemoryDiffHint,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ],
      ),
    );
  }
}

/// Marks an output taken from the history
/// ([TranslateState.resultFromMemory]) in the output card's footer.
class MemoryResultBadge extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Tooltip(
      message: l10n.translateMemoryBadgeTooltip,
      child: StatusBadge(
        key: const Key('translate_memory_badge'),
        label: l10n.translateMemoryBadge,
        color: Theme.of(context).colorScheme.secondary,
        icon: Icons.history,
      ),
    );
  }
}
