import 'dart:async';

/// Removes `<think>...</think>` / `<thinking>...</thinking>` /
/// `<reasoning>...</reasoning>` blocks that reasoning models (DeepSeek-R1,
/// Qwen3, QwQ, some LM Studio / llama.cpp setups) emit inline at the start
/// of the content stream.
///
/// Only blocks at the start of the output are removed (after any
/// whitespace, and possibly several in a row). Once visible text has been
/// emitted, tags are ordinary text, so a translation that legitimately
/// contains `<think>` or `<reasoning>` is kept intact. A closing tag that
/// arrives before any visible text and without an opening tag is dropped as
/// well.
///
/// Works on *streamed* text where tags may be split across chunks: text at
/// the start that might be the beginning of a tag is held back until it can
/// be decided, as is leading whitespace (which is dropped when a block
/// follows it). An unterminated block at end of stream is dropped. Also
/// drops the whitespace that follows a removed block.
///
/// Tags match case-insensitively and blocks do not nest: a block ends at the
/// first closing tag of the same name.
///
/// Reasoning whose opening tag is part of the prompt (chat templates of
/// DeepSeek-R1 or QwQ served by vLLM without `--reasoning-parser`, or by
/// llama-server with `--reasoning-format none`) arrives as
/// `reasoning</think>answer`. The streaming filter cannot take back the
/// reasoning it already emitted, so it passes such a closing tag through
/// unchanged; [strip] removes everything up to it. Consumers that
/// accumulate the streamed text should therefore apply [strip] to the
/// accumulated text before showing it.
class ThinkTagFilter extends StreamTransformerBase<String, String> {
  const new();

  /// Convenience for complete strings.
  ///
  /// Besides what the streaming filter removes, a closing tag that appears
  /// before any opening tag is treated as the end of reasoning whose opening
  /// tag was part of the prompt: it and everything before it are dropped,
  /// along with the whitespace after it.
  static String strip(String text) {
    final parser = _ThinkTagParser();
    final end = _ThinkTagParser.orphanReasoningEnd(text);
    final rest = end == 0 ? text : text.substring(end).trimLeft();
    return parser.add(rest) + parser.close();
  }

  @override
  Stream<String> bind(Stream<String> stream) =>
      Stream<String>.eventTransformed(stream, _ThinkTagSink.new);
}

class _ThinkTagSink implements EventSink<String> {
  new(this._output);

  final EventSink<String> _output;
  final _ThinkTagParser _parser = _ThinkTagParser();

  @override
  void add(String chunk) => _emit(_parser.add(chunk));

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _output.addError(error, stackTrace);

  @override
  void close() {
    _emit(_parser.close());
    _output.close();
  }

  void _emit(String text) {
    if (text.isNotEmpty) _output.add(text);
  }
}

/// Incremental state machine behind [ThinkTagFilter].
class _ThinkTagParser {
  /// Opening tags (lower case) of the blocks that are removed.
  static const _openingTags = ['<think>', '<thinking>', '<reasoning>'];

  /// Closing tags (lower case) matching [_openingTags].
  static const _closingTags = ['</think>', '</thinking>', '</reasoning>'];

  static const List<String> _allTags = [..._openingTags, ..._closingTags];

  /// Input that could not be decided yet and is prepended to the next chunk:
  /// a possible partial tag at the start of the output, or a possible
  /// partial closing tag inside a block.
  String _pending = '';

  /// The closing tag (lower case) while inside a block, otherwise null.
  String? _closingTag;

  /// Whether no visible text has been emitted yet. Blocks are only
  /// recognised at the start of the output; afterwards everything is text.
  bool _atStart = true;

  /// Whitespace at the start of the output, held back until visible text
  /// follows it.
  String _leadingWhitespace = '';

  /// Whether leading whitespace is dropped, i.e. a block was removed and no
  /// visible text followed it yet.
  bool _skipWhitespace = false;

  /// Consumes [chunk] and returns the text that can be emitted.
  String add(String chunk) {
    final input = _pending + chunk;
    _pending = '';
    if (!_atStart) return input;
    final output = StringBuffer();
    var index = 0;
    while (index < input.length) {
      final closingTag = _closingTag;
      if (closingTag != null) {
        final end = _indexOfTag(input, closingTag, index);
        if (end < 0) {
          // Discard the block content but keep a possible partial closing
          // tag at the end of the chunk.
          final lastOpen = input.lastIndexOf('<');
          if (lastOpen >= index && _isPartialTag(input, lastOpen, closingTag)) {
            _pending = input.substring(lastOpen);
          }
          break;
        }
        index = end + closingTag.length;
        _closingTag = null;
        continue;
      }
      if (!_atStart) {
        output.write(input.substring(index));
        break;
      }

      final open = input.indexOf('<', index);
      if (open < 0) {
        _write(output, input.substring(index));
        break;
      }
      _write(output, input.substring(index, open));
      index = open;
      if (!_atStart) continue;
      if (_tagAt(input, open, _openingTags) case final tag?) {
        _closingTag = '</${tag.substring(1)}';
        _dropLeadingWhitespace();
        index = open + tag.length;
      } else if (_tagAt(input, open, _closingTags) case final tag?) {
        // Only whitespace came before it: the block was opened by the
        // prompt and is empty.
        _dropLeadingWhitespace();
        index = open + tag.length;
      } else if (_allTags.any((tag) => _isPartialTag(input, open, tag))) {
        _pending = input.substring(open);
        break;
      } else {
        _write(output, '<');
        index = open + 1;
      }
    }
    return output.toString();
  }

  /// Flushes held back text at end of stream. An unterminated block is
  /// dropped.
  String close() {
    final output = StringBuffer();
    if (_closingTag == null) _write(output, _pending);
    if (!_skipWhitespace) output.write(_leadingWhitespace);
    _pending = '';
    _closingTag = null;
    _atStart = true;
    _leadingWhitespace = '';
    _skipWhitespace = false;
    return output.toString();
  }

  /// Writes [text] while at the start of the output: whitespace is held back
  /// (or dropped after a block) until visible text follows.
  void _write(StringBuffer output, String text) {
    final visible = text.trimLeft();
    if (visible.isEmpty) {
      if (!_skipWhitespace) _leadingWhitespace += text;
      return;
    }
    if (_skipWhitespace) {
      output.write(visible);
    } else {
      output
        ..write(_leadingWhitespace)
        ..write(text);
    }
    _leadingWhitespace = '';
    _atStart = false;
  }

  void _dropLeadingWhitespace() {
    _leadingWhitespace = '';
    _skipWhitespace = true;
  }

  /// The index just after the first closing tag of [text] when no opening
  /// tag comes before it, otherwise 0.
  static int orphanReasoningEnd(String text) {
    for (
      var at = text.indexOf('<');
      at >= 0;
      at = text.indexOf('<', at + 1)
    ) {
      if (_tagAt(text, at, _openingTags) != null) return 0;
      if (_tagAt(text, at, _closingTags) case final tag?) {
        return at + tag.length;
      }
    }
    return 0;
  }

  /// The tag of [tags] that [input] contains at [at], if any.
  static String? _tagAt(String input, int at, List<String> tags) {
    for (final tag in tags) {
      if (input.length - at >= tag.length &&
          _matchesIgnoreCase(input, at, tag, tag.length)) {
        return tag;
      }
    }
    return null;
  }

  /// Whether the input from [at] to its end is a proper prefix of [tag].
  static bool _isPartialTag(String input, int at, String tag) {
    final remaining = input.length - at;
    return remaining < tag.length &&
        _matchesIgnoreCase(input, at, tag, remaining);
  }

  static int _indexOfTag(String input, String tag, int start) {
    for (
      var at = input.indexOf('<', start);
      at >= 0;
      at = input.indexOf('<', at + 1)
    ) {
      if (input.length - at >= tag.length &&
          _matchesIgnoreCase(input, at, tag, tag.length)) {
        return at;
      }
    }
    return -1;
  }

  /// Compares [length] code units of [input] at [at] with the lower case
  /// ASCII [tag], ignoring ASCII case.
  static bool _matchesIgnoreCase(String input, int at, String tag, int length) {
    for (var i = 0; i < length; i++) {
      final unit = input.codeUnitAt(at + i);
      final lower = unit >= 0x41 && unit <= 0x5A ? unit | 0x20 : unit;
      if (lower != tag.codeUnitAt(i)) return false;
    }
    return true;
  }
}
