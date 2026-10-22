/// Just enough XML for WebDAV `207 Multi-Status` answers: a small,
/// non-validating parser with namespaces, and the reader of the
/// `multistatus` documents of `PROPFIND`.
///
/// Servers write these in many shapes (Nextcloud's and ownCloud's sabre/dav
/// with `d:` prefixes and `&quot;` in ETags, Apache mod_dav with `lp1:`
/// property prefixes, rclone and Go's `x/net/webdav` with `D:` and
/// prefixes redeclared on child elements, others with a default
/// namespace), so elements are matched by namespace and local name, never
/// by prefix. Document type declarations are skipped and no entity other
/// than the five predefined ones and character references is expanded
/// (nothing is fetched, nothing grows).
library;

import 'package:flutter/foundation.dart' show immutable;

/// The WebDAV namespace.
const davNamespace = 'DAV:';

/// One element of a parsed document: its namespace (null when its prefix
/// was not declared, or it has none and there is no default namespace),
/// local name, child elements and text.
@immutable
class XmlNode {
  const new({
    required this.namespace,
    required this.name,
    required this.children,
    required this.text,
  });

  final String? namespace;

  /// The local name (without prefix).
  final String name;
  final List<XmlNode> children;

  /// The text directly inside this element (not that of its children),
  /// entities decoded.
  final String text;

  /// Whether this is the WebDAV element [localName]. Elements without a
  /// namespace count too: a few servers leave out the declaration.
  bool isDav(String localName) =>
      name == localName && (namespace == davNamespace || namespace == null);

  /// The child elements that are the WebDAV element [localName].
  Iterable<XmlNode> dav(String localName) =>
      children.where((child) => child.isDav(localName));

  /// The first child element that is the WebDAV element [localName].
  XmlNode? firstDav(String localName) => dav(localName).firstOrNull;

  /// The text of this element and all of its descendants, in order.
  String get allText {
    if (children.isEmpty) return text;
    final buffer = StringBuffer(text);
    for (final child in children) {
      buffer.write(child.allText);
    }
    return buffer.toString();
  }
}

/// Parses [source] and returns its root element. Throws a
/// [FormatException] for anything that is not well-formed enough to read
/// (unclosed or mismatched tags, no root element).
XmlNode parseXml(String source) => _XmlParser(source).parse();

class _XmlParser {
  new(this._source);

  final String _source;
  int _at = 0;

  XmlNode parse() {
    final stack = <_OpenElement>[];
    XmlNode? root;
    while (_at < _source.length) {
      final lt = _source.indexOf('<', _at);
      final textEnd = lt < 0 ? _source.length : lt;
      if (textEnd > _at) {
        if (stack.isNotEmpty) {
          stack.last.text.write(_decode(_source.substring(_at, textEnd)));
        }
        _at = textEnd;
        continue;
      }
      if (_source.startsWith('<!--', _at)) {
        _at = _skipPast('-->');
      } else if (_source.startsWith('<![CDATA[', _at)) {
        final start = _at + 9;
        _at = _skipPast(']]>');
        if (stack.isNotEmpty) {
          stack.last.text.write(_source.substring(start, _at - 3));
        }
      } else if (_source.startsWith('<?', _at)) {
        _at = _skipPast('?>');
      } else if (_source.startsWith('<!', _at)) {
        _skipDeclaration();
      } else if (_source.startsWith('</', _at)) {
        final end = _source.indexOf('>', _at);
        if (end < 0) throw _error('Unclosed end tag');
        final name = _source.substring(_at + 2, end).trim();
        _at = end + 1;
        if (stack.isEmpty || stack.last.qualifiedName != name) {
          throw _error('Unexpected end tag </$name>');
        }
        final node = stack.removeLast().build();
        if (stack.isEmpty) {
          root ??= node;
        } else {
          stack.last.children.add(node);
        }
      } else {
        final (element, selfClosing) = _startTag(
          stack.isEmpty ? const {} : stack.last.namespaces,
        );
        if (selfClosing) {
          final node = element.build();
          if (stack.isEmpty) {
            root ??= node;
          } else {
            stack.last.children.add(node);
          }
        } else {
          stack.add(element);
        }
      }
    }
    if (stack.isNotEmpty) throw _error('Unclosed element');
    return root ?? (throw _error('No root element'));
  }

  /// Reads the start tag at [_at]: the element (namespaces resolved
  /// against [scope] and its own declarations) and whether it closes
  /// itself.
  (_OpenElement, bool) _startTag(Map<String, String> scope) {
    var i = _at + 1;
    final nameStart = i;
    while (i < _source.length && !_isNameEnd(_source.codeUnitAt(i))) {
      i++;
    }
    final qualifiedName = _source.substring(nameStart, i);
    if (qualifiedName.isEmpty) throw _error('Empty tag name');
    final attributes = <String, String>{};
    var selfClosing = false;
    while (true) {
      while (i < _source.length && _isSpace(_source.codeUnitAt(i))) {
        i++;
      }
      if (i >= _source.length) throw _error('Unclosed start tag');
      final char = _source[i];
      if (char == '>') {
        i++;
        break;
      }
      if (char == '/' && _source.startsWith('/>', i)) {
        selfClosing = true;
        i += 2;
        break;
      }
      final attributeStart = i;
      while (i < _source.length &&
          _source[i] != '=' &&
          !_isNameEnd(_source.codeUnitAt(i))) {
        i++;
      }
      final attribute = _source.substring(attributeStart, i);
      while (i < _source.length && _isSpace(_source.codeUnitAt(i))) {
        i++;
      }
      if (attribute.isEmpty || i >= _source.length || _source[i] != '=') {
        throw _error('Malformed attribute');
      }
      i++;
      while (i < _source.length && _isSpace(_source.codeUnitAt(i))) {
        i++;
      }
      if (i >= _source.length) throw _error('Unclosed start tag');
      final quote = _source[i];
      if (quote != '"' && quote != "'") throw _error('Unquoted attribute');
      final valueEnd = _source.indexOf(quote, i + 1);
      if (valueEnd < 0) throw _error('Unclosed attribute');
      attributes[attribute] = _decode(_source.substring(i + 1, valueEnd));
      i = valueEnd + 1;
    }
    _at = i;

    var namespaces = scope;
    for (final MapEntry(:key, :value) in attributes.entries) {
      final prefix = key == 'xmlns'
          ? ''
          : key.startsWith('xmlns:')
          ? key.substring(6)
          : null;
      if (prefix == null) continue;
      if (identical(namespaces, scope)) namespaces = {...scope};
      namespaces[prefix] = value;
    }
    final colon = qualifiedName.indexOf(':');
    final prefix = colon < 0 ? '' : qualifiedName.substring(0, colon);
    final namespace = namespaces[prefix];
    return (
      _OpenElement(
        qualifiedName: qualifiedName,
        name: qualifiedName.substring(colon + 1),
        namespace: namespace == null || namespace.isEmpty ? null : namespace,
        namespaces: namespaces,
      ),
      selfClosing,
    );
  }

  /// Skips `<!DOCTYPE ...>` (with an internal subset in brackets) and other
  /// declarations.
  void _skipDeclaration() {
    var depth = 0;
    for (var i = _at + 2; i < _source.length; i++) {
      final char = _source[i];
      if (char == '[') depth++;
      if (char == ']') depth--;
      if (char == '>' && depth <= 0) {
        _at = i + 1;
        return;
      }
    }
    throw _error('Unclosed declaration');
  }

  /// The index after the next [end] from [_at].
  int _skipPast(String end) {
    final index = _source.indexOf(end, _at);
    if (index < 0) throw _error('Unclosed $end');
    return index + end.length;
  }

  FormatException _error(String message) =>
      FormatException(message, _source, _at);

  static bool _isSpace(int char) =>
      char == 0x20 || char == 0x09 || char == 0x0a || char == 0x0d;

  static bool _isNameEnd(int char) =>
      _isSpace(char) || char == 0x3e || char == 0x2f; // > /

  static final _entity = RegExp('&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);');

  /// [text] with the predefined entities and character references
  /// decoded; anything else is kept as it is.
  static String _decode(String text) {
    if (!text.contains('&')) return text;
    return text.replaceAllMapped(_entity, (match) {
      final name = match[1]!;
      if (name.startsWith('#')) {
        final code = name.startsWith('#x')
            ? int.tryParse(name.substring(2), radix: 16)
            : int.tryParse(name.substring(1));
        if (code == null || code < 0 || code > 0x10ffff) return match[0]!;
        return String.fromCharCode(code);
      }
      return switch (name) {
        'lt' => '<',
        'gt' => '>',
        'amp' => '&',
        'quot' => '"',
        'apos' => "'",
        _ => match[0]!,
      };
    });
  }
}

class _OpenElement {
  new({
    required this.qualifiedName,
    required this.name,
    required this.namespace,
    required this.namespaces,
  });

  final String qualifiedName;
  final String name;
  final String? namespace;
  final Map<String, String> namespaces;
  final children = <XmlNode>[];
  final text = StringBuffer();

  XmlNode build() => XmlNode(
    namespace: namespace,
    name: name,
    children: List.unmodifiable(children),
    text: text.toString(),
  );
}

/// One resource of a `multistatus` answer: its address and the
/// properties the server found (`200` propstats only).
@immutable
class DavResource {
  const new({
    required this.href,
    this.status,
    this.isCollection = false,
    this.hasResourceType = false,
    this.etag,
    this.contentLength,
  });

  /// The `href`, as the server wrote it (a path or a whole URL,
  /// percent-encoded).
  final String href;

  /// The status of the whole response, when the server gave one instead
  /// of propstats (`HTTP/1.1 404 Not Found`).
  final int? status;

  /// Whether its `resourcetype` holds `collection`: a folder.
  final bool isCollection;

  /// Whether the server listed its `resourcetype` at all (empty: a file).
  final bool hasResourceType;

  /// Its `getetag`, as written (quotes included).
  final String? etag;

  /// Its `getcontentlength`.
  final int? contentLength;
}

/// The resources of the `multistatus` document [body]. Throws a
/// [FormatException] when [body] is not one (not XML, or another root
/// element: an HTML page, a JSON error).
List<DavResource> parseMultistatus(String body) {
  final root = parseXml(body);
  if (!root.isDav('multistatus')) {
    throw FormatException('Not a WebDAV multistatus', root.name);
  }
  return [for (final response in root.dav('response')) ?_resource(response)];
}

DavResource? _resource(XmlNode response) {
  final href = response.firstDav('href')?.allText.trim();
  if (href == null || href.isEmpty) return null;
  var isCollection = false;
  var hasResourceType = false;
  String? etag;
  int? length;
  for (final propstat in response.dav('propstat')) {
    final status = parseDavStatus(propstat.firstDav('status')?.allText);
    // A missing status counts as found: some servers leave it out.
    if (status != null && (status < 200 || status > 299)) continue;
    for (final prop in propstat.dav('prop')) {
      for (final property in prop.children) {
        if (property.isDav('resourcetype')) {
          hasResourceType = true;
          if (property.dav('collection').isNotEmpty) isCollection = true;
        } else if (property.isDav('getetag')) {
          final value = property.allText.trim();
          if (value.isNotEmpty) etag = value;
        } else if (property.isDav('getcontentlength')) {
          length = int.tryParse(property.allText.trim()) ?? length;
        }
      }
    }
  }
  return DavResource(
    href: href,
    status: parseDavStatus(response.firstDav('status')?.allText),
    isCollection: isCollection,
    hasResourceType: hasResourceType,
    etag: etag,
    contentLength: length,
  );
}

/// The code of a WebDAV status line (`HTTP/1.1 200 OK` → 200), or null.
int? parseDavStatus(String? line) {
  if (line == null) return null;
  final match = RegExp(r'^\s*HTTP/\S+\s+(\d{3})').firstMatch(line);
  return match == null ? null : int.parse(match[1]!);
}
