import 'package:flutter/gestures.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// Opens the details of one word insight; tapping a variation applies it.
Future<void> showInsightSheet(BuildContext context, WordInsight insight) {
  final cubit = context.read<TranslateCubit>();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetContext) => InsightSheet(
      insight: insight,
      onVariation: (variation) {
        Navigator.of(sheetContext).pop();
        cubit.applyVariation(insight, variation);
      },
    ),
  );
}

/// Type, phrase, explanation and variations of a [WordInsight].
class InsightSheet extends StatelessWidget {
  const InsightSheet({
    required this.insight,
    required this.onVariation,
    super.key,
  });

  final WordInsight insight;
  final ValueChanged<String> onVariation;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final type = insight.type.trim();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (type.isNotEmpty)
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Text(
                  type[0].toUpperCase() + type.substring(1),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onTertiaryContainer,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 12),
          SelectableText(
            insight.targetText,
            style: theme.textTheme.headlineSmall,
          ),
          if (insight.sourceText.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              insight.sourceText,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: scheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          if (insight.explanation.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(insight.explanation, style: theme.textTheme.bodyLarge),
          ],
          if (insight.variations.isNotEmpty) ...[
            const SizedBox(height: 20),
            Semantics(
              header: true,
              child: Text(
                l10n.translateInsightVariations,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.primary,
                ),
              ),
            ),
            const SizedBox(height: 4),
            for (final variation in insight.variations)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(variation.text),
                subtitle: variation.explanation.isEmpty
                    ? null
                    : Text(variation.explanation),
                trailing: const Icon(Icons.swap_horiz),
                onTap: () => onVariation(variation.text),
              ),
          ],
        ],
      ),
    );
  }
}

/// Output text with each insight's `targetText` underlined and tappable.
class InsightText extends StatefulWidget {
  const InsightText({
    required this.text,
    required this.insights,
    required this.onTap,
    this.style,
    super.key,
  });

  final String text;
  final List<WordInsight> insights;
  final ValueChanged<WordInsight> onTap;
  final TextStyle? style;

  @override
  State<InsightText> createState() => _InsightTextState();
}

class _InsightTextState extends State<InsightText> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  /// Non-overlapping (start, end, insight) ranges, in text order.
  static List<(int, int, WordInsight)> ranges(
    String text,
    List<WordInsight> insights,
  ) {
    final result = <(int, int, WordInsight)>[];
    for (final insight in insights) {
      final target = insight.targetText;
      if (target.trim().isEmpty) continue;
      var from = 0;
      while (true) {
        final start = text.indexOf(target, from);
        if (start < 0) break;
        final end = start + target.length;
        final overlaps = result.any((r) => start < r.$2 && end > r.$1);
        if (!overlaps) {
          result.add((start, end, insight));
          break;
        }
        from = start + 1;
      }
    }
    return result..sort((a, b) => a.$1.compareTo(b.$1));
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final scheme = Theme.of(context).colorScheme;
    final highlight = TextStyle(
      decoration: TextDecoration.underline,
      decorationColor: scheme.primary,
      decorationThickness: 2,
      backgroundColor: scheme.primaryContainer.withValues(alpha: 0.35),
    );
    final text = widget.text;
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final (start, end, insight) in ranges(text, widget.insights)) {
      if (start > cursor)
        spans.add(TextSpan(text: text.substring(cursor, start)));
      final recognizer = TapGestureRecognizer()
        ..onTap = () => widget.onTap(insight);
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: text.substring(start, end),
          style: highlight,
          recognizer: recognizer,
        ),
      );
      cursor = end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    return Text.rich(
      key: const Key('translate_insight_text'),
      TextSpan(children: spans),
      style: widget.style,
    );
  }
}
