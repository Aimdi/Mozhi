import 'package:mozhi_cli/src/output/text_width.dart';

/// Prints a growing AI translation to a terminal as it streams in.
///
/// Snapshots that extend what is already on screen are appended. The final
/// text is cleaned up by the repository (quotes, labels or code fences the
/// model added are removed), so it can differ from the streamed text: then
/// the streamed lines are erased with ANSI escapes and the final text is
/// printed instead, as long as everything printed still fits on the screen.
class StreamingPrinter {
  new({
    required this._write,
    required this._columns,
    required this._lines,
  });

  final void Function(String text) _write;
  final int _columns;
  final int _lines;
  String _printed = '';
  bool _diverged = false;

  /// Text written so far.
  String get printed => _printed;

  /// Shows the snapshot [text] (a full, growing translation).
  void update(String text) {
    if (_diverged) return;
    if (!text.startsWith(_printed)) {
      // Wait for the final text to redraw.
      _diverged = true;
      return;
    }
    final delta = text.substring(_printed.length);
    if (delta.isEmpty) return;
    _write(delta);
    _printed = text;
  }

  /// Shows the final [text] and ends the output with a newline.
  void finish(String text) {
    if (text.startsWith(_printed)) {
      _write('${text.substring(_printed.length)}\n');
    } else if (_erase()) {
      _write('$text\n');
    } else {
      _write('\n');
    }
    _printed = text;
  }

  /// Removes the streamed text (e.g. before an error is shown) when it fits
  /// on screen; otherwise just ends the line.
  void abort() {
    if (_printed.isEmpty) return;
    if (!_erase()) _write('\n');
    _printed = '';
  }

  /// Moves the cursor back to where streaming started and clears everything
  /// below it. Returns false when the streamed text scrolled off screen.
  bool _erase() {
    if (_printed.isEmpty) return true;
    final rows = rowsOf(_printed, _columns);
    if (rows >= _lines) return false;
    _write('\r${rows > 1 ? '\x1B[${rows - 1}A' : ''}\x1B[J');
    return true;
  }

  /// Number of terminal rows [text] occupies at [columns] width.
  static int rowsOf(String text, int columns) {
    final width = columns < 1 ? 1 : columns;
    var rows = 0;
    for (final line in text.split('\n')) {
      final lineWidth = displayWidth(line);
      rows += lineWidth == 0 ? 1 : (lineWidth + width - 1) ~/ width;
    }
    return rows;
  }
}
