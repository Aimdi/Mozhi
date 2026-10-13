import 'package:material_ui/material_ui.dart';

/// Minimal Markdown renderer for streamed LLM explanations: paragraphs,
/// headings (`#`), bullet (`-`, `*`, `•`) and numbered lists, plus inline
/// `**bold**`, `*italic*` and `` `code` ``. Unclosed markers render as-is,
/// so partially streamed text stays readable.
class MarkdownLite extends StatelessWidget {
  const new(this.data, {super.key});

  final String data;

  static final _bullet = RegExp(r'^\s*[-*•]\s+(.*)$');
  static final _numbered = RegExp(r'^\s*(\d+)[.)]\s+(.*)$');
  static final _heading = RegExp(r'^\s*#{1,6}\s+(.*)$');
  static final _inline = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`|\*([^*\s][^*]*)\*');

  /// Splits [text] into styled spans for bold/italic/code markers.
  static List<InlineSpan> inlineSpans(String text, TextStyle? codeStyle) {
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final match in _inline.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      final bold = match.group(1);
      final code = match.group(2);
      final italic = match.group(3);
      if (bold != null) {
        spans.add(
          TextSpan(
            text: bold,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        );
      } else if (code != null) {
        spans.add(TextSpan(text: code, style: codeStyle));
      } else if (italic != null) {
        spans.add(
          TextSpan(
            text: italic,
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        );
      }
      cursor = match.end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = theme.textTheme.bodyLarge;
    final codeStyle = TextStyle(
      fontFamily: 'monospace',
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
    );
    final blocks = <Widget>[];
    final paragraph = <String>[];

    Widget rich(String text, {TextStyle? style}) => Text.rich(
      TextSpan(children: inlineSpans(text, codeStyle)),
      style: style ?? body,
    );

    void flush() {
      if (paragraph.isEmpty) return;
      blocks.add(rich(paragraph.join(' ')));
      paragraph.clear();
    }

    Widget listItem(String marker, String text) => Padding(
      padding: const EdgeInsetsDirectional.only(start: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A minimum (not fixed) width so "10." never clips at large text.
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 24),
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: 4),
              child: Text(marker, style: body),
            ),
          ),
          Expanded(child: rich(text)),
        ],
      ),
    );

    for (final line in data.split('\n')) {
      if (line.trim().isEmpty) {
        flush();
        continue;
      }
      final heading = _heading.firstMatch(line);
      final bullet = _bullet.firstMatch(line);
      final numbered = _numbered.firstMatch(line);
      if (heading != null) {
        flush();
        blocks.add(
          Semantics(
            header: true,
            child: rich(heading.group(1)!, style: theme.textTheme.titleMedium),
          ),
        );
      } else if (bullet != null) {
        flush();
        blocks.add(listItem('•', bullet.group(1)!));
      } else if (numbered != null) {
        flush();
        blocks.add(listItem('${numbered.group(1)}.', numbered.group(2)!));
      } else {
        paragraph.add(line.trim());
      }
    }
    flush();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          blocks[i],
        ],
      ],
    );
  }
}
