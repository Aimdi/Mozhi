import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/models/writing_stats.dart';
import 'package:mozhi/proofread/widgets/proofread_labels.dart';

/// A collapsible card with the [WritingStats] of the [original] text and
/// of the [corrected] one (before -> after), computed on the device.
///
/// The Flesch reading-ease row only appears for English ([languageCode]).
/// Collapsed, it shows the corrected text's word count and reading time.
class ProofreadStatsPanel extends StatefulWidget {
  const new({
    required this.original,
    required this.corrected,
    this.languageCode,
    super.key,
  });

  /// The text that was proofread.
  final String original;

  /// The text with the accepted edits applied.
  final String corrected;

  /// Language of the text (enables the Flesch score for English).
  final String? languageCode;

  @override
  State<ProofreadStatsPanel> createState() => _ProofreadStatsPanelState();
}

class _ProofreadStatsPanelState extends State<ProofreadStatsPanel> {
  final _original = _CachedStats();
  final _corrected = _CachedStats();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final format = _StatsFormat.of(context);
    final before = _original.of(widget.original, widget.languageCode);
    final after = _corrected.of(widget.corrected, widget.languageCode);
    final beforeFlesch = before.fleschReadingEase;
    final afterFlesch = after.fleschReadingEase;

    return Card.outlined(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: const PageStorageKey('proofread_stats'),
        shape: const Border(),
        collapsedShape: const Border(),
        leading: const Icon(Icons.insights_outlined),
        title: Text(l10n.proofreadStatsTitle),
        subtitle: Text(
          l10n.proofreadStatsSummary(
            l10n.proofreadStatsWordCount(
              after.words,
              format.integer(after.words),
            ),
            format.duration(after.readingTime),
          ),
        ),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        childrenPadding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 12),
        children: [
          const _Legend(),
          _StatRow(
            label: l10n.proofreadStatsWords,
            before: format.integer(before.words),
            after: format.integer(after.words),
          ),
          _StatRow(
            label: l10n.proofreadStatsCharacters,
            before: format.integer(before.characters),
            after: format.integer(after.characters),
          ),
          _StatRow(
            label: l10n.proofreadStatsSentences,
            before: format.integer(before.sentences),
            after: format.integer(after.sentences),
          ),
          _StatRow(
            label: l10n.proofreadStatsParagraphs,
            before: format.integer(before.paragraphs),
            after: format.integer(after.paragraphs),
          ),
          _StatRow(
            label: l10n.proofreadStatsWordsPerSentence,
            before: format.decimal(before.averageSentenceLength),
            after: format.decimal(after.averageSentenceLength),
          ),
          _StatRow(
            label: l10n.proofreadStatsReadingTime,
            before: format.duration(before.readingTime),
            after: format.duration(after.readingTime),
          ),
          if (beforeFlesch != null || afterFlesch != null)
            _StatRow(
              key: const Key('proofread_stats_flesch'),
              label: l10n.proofreadStatsFlesch,
              hint: l10n.proofreadStatsFleschHint,
              before: format.score(beforeFlesch),
              after: format.score(afterFlesch),
              beforeNote: _band(l10n, before.fleschBand),
              afterNote: _band(l10n, after.fleschBand),
            ),
        ],
      ),
    );
  }

  static String _band(AppLocalizations l10n, FleschBand? band) =>
      band == null ? '' : l10n.proofreadFleschBand(band);
}

/// The `intl` locale to format numbers for [locale] with: the locale
/// itself, else its language, else English.
String proofreadNumberLocale(Locale locale) => Intl.verifiedLocale(
  locale.toString(),
  NumberFormat.localeExists,
  onFailure: (_) => 'en',
)!;

/// [WritingStats] of the last text (and language) asked for.
class _CachedStats {
  String? _text;
  String? _language;
  WritingStats? _stats;

  WritingStats of(String text, String? language) {
    final stats = _stats;
    if (stats != null && text == _text && language == _language) return stats;
    _text = text;
    _language = language;
    return _stats = WritingStats.of(text, languageCode: language);
  }
}

/// Locale-aware formatting of the statistics.
class _StatsFormat {
  const new(this.l10n, this.locale);

  factory of(BuildContext context) => _StatsFormat(
    context.l10n,
    proofreadNumberLocale(Localizations.localeOf(context)),
  );

  final AppLocalizations l10n;
  final String locale;

  String integer(int value) =>
      NumberFormat.decimalPattern(locale).format(value);

  String decimal(double value) => NumberFormat.decimalPatternDigits(
    locale: locale,
    decimalDigits: 1,
  ).format(value);

  /// A Flesch score with one decimal, or an en dash when there is none.
  String score(double? value) => value == null ? '–' : decimal(value);

  /// Seconds below a minute, else whole minutes.
  String duration(Duration value) {
    final seconds = value.inSeconds;
    if (seconds < 60) return l10n.proofreadStatsSeconds(seconds);
    return l10n.proofreadStatsMinutes((seconds / 60).round());
  }
}

/// "Original -> Corrected" above the values (visual only: every row reads
/// its own before and after values to screen readers).
class _Legend extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return ExcludeSemantics(
      child: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: _ChangeText(
          before: l10n.proofreadStatsOriginal,
          after: l10n.proofreadStatsCorrected,
          style: style,
          forceArrow: true,
        ),
      ),
    );
  }
}

/// A statistic: its [label] (and [hint]) at the start, its [before] and
/// [after] values (and notes) at the end; read as one item by screen
/// readers.
class _StatRow extends StatelessWidget {
  const new({
    required this.label,
    required this.before,
    required this.after,
    this.hint = '',
    this.beforeNote = '',
    this.afterNote = '',
    super.key,
  });

  final String label;
  final String hint;
  final String before;
  final String after;
  final String beforeNote;
  final String afterNote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final value = theme.textTheme.bodyMedium?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 16,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: theme.textTheme.bodyMedium),
                  if (hint.isNotEmpty) Text(hint, style: muted),
                ],
              ),
            ),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _ChangeText(before: before, after: after, style: value),
                  if (afterNote.isNotEmpty || beforeNote.isNotEmpty)
                    _ChangeText(
                      before: beforeNote,
                      after: afterNote,
                      style: muted,
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

/// `before -> after`, or just [after] when nothing changed (unless
/// [forceArrow]). The arrow follows the text direction.
class _ChangeText extends StatelessWidget {
  const new({
    required this.before,
    required this.after,
    this.style,
    this.forceArrow = false,
  });

  final String before;
  final String after;
  final TextStyle? style;
  final bool forceArrow;

  @override
  Widget build(BuildContext context) {
    if (before == after && !forceArrow) {
      return Text(after, style: style, textAlign: TextAlign.end);
    }
    final theme = Theme.of(context);
    final text = Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(
            text: before,
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(
                Icons.arrow_forward,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextSpan(
            text: after,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
      textAlign: TextAlign.end,
    );
    if (forceArrow) return text;
    return Semantics(
      label: context.l10n.proofreadStatsChangeSemantics(before, after),
      excludeSemantics: true,
      child: text,
    );
  }
}
