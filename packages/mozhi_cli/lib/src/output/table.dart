import 'package:mozhi_cli/src/output/text_width.dart';

/// Renders rows as left-aligned columns separated by two spaces.
///
/// [styleHeader] decorates the header cells (e.g. bold); padding is
/// computed on the visible width, so ANSI styles and CJK text line up.
/// Trailing spaces are trimmed from every line.
String renderTable(
  List<String> headers,
  List<List<String>> rows, {
  String Function(String header)? styleHeader,
}) {
  final widths = [
    for (var column = 0; column < headers.length; column++)
      [
        displayWidth(headers[column]),
        for (final row in rows)
          if (column < row.length) displayWidth(row[column]),
      ].reduce((a, b) => a > b ? a : b),
  ];

  String line(List<String> cells, [String Function(String)? style]) {
    final buffer = StringBuffer();
    for (var column = 0; column < headers.length; column++) {
      final cell = column < cells.length ? cells[column] : '';
      final padded = column == headers.length - 1
          ? cell
          : '${padDisplay(cell, widths[column])}  ';
      buffer.write(
        style == null ? padded : _styleKeepingPadding(padded, style),
      );
    }
    return buffer.toString().trimRight();
  }

  return [
    line(headers, styleHeader),
    for (final row in rows) line(row),
  ].join('\n');
}

String _styleKeepingPadding(String cell, String Function(String) style) {
  final trimmed = cell.trimRight();
  return '${style(trimmed)}${cell.substring(trimmed.length)}';
}
