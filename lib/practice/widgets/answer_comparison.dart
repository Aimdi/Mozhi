import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/practice/data/answer_check.dart';
import 'package:mozhi/translate/widgets/language_text.dart';

/// How an answer compares with the expected phrase ([check]): each word of
/// the phrase right (plain, with a check underline), nearly right (dotted
/// underline) or missed (struck through in the error colour), with what
/// was heard or typed ([heard]: "Heard: …" or "You typed: …") and the
/// words said beyond the phrase. Colour is never the only cue: each word
/// says how it came out to screen readers, and the marks differ.
class AnswerComparison extends StatelessWidget {
  const new({
    required this.check,
    required this.heard,
    this.languageCode,
    super.key,
  });

  final AnswerCheck check;

  /// The line naming the answer ("Heard: …").
  final String heard;

  /// The language of the phrase (its direction and glyphs).
  final String? languageCode;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final style = theme.textTheme.titleMedium!;
    final words = check.words;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          container: true,
          liveRegion: true,
          child: Text(
            l10n.practiceWordsRight(check.matched, words.length),
            style: theme.textTheme.labelLarge?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Directionality(
          textDirection:
              textDirectionForCode(languageCode) ?? Directionality.of(context),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final word in words)
                _Word(
                  word: word,
                  style: style,
                  locale: localeForCode(languageCode),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          heard,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        if (check.extra.isNotEmpty)
          Text(
            l10n.practiceExtraWords(check.extra.join(' ')),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

class _Word extends StatelessWidget {
  const new({required this.word, required this.style, this.locale});

  final AnswerWord word;
  final TextStyle style;
  final Locale? locale;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final (
      label,
      color,
      decoration,
      decorationStyle,
      icon,
    ) = switch (word.status) {
      AnswerWordStatus.matched => (
        l10n.practiceWordMatched(word.text),
        colors.onSurface,
        TextDecoration.underline,
        TextDecorationStyle.solid,
        Icons.check,
      ),
      AnswerWordStatus.close => (
        l10n.practiceWordClose(word.text),
        colors.tertiary,
        TextDecoration.underline,
        TextDecorationStyle.dotted,
        Icons.more_horiz,
      ),
      AnswerWordStatus.missed => (
        l10n.practiceWordMissed(word.text),
        colors.error,
        TextDecoration.lineThrough,
        TextDecorationStyle.solid,
        Icons.close,
      ),
    };
    return Semantics(
      container: true,
      label: label,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            word.text,
            locale: locale,
            style: style.copyWith(
              color: color,
              decoration: decoration,
              decorationStyle: decorationStyle,
              decorationColor: word.status == AnswerWordStatus.matched
                  ? colors.primary
                  : color,
              decorationThickness: 2,
            ),
          ),
          Icon(icon, size: 16, color: color),
        ],
      ),
    );
  }
}
