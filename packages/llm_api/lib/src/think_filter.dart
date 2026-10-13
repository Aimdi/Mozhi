import 'dart:async';

/// Removes `<think>...</think>` / `<thinking>...</thinking>` /
/// `<reasoning>...</reasoning>` blocks that reasoning models (DeepSeek-R1,
/// Qwen3, QwQ, some LM Studio / llama.cpp setups) emit inline in the
/// content stream.
///
/// Works on *streamed* text where tags may be split across chunks: text
/// that might be the beginning of an opening tag is held back until it can
/// be decided. An unterminated block at end of stream is dropped. Also
/// drops a leading run of whitespace that follows a removed block.
///
/// Tags match case-insensitively and blocks do not nest: a block ends at the
/// first closing tag of the same name.
class ThinkTagFilter extends StreamTransformerBase<String, String> {
  const new();

  /// Convenience for complete strings.
  static String strip(String text) {
    final parser = _ThinkTagParser();
    return parser.add(text) + parser.close();
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

  /// Input that could not be decided yet and is prepended to the next chunk:
  /// a possible partial opening tag (outside a block) or closing tag (inside
  /// one).
  String _pending = '';

  /// The closing tag (lower case) while inside a block, otherwise null.
  String? _closingTag;

  /// Whether leading whitespace is dropped, i.e. a block was just removed and
  /// no visible text followed it yet.
  bool _skipWhitespace = false;

  /// Consumes [chunk] and returns the text that can be emitted.
  String add(String chunk) {
    final input = _pending + chunk;
    _pending = '';
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
        _skipWhitespace = true;
        continue;
      }

      final open = input.indexOf('<', index);
      if (open < 0) {
        _write(output, input.substring(index));
        break;
      }
      _write(output, input.substring(index, open));
      final tag = _openingTagAt(input, open);
      if (tag != null) {
        _closingTag = '</${tag.substring(1)}';
        index = open + tag.length;
      } else if (_openingTags.any((tag) => _isPartialTag(input, open, tag))) {
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
    final rest = _closingTag == null ? _pending : '';
    final output = StringBuffer();
    _write(output, rest);
    _pending = '';
    _closingTag = null;
    _skipWhitespace = false;
    return output.toString();
  }

  void _write(StringBuffer output, String text) {
    var visible = text;
    if (_skipWhitespace) {
      visible = visible.trimLeft();
      if (visible.isEmpty) return;
      _skipWhitespace = false;
    }
    output.write(visible);
  }

  static String? _openingTagAt(String input, int at) {
    for (final tag in _openingTags) {
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
