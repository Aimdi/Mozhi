import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/web_translate/core/html_tree.dart';

/// Compact S-expression of [element]'s children.
String outline(HtmlElement element) => element.children
    .map(
      (node) => switch (node) {
        HtmlTextNode(:final text) =>
          text.trim().isEmpty ? '' : '"${text.trim()}"',
        final HtmlElement e => '${e.name}(${outline(e)})',
      },
    )
    .where((s) => s.isNotEmpty)
    .join(' ');

void main() {
  group('parseHtml', () {
    test('builds a tree with void elements', () {
      final doc = parseHtml('<div><p>a<br>b<img src=x></p></div>');
      expect(outline(doc), 'div(p("a" br() "b" img()))');
    });

    test('implicitly closes paragraphs, list items and definitions', () {
      expect(
        outline(parseHtml('<p>a<p>b<div>c</div>')),
        'p("a") p("b") div("c")',
      );
      expect(
        outline(parseHtml('<ul><li>a<li>b<ul><li>c</ul><li>d</ul>')),
        'ul(li("a") li("b" ul(li("c"))) li("d"))',
      );
      expect(
        outline(parseHtml('<dl><dt>a<dd>b<dt>c</dl>')),
        'dl(dt("a") dd("b") dt("c"))',
      );
    });

    test('closes table cells and rows implicitly', () {
      expect(
        outline(parseHtml('<table><tr><td>a<td>b<tr><td>c</table>')),
        'table(tr(td("a") td("b")) tr(td("c")))',
      );
      expect(
        outline(parseHtml('<table><tbody><tr><th>a<td><p>b<tr><td>c</table>')),
        'table(tbody(tr(th("a") td(p("b"))) tr(td("c"))))',
      );
    });

    test('closes headings, options and nested anchors', () {
      expect(outline(parseHtml('<h1>a<h2>b')), 'h1("a") h2("b")');
      expect(outline(parseHtml('<h2>Title<p>Body')), 'h2("Title") p("Body")');
      expect(
        outline(parseHtml('<select><option>a<option>b</select>')),
        'select(option("a") option("b"))',
      );
      expect(outline(parseHtml('<a>x<a>y')), 'a("x") a("y")');
    });

    test('end tags close intervening elements; stray ones are ignored', () {
      expect(
        outline(parseHtml('<div><span><b>a</div>b</span></p>c')),
        'div(span(b("a"))) "bc"',
      );
      expect(
        outline(parseHtml('<b>bold <i>both</b> italic?</i>')),
        'b("bold" i("both")) "italic?"',
      );
    });

    test('end tags do not close past a table cell', () {
      expect(
        outline(
          parseHtml('<div><table><tr><td>a</div>b</td></tr></table>c</div>'),
        ),
        'div(table(tr(td("ab"))) "c")',
      );
    });

    test('merges html/body/head start tags and ignores their end tags', () {
      final doc = parseHtml(
        '<html lang=en><head><title>t</title><body class=a>x</body>'
        '<body id=b>y</html>z',
      );
      expect(outline(doc), 'html(head(title("t")) body("xyz"))');
      expect(doc.find('body')!.attributes, {'class': 'a', 'id': 'b'});
    });

    test('body content closes an unclosed head', () {
      final doc = parseHtml('<head><title>t</title><div>x</div>');
      expect(outline(doc), 'head(title("t")) div("x")');
    });

    test('</br> becomes a line break', () {
      expect(outline(parseHtml('a</br>b')), '"a" br() "b"');
    });

    test('self-closing non-void elements have no children', () {
      expect(outline(parseHtml('<div/>x')), 'div() "x"');
    });

    test('caps the nesting depth', () {
      final html = '${'<div>' * (maxHtmlDepth + 50)}deep';
      final doc = parseHtml(html);
      var depth = 0;
      var node = doc;
      while (node.elementChildren.isNotEmpty) {
        node = node.elementChildren.first;
        depth++;
      }
      expect(depth, lessThanOrEqualTo(maxHtmlDepth));
      expect(doc.textContent, 'deep');
    });

    test('element helpers', () {
      final doc = parseHtml('<div id=a><p>x <b>y</b></p><p>z</p></div>');
      final div = doc.find('div')!;
      expect(div.findAll('p'), hasLength(2));
      expect(div.descendants.map((e) => e.name), ['p', 'b', 'p']);
      expect(div.textContent, 'x yz');
      final b = doc.find('b')!;
      expect(b.hasAncestor((e) => e.attributes['id'] == 'a'), isTrue);
      expect(b.hasAncestor((e) => e.name == 'span'), isFalse);
      expect(doc.find('span'), isNull);
      b.remove();
      expect(div.textContent, 'x z');
      expect(b.parent, isNull);
      expect(b.toString(), 'HtmlElement(b)');
    });
  });
}
