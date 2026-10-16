import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// Opens the details of one word insight; tapping a variation applies it.
///
/// The variation replaces the occurrence of the insight's phrase that starts
/// at [offset] in the output (the tapped highlight) when given, otherwise
/// the one [TranslateCubit.locateInsight] finds.
Future<void> showInsightSheet(
  BuildContext context,
  WordInsight insight, {
  int? offset,
}) {
  final cubit = context.read<TranslateCubit>();
  final state = cubit.state;
  final start =
      offset ??
      TranslateCubit.locateInsight(
        state.output,
        insight,
        source: state.resultInput ?? state.input,
      );
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
        cubit.applyVariation(insight, variation, offset: start);
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
    final palette = AppPalette.of(context);
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
            // An outlined hairline pill, like an X topic.
            DecoratedBox(
              decoration: ShapeDecoration(
                shape: StadiumBorder(side: BorderSide(color: palette.hairline)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 3,
                ),
                child: Text(
                  type[0].toUpperCase() + type.substring(1),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: palette.secondaryText,
                    fontWeight: FontWeight.w700,
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
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
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
                color: palette.secondaryText,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          if (insight.explanation.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Hairline(),
            const SizedBox(height: 16),
            Text(insight.explanation, style: theme.textTheme.bodyLarge),
          ],
          if (insight.variations.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Hairline(),
            const SizedBox(height: 12),
            Semantics(
              header: true,
              child: Text(
                l10n.translateInsightVariations,
                style: TranslateLayout.headingStyle(context),
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
///
/// Each phrase is underlined where [TranslateCubit.locateInsight] places it
/// (whole words, nearest to where its source phrase sits in [source]), so a
/// repeated phrase is marked at the right occurrence.
class InsightText extends StatefulWidget {
  const new({
    required this.text,
    required this.insights,
    this.onTap,
    this.onTapAt,
    this.source,
    this.style,
    this.textDirection,
    this.locale,
    super.key,
  });

  final String text;
  final List<WordInsight> insights;

  /// Called with the tapped insight (unless [onTapAt] is set).
  final ValueChanged<WordInsight>? onTap;

  /// Called with the tapped insight and the start of the tapped highlight
  /// in [text]; takes precedence over [onTap].
  final void Function(WordInsight insight, int offset)? onTapAt;

  /// The text [text] is a translation of (helps to pick the occurrence of a
  /// repeated phrase).
  final String? source;
  final TextStyle? style;

  /// Direction of [text] (the target language's).
  final TextDirection? textDirection;

  /// Language of [text], so screen readers use a matching voice.
  final Locale? locale;

  /// Non-overlapping (start, end, insight) ranges, in text order.
  ///
  /// Each insight is placed where [TranslateCubit.locateInsight] finds it
  /// (using [source], the text [text] translates). When another insight
  /// already covers that place, the nearest free occurrence is used;
  /// insights whose phrase does not occur are skipped.
  static List<(int, int, WordInsight)> ranges(
    String text,
    List<WordInsight> insights, {
    String? source,
  }) {
    final result = <(int, int, WordInsight)>[];
    bool free(int start, int end) =>
        !result.any((r) => start < r.$2 && end > r.$1);
    for (final insight in insights) {
      final target = insight.targetText;
      if (target.trim().isEmpty) continue;
      final located = TranslateCubit.locateInsight(
        text,
        insight,
        source: source,
      );
      if (located == null) continue;
      final candidates = [
        for (
          var i = text.indexOf(target);
          i >= 0;
          i = text.indexOf(target, i + 1)
        )
          if (i != located) i,
      ]..sort((a, b) => (a - located).abs().compareTo((b - located).abs()));
      for (final start in [located, ...candidates]) {
        if (free(start, start + target.length)) {
          result.add((start, start + target.length, insight));
          break;
        }
      }
    }
    return result..sort((a, b) => a.$1.compareTo(b.$1));
  }

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

  void _onTap(WordInsight insight, int offset) {
    final onTapAt = widget.onTapAt;
    if (onTapAt != null) {
      onTapAt(insight, offset);
    } else {
      widget.onTap?.call(insight);
    }
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
    for (final (start, end, insight) in InsightText.ranges(
      text,
      widget.insights,
      source: widget.source,
    )) {
      if (start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, start)));
      }
      final recognizer = TapGestureRecognizer()
        ..onTap = () => _onTap(insight, start);
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
