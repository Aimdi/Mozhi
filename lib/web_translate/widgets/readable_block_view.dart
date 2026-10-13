import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/web_translate/core/readable_extractor.dart';
import 'package:mozhi/web_translate/widgets/web_translate_messages.dart';

/// Renders one [ReadableBlock] with [text] (the translation or the
/// original). [pending] blocks (not translated yet) are dimmed.
class ReadableBlockView extends StatelessWidget {
  const ReadableBlockView({
    required this.block,
    required this.text,
    this.pending = false,
    this.languageCode,
    super.key,
  });

  final ReadableBlock block;
  final String text;
  final bool pending;

  /// Language of [text], to lay out right-to-left scripts correctly.
  final String? languageCode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final colors = theme.colorScheme;
    final body = textTheme.bodyLarge?.copyWith(height: 1.55);

    final Widget content = switch (block.kind) {
      ReadableBlockKind.heading1 ||
      ReadableBlockKind.heading2 ||
      ReadableBlockKind.heading3 ||
      ReadableBlockKind.heading4 ||
      ReadableBlockKind.heading5 ||
      ReadableBlockKind.heading6 => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Semantics(
          header: true,
          child: Text(text, style: _headingStyle(textTheme)),
        ),
      ),
      ReadableBlockKind.paragraph => Text(text, style: body),
      ReadableBlockKind.listItem => Padding(
        padding: EdgeInsetsDirectional.only(start: 16.0 * block.depth),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 28,
              child: Text(
                block.number == null ? '•' : '${block.number}.',
                style: body?.copyWith(color: colors.primary),
              ),
            ),
            Expanded(child: Text(text, style: body)),
          ],
        ),
      ),
      ReadableBlockKind.quote => Container(
        padding: const EdgeInsetsDirectional.only(start: 16, top: 4, bottom: 4),
        decoration: BoxDecoration(
          border: BorderDirectional(
            start: BorderSide(color: colors.primary, width: 3),
          ),
        ),
        child: Text(
          text,
          style: body?.copyWith(
            fontStyle: FontStyle.italic,
            color: colors.onSurfaceVariant,
          ),
        ),
      ),
      ReadableBlockKind.code => Directionality(
        textDirection: TextDirection.ltr,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              text,
              style: textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
                fontFamilyFallback: const ['Courier New', 'Courier'],
              ),
            ),
          ),
        ),
      ),
      ReadableBlockKind.image => Semantics(
        label: context.l10n.webTranslateImage(text),
        excludeSemantics: true,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: colors.outlineVariant),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.image_outlined, color: colors.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  text,
                  style: textTheme.bodyMedium?.copyWith(
                    fontStyle: FontStyle.italic,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    };

    final directed =
        languageCode == null || block.kind == ReadableBlockKind.code
        ? content
        : Directionality(
            textDirection: isRtlLanguage(languageCode)
                ? TextDirection.rtl
                : TextDirection.ltr,
            child: content,
          );
    return AnimatedOpacity(
      opacity: pending ? 0.55 : 1,
      duration: const Duration(milliseconds: 200),
      child: directed,
    );
  }

  TextStyle? _headingStyle(TextTheme textTheme) {
    final style = switch (block.kind.headingLevel) {
      1 => textTheme.headlineSmall,
      2 => textTheme.titleLarge,
      3 => textTheme.titleMedium,
      _ => textTheme.titleSmall,
    };
    return style?.copyWith(fontWeight: FontWeight.w600);
  }
}
