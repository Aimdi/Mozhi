/// A minimal DOM built from [tokenizeHtml] tokens with the HTML 5 recovery
/// rules that matter for reading: void elements, implied end tags
/// (`<p>`, `<li>`, `<dt>`/`<dd>`, table cells, headings, options),
/// end tags that close intervening elements, stray end tags that are
/// ignored, and a nesting depth cap.
library;

import 'package:mozhi/web_translate/core/html_tokenizer.dart';

/// A node of the tree.
sealed class HtmlNode {
  HtmlElement? parent;
}

/// Character data.
final class HtmlTextNode extends HtmlNode {
  new(this.text);

  String text;
}

/// An element with lower-case [name] and attributes.
final class HtmlElement extends HtmlNode {
  new(this.name, [Map<String, String>? attributes])
    : attributes = attributes ?? {};

  final String name;
  final Map<String, String> attributes;
  final List<HtmlNode> children = [];

  /// Child elements only.
  Iterable<HtmlElement> get elementChildren => children.whereType();

  /// Pre-order traversal of the descendant elements (not this one).
  Iterable<HtmlElement> get descendants sync* {
    final stack = <HtmlElement>[...elementChildren.toList().reversed];
    while (stack.isNotEmpty) {
      final element = stack.removeLast();
      yield element;
      stack.addAll(element.elementChildren.toList().reversed);
    }
  }

  /// First descendant element named [tag], else null.
  HtmlElement? find(String tag) {
    for (final element in descendants) {
      if (element.name == tag) return element;
    }
    return null;
  }

  /// All descendant elements named [tag], in document order.
  Iterable<HtmlElement> findAll(String tag) =>
      descendants.where((element) => element.name == tag);

  /// Concatenated character data of the subtree (no whitespace handling).
  String get textContent {
    final buffer = StringBuffer();
    void visit(HtmlElement element) {
      for (final child in element.children) {
        switch (child) {
          case HtmlTextNode(:final text):
            buffer.write(text);
          case final HtmlElement element:
            visit(element);
        }
      }
    }

    visit(this);
    return buffer.toString();
  }

  /// Whether an ancestor of this element satisfies [test].
  bool hasAncestor(bool Function(HtmlElement element) test) {
    for (var node = parent; node != null; node = node.parent) {
      if (test(node)) return true;
    }
    return false;
  }

  void append(HtmlNode node) {
    node.parent = this;
    children.add(node);
  }

  /// Detaches this element from its parent.
  void remove() {
    parent?.children.remove(this);
    parent = null;
  }

  @override
  String toString() => 'HtmlElement($name)';
}

/// Elements that never have content.
const voidElements = {
  'area',
  'base',
  'br',
  'col',
  'embed',
  'hr',
  'img',
  'input',
  'keygen',
  'link',
  'meta',
  'param',
  'source',
  'track',
  'wbr',
  'image',
};

/// Start tags that implicitly close an open `<p>`.
const _closesParagraph = {
  'address',
  'article',
  'aside',
  'blockquote',
  'center',
  'details',
  'dialog',
  'dir',
  'div',
  'dl',
  'fieldset',
  'figcaption',
  'figure',
  'footer',
  'form',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'header',
  'hgroup',
  'hr',
  'li',
  'main',
  'menu',
  'nav',
  'ol',
  'p',
  'pre',
  'section',
  'summary',
  'table',
  'ul',
  'dd',
  'dt',
};

const _headings = {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'};

/// Block start tags that close an open heading (see [parseHtml]).
const _closesHeading = {
  'p',
  'ul',
  'ol',
  'dl',
  'table',
  'blockquote',
  'pre',
  'hr',
  'article',
  'section',
  'main',
};

/// Elements that may appear in <head> (anything else closes it).
const _headContent = {
  'head',
  'html',
  'title',
  'meta',
  'link',
  'style',
  'script',
  'base',
  'noscript',
  'template',
};

/// Elements that stop the search for an element to close implicitly.
const _scopeBoundaries = {
  'html',
  'body',
  'table',
  'td',
  'th',
  'caption',
  'button',
  'object',
  'template',
  'marquee',
  'applet',
};

/// Maximum element nesting; deeper elements are flattened into their
/// ancestor so that pathological input cannot exhaust the stack.
const maxHtmlDepth = 256;

/// Parses [html] into a tree rooted at a `#document` element.
HtmlElement parseHtml(String html) {
  final document = HtmlElement('#document');
  final stack = <HtmlElement>[document];

  HtmlElement current() => stack.last;

  /// Index in [stack] of the nearest open [names] element, searching
  /// down to (not past) a scope boundary; -1 when absent.
  int openIndex(Set<String> names, {Set<String> boundaries = const {}}) {
    for (var i = stack.length - 1; i > 0; i--) {
      final name = stack[i].name;
      if (names.contains(name)) return i;
      if (_scopeBoundaries.contains(name) || boundaries.contains(name)) {
        return -1;
      }
    }
    return -1;
  }

  void popTo(int index) {
    if (index > 0) stack.removeRange(index, stack.length);
  }

  for (final token in tokenizeHtml(html)) {
    switch (token) {
      case HtmlCharacters(:final text):
        final parent = current();
        final last = parent.children.isEmpty ? null : parent.children.last;
        if (last is HtmlTextNode) {
          last.text += text;
        } else {
          parent.append(HtmlTextNode(text));
        }

      case HtmlStartTag(:final name, :final attributes, :final selfClosing):
        if (name == 'html' || name == 'body' || name == 'head') {
          final existing = _openNamed(stack, name);
          if (existing != null) {
            attributes.forEach(
              (key, value) => existing.attributes.putIfAbsent(key, () => value),
            );
            continue;
          }
        }
        // Body content closes an open <head> (missing </head>).
        if (!_headContent.contains(name)) {
          final head = stack.indexWhere((e) => e.name == 'head');
          if (head > 0) popTo(head);
        }
        if (_closesParagraph.contains(name)) {
          popTo(openIndex(const {'p'}));
        }
        // Deliberately unlike browsers: block content closes an unclosed
        // heading, so that a missing </h2> does not turn the rest of the
        // page into one heading.
        if (_closesHeading.contains(name)) {
          popTo(openIndex(_headings));
        }
        switch (name) {
          case 'li':
            popTo(openIndex(const {'li'}, boundaries: const {'ul', 'ol'}));
          case 'dt' || 'dd':
            popTo(openIndex(const {'dt', 'dd'}, boundaries: const {'dl'}));
          case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
            if (_headings.contains(current().name)) stack.removeLast();
          case 'option':
            if (current().name == 'option') stack.removeLast();
          case 'tr':
            // Closes the open row (and its cells) of the same table.
            for (var i = stack.length - 1; i > 0; i--) {
              final open = stack[i].name;
              if (open == 'tr') {
                popTo(i);
                break;
              }
              if (open == 'table' ||
                  open == 'tbody' ||
                  open == 'thead' ||
                  open == 'tfoot') {
                break;
              }
            }
          case 'td' || 'th':
            final cell = openIndex(const {'td', 'th', 'tr'});
            if (cell > 0 && stack[cell].name != 'tr') popTo(cell);
          case 'a':
            popTo(openIndex(const {'a'}));
        }
        final element = HtmlElement(name, attributes);
        current().append(element);
        if (!selfClosing &&
            !voidElements.contains(name) &&
            stack.length < maxHtmlDepth) {
          stack.add(element);
        }

      case HtmlEndTag(:final name):
        if (name == 'body' || name == 'html') continue;
        if (name == 'br') {
          current().append(HtmlElement('br'));
          continue;
        }
        for (var i = stack.length - 1; i > 0; i--) {
          final open = stack[i].name;
          if (open == name) {
            popTo(i);
            break;
          }
          // An end tag never closes past the table cell it appears in.
          if ((open == 'td' || open == 'th') && !_tableParts.contains(name)) {
            break;
          }
        }
    }
  }
  return document;
}

const _tableParts = {'td', 'th', 'tr', 'tbody', 'thead', 'tfoot', 'table'};

HtmlElement? _openNamed(List<HtmlElement> stack, String name) {
  for (final element in stack) {
    if (element.name == name) return element;
  }
  return null;
}
