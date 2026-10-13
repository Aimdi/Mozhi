import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/quick_translate/models/quick_languages.dart';
import 'package:translation_repository/translation_repository.dart';

/// The incoming text, collapsed to [collapsedLines] lines with a
/// "Show more" toggle when it is longer, plus the detected source language.
class QuickSourceCard extends StatefulWidget {
  const new({
    required this.text,
    this.detectedSource,
    this.collapsedLines = 2,
    this.initiallyExpanded = false,
    super.key,
  });

  final String text;

  /// Code of the auto-detected language (null while unknown).
  final String? detectedSource;
  final int collapsedLines;
  final bool initiallyExpanded;

  @override
  State<QuickSourceCard> createState() => _QuickSourceCardState();
}

class _QuickSourceCardState extends State<QuickSourceCard> {
  late bool _expanded = widget.initiallyExpanded;

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final detected = widget.detectedSource;
    final textStyle = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final direction = detected == null
        ? null
        : (isRtlLanguage(detected) ? TextDirection.rtl : TextDirection.ltr);

    return Card.filled(
      key: const Key('quick_translate_source'),
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHigh,
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final overflows = _overflows(
            context,
            style: textStyle,
            maxWidth: constraints.maxWidth - 32,
            direction: direction,
          );
          final header = Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 4, 0),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    l10n.quickTranslateOriginal,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (detected != null) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    flex: 2,
                    child: Text(
                      l10n.translateDetectedLanguage(
                        LanguageCatalog.nameOf(detected),
                      ),
                      key: const Key('quick_translate_detected'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.primary,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                if (overflows || _expanded)
                  IconButton(
                    key: const Key('quick_translate_source_toggle'),
                    tooltip: _expanded
                        ? l10n.quickTranslateShowLess
                        : l10n.quickTranslateShowMore,
                    isSelected: _expanded,
                    icon: const Icon(Icons.expand_more),
                    selectedIcon: const Icon(Icons.expand_less),
                    onPressed: _toggle,
                  )
                else
                  const SizedBox(height: 48),
              ],
            ),
          );
          return Semantics(
            expanded: overflows || _expanded ? _expanded : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    alignment: AlignmentDirectional.topStart,
                    child: Text(
                      widget.text,
                      key: const Key('quick_translate_source_text'),
                      maxLines: _expanded ? null : widget.collapsedLines,
                      overflow: _expanded ? null : TextOverflow.ellipsis,
                      textDirection: direction,
                      style: textStyle,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  bool _overflows(
    BuildContext context, {
    required TextStyle? style,
    required double maxWidth,
    required TextDirection? direction,
  }) {
    if (maxWidth <= 0) return false;
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: style),
      maxLines: widget.collapsedLines,
      textDirection: direction ?? Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxWidth);
    final exceeded = painter.didExceedMaxLines;
    painter.dispose();
    return exceeded;
  }
}
