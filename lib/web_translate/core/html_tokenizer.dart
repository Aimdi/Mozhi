/// A small, forgiving HTML tokenizer (no external parser dependency).
///
/// It follows the HTML 5 tokenizer closely enough for text extraction:
/// comments, doctypes and processing instructions are skipped, `<script>`,
/// `<style>` and friends are read as raw text, `<title>`/`<textarea>` as
/// escapable raw text, attribute values may be quoted or not, entities are
/// decoded in text and attribute values, and stray `<` characters are kept
/// as text. Malformed input never throws.
library;

import 'package:mozhi/web_translate/core/html_entities.dart';

/// A token produced by [tokenizeHtml].
sealed class HtmlToken {
  const new();
}

/// `<name attr="value">`; [name] and attribute names are lower-cased.
final class HtmlStartTag extends HtmlToken {
  const new(this.name, {this.attributes = const {}, this.selfClosing = false});

  final String name;
  final Map<String, String> attributes;

  /// Written as `<name ... />`.
  final bool selfClosing;

  @override
  String toString() => 'HtmlStartTag($name, $attributes)';
}

/// `</name>`; [name] is lower-cased.
final class HtmlEndTag extends HtmlToken {
  const new(this.name);

  final String name;

  @override
  String toString() => 'HtmlEndTag($name)';
}

/// Character data with entities decoded (raw for `<script>`/`<style>`).
final class HtmlCharacters extends HtmlToken {
  const new(this.text);

  final String text;

  @override
  String toString() => 'HtmlCharacters($text)';
}

/// Elements whose content is raw text up to the matching end tag.
const rawTextElements = {
  'script',
  'style',
  'xmp',
  'iframe',
  'noembed',
  'noframes',
  'noscript',
  'plaintext',
};

/// Elements whose content is text (with entities) up to the end tag.
const escapableRawTextElements = {'title', 'textarea'};

/// Splits [html] into tokens.
Iterable<HtmlToken> tokenizeHtml(String html) sync* {
  final length = html.length;
  var pos = 0;
  var textStart = 0;

  while (pos < length) {
    final lt = html.indexOf('<', pos);
    if (lt < 0 || lt + 1 >= length) break;
    final next = html.codeUnitAt(lt + 1);

    if (_isAsciiLetter(next)) {
      final tag = _readStartTag(html, lt);
      if (tag == null) {
        // Unterminated tag at the end of the input: drop it.
        if (lt > textStart) yield _characters(html, textStart, lt);
        textStart = length;
        pos = length;
        break;
      }
      if (lt > textStart) yield _characters(html, textStart, lt);
      yield tag.token;
      pos = tag.end;
      textStart = pos;
      final name = tag.token.name;
      final raw = rawTextElements.contains(name);
      if (!tag.token.selfClosing &&
          (raw || escapableRawTextElements.contains(name))) {
        if (name == 'plaintext') {
          if (pos < length) {
            yield HtmlCharacters(html.substring(pos));
          }
          return;
        }
        final close = _findEndTag(html, name, pos);
        if (close < 0) {
          if (raw) {
            // Like browsers: an unclosed script swallows the rest.
            if (pos < length) yield HtmlCharacters(html.substring(pos));
            return;
          }
          // Unclosed <title>/<textarea>: carry on as normal markup.
          continue;
        }
        if (close > pos) {
          final content = html.substring(pos, close);
          yield HtmlCharacters(raw ? content : decodeHtmlEntities(content));
        }
        final gt = html.indexOf('>', close);
        yield HtmlEndTag(name);
        pos = gt < 0 ? length : gt + 1;
        textStart = pos;
      }
      continue;
    }

    if (next == _slash) {
      if (lt + 2 < length && _isAsciiLetter(html.codeUnitAt(lt + 2))) {
        var i = lt + 2;
        while (i < length && !_isTagNameEnd(html.codeUnitAt(i))) {
          i++;
        }
        final name = _asciiLower(html.substring(lt + 2, i));
        final gt = _findTagEnd(html, i);
        if (gt < 0) {
          if (lt > textStart) yield _characters(html, textStart, lt);
          textStart = length;
          pos = length;
          break;
        }
        if (lt > textStart) yield _characters(html, textStart, lt);
        yield HtmlEndTag(name);
        pos = gt + 1;
        textStart = pos;
        continue;
      }
      // `</>` is ignored, `</ ...>` is a bogus comment.
      if (lt > textStart) yield _characters(html, textStart, lt);
      final gt = html.indexOf('>', lt + 2);
      pos = gt < 0 ? length : gt + 1;
      textStart = pos;
      continue;
    }

    if (next == _bang) {
      if (lt > textStart) yield _characters(html, textStart, lt);
      if (html.startsWith('<!--', lt)) {
        final end = html.indexOf('-->', lt + 4);
        pos = end < 0 ? length : end + 3;
      } else if (html.startsWith('<![CDATA[', lt)) {
        final end = html.indexOf(']]>', lt + 9);
        final contentEnd = end < 0 ? length : end;
        if (contentEnd > lt + 9) {
          yield HtmlCharacters(html.substring(lt + 9, contentEnd));
        }
        pos = end < 0 ? length : end + 3;
      } else {
        // <!DOCTYPE ...> and other markup declarations.
        final gt = html.indexOf('>', lt + 2);
        pos = gt < 0 ? length : gt + 1;
      }
      textStart = pos;
      continue;
    }

    if (next == _question) {
      // Processing instruction / bogus comment: <?xml ...?>.
      if (lt > textStart) yield _characters(html, textStart, lt);
      final gt = html.indexOf('>', lt + 2);
      pos = gt < 0 ? length : gt + 1;
      textStart = pos;
      continue;
    }

    // A literal "<" (e.g. "a < b"): keep it as text.
    pos = lt + 1;
  }

  if (textStart < length) yield _characters(html, textStart, length);
}

HtmlCharacters _characters(String html, int start, int end) =>
    HtmlCharacters(decodeHtmlEntities(html.substring(start, end)));

({HtmlStartTag token, int end})? _readStartTag(String html, int lt) {
  final length = html.length;
  var i = lt + 1;
  while (i < length && !_isTagNameEnd(html.codeUnitAt(i))) {
    i++;
  }
  final name = _asciiLower(html.substring(lt + 1, i));
  final attributes = <String, String>{};
  var selfClosing = false;

  while (true) {
    // Skip whitespace and stray slashes.
    while (i < length) {
      final c = html.codeUnitAt(i);
      if (_isSpace(c)) {
        i++;
      } else if (c == _slash) {
        selfClosing = i + 1 < length && html.codeUnitAt(i + 1) == _gt;
        i++;
      } else {
        break;
      }
    }
    if (i >= length) return null;
    if (html.codeUnitAt(i) == _gt) {
      return (
        token: HtmlStartTag(
          name,
          attributes: attributes,
          selfClosing: selfClosing,
        ),
        end: i + 1,
      );
    }
    selfClosing = false;

    // Attribute name (a leading "=" belongs to the name, as in HTML 5).
    final nameStart = i;
    i++;
    while (i < length) {
      final c = html.codeUnitAt(i);
      if (_isSpace(c) || c == _slash || c == _gt || c == _equals) break;
      i++;
    }
    final attrName = _asciiLower(html.substring(nameStart, i));
    while (i < length && _isSpace(html.codeUnitAt(i))) {
      i++;
    }
    var value = '';
    if (i < length && html.codeUnitAt(i) == _equals) {
      i++;
      while (i < length && _isSpace(html.codeUnitAt(i))) {
        i++;
      }
      if (i >= length) return null;
      final quote = html.codeUnitAt(i);
      if (quote == _doubleQuote || quote == _singleQuote) {
        final close = html.indexOf(String.fromCharCode(quote), i + 1);
        if (close < 0) return null;
        value = html.substring(i + 1, close);
        i = close + 1;
      } else {
        final valueStart = i;
        while (i < length) {
          final c = html.codeUnitAt(i);
          if (_isSpace(c) || c == _gt) break;
          i++;
        }
        value = html.substring(valueStart, i);
      }
    }
    attributes.putIfAbsent(
      attrName,
      () => decodeHtmlEntities(value, inAttribute: true),
    );
  }
}

/// Index of the `>` closing a tag whose name ended at [from], honouring
/// quoted attribute values; -1 when unterminated.
int _findTagEnd(String html, int from) {
  final length = html.length;
  var i = from;
  while (i < length) {
    final c = html.codeUnitAt(i);
    if (c == _gt) return i;
    if (c == _doubleQuote || c == _singleQuote) {
      final close = html.indexOf(String.fromCharCode(c), i + 1);
      if (close < 0) return -1;
      i = close + 1;
      continue;
    }
    i++;
  }
  return -1;
}

/// Index of `</name` (ASCII case-insensitive, followed by whitespace, `/`,
/// `>` or the end) at or after [from]; -1 when absent.
int _findEndTag(String html, String name, int from) {
  var i = from;
  while (true) {
    final candidate = html.indexOf('</', i);
    if (candidate < 0) return -1;
    final nameEnd = candidate + 2 + name.length;
    if (nameEnd <= html.length &&
        _asciiLower(html.substring(candidate + 2, nameEnd)) == name &&
        (nameEnd == html.length || _isTagNameEnd(html.codeUnitAt(nameEnd)))) {
      return candidate;
    }
    i = candidate + 2;
  }
}

String _asciiLower(String s) {
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c >= 0x41 && c <= 0x5A) {
      final units = s.codeUnits.toList();
      for (var j = i; j < units.length; j++) {
        final u = units[j];
        if (u >= 0x41 && u <= 0x5A) units[j] = u + 0x20;
      }
      return String.fromCharCodes(units);
    }
  }
  return s;
}

bool _isAsciiLetter(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

bool _isSpace(int c) =>
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D;

bool _isTagNameEnd(int c) => _isSpace(c) || c == _slash || c == _gt;

const _slash = 0x2F; // /
const _gt = 0x3E; // >
const _bang = 0x21; // !
const _question = 0x3F; // ?
const _equals = 0x3D; // =
const _doubleQuote = 0x22; // "
const _singleQuote = 0x27; // '
