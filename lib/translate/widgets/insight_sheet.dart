import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/language_text.dart';
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
      targetLanguage: cubit.state.target,
      sourceLanguage: cubit.state.source.isAuto
          ? _detectedLanguage(cubit.state.result?.detectedSource)
          : cubit.state.source,
      onVariation: (variation) {
        Navigator.of(sheetContext).pop();
        cubit.applyVariation(insight, variation);
      },
    ),
  );
}

Language? _detectedLanguage(String? code) =>
    code == null || code.isEmpty ? null : Language(code: code, name: code);

/// Type, phrase, explanation and variations of a [WordInsight].
class InsightSheet extends StatelessWidget {
  const new({
    required this.insight,
    required this.onVariation,
    this.targetLanguage,
    this.sourceLanguage,
    super.key,
  });

  final WordInsight insight;
  final ValueChanged<String> onVariation;

  /// Language of the phrase and its variations (direction and voice).
  final Language? targetLanguage;

  /// Language of the original phrase.
  final Language? sourceLanguage;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final type = insight.type.trim();
    final target = targetLanguage;
    final source = sourceLanguage;
    final targetLocale = target == null ? null : localeForLanguage(target);
    final targetDirection =
        (target == null ? null : textDirectionForLanguage(target)) ??
        textDirectionForText(insight.targetText);
    final sourceDirection =
        (source == null ? null : textDirectionForLanguage(source)) ??
        textDirectionForText(insight.sourceText);
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
          SizedBox(
            width: double.infinity,
            child: SelectableText.rich(
              TextSpan(text: insight.targetText, locale: targetLocale),
              textDirection: targetDirection,
              style: theme.textTheme.headlineSmall,
            ),
          ),
          if (insight.sourceText.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text.rich(
              TextSpan(
                text: insight.sourceText,
                locale: source == null ? null : localeForLanguage(source),
              ),
              textDirection: sourceDirection,
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
                title: Text.rich(
                  TextSpan(text: variation.text, locale: targetLocale),
                  textDirection:
                      targetDirection ?? textDirectionForText(variation.text),
                ),
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
  const new({
    required this.text,
    required this.insights,
    required this.onTap,
    this.style,
    this.textDirection,
    this.locale,
    super.key,
  });

  final String text;
  final List<WordInsight> insights;
  final ValueChanged<WordInsight> onTap;
  final TextStyle? style;

  /// Direction of [text] (the target language's).
  final TextDirection? textDirection;

  /// Language of [text], so screen readers use a matching voice.
  final Locale? locale;

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
    final l10n = context.l10n;
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
      if (start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, start)));
      }
      final recognizer = TapGestureRecognizer()
        ..onTap = () => widget.onTap(insight);
      _recognizers.add(recognizer);
      final phrase = text.substring(start, end);
      spans.add(
        TextSpan(
          text: phrase,
          style: highlight,
          recognizer: recognizer,
          semanticsLabel: l10n.translateInsightSemantics(phrase),
        ),
      );
      cursor = end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    return Text.rich(
      key: const Key('translate_insight_text'),
      TextSpan(children: spans, locale: widget.locale),
      style: widget.style,
      textDirection: widget.textDirection,
    );
  }
}

/// A focusable chip per insight under the output, so keyboard, switch and
/// screen-reader users can open insights without tapping text spans.
class InsightChips extends StatelessWidget {
  const new({
    required this.insights,
    this.locale,
    this.textDirection,
    super.key,
  });

  final List<WordInsight> insights;

  /// Language of the insight phrases (the target's).
  final Locale? locale;
  final TextDirection? textDirection;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final shown = [
      for (final insight in insights)
        if (insight.targetText.trim().isNotEmpty) insight,
    ];
    if (shown.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 8, end: 12),
      child: Semantics(
        key: const Key('translate_insight_chips'),
        container: true,
        explicitChildNodes: true,
        label: l10n.translateInsightsListLabel,
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final (index, insight) in shown.indexed)
              ActionChip(
                key: ValueKey('translate_insight_chip:$index'),
                avatar: const Icon(Icons.lightbulb_outline),
                label: Text.rich(
                  TextSpan(text: insight.targetText.trim(), locale: locale),
                  textDirection: textDirection,
                ),
                tooltip: l10n.translateInsightOpen(insight.targetText.trim()),
                onPressed: () => unawaited(showInsightSheet(context, insight)),
              ),
          ],
        ),
      ),
    );
  }
}
