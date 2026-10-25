import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/core/parsers/html_parser.dart';
import 'package:xml/xml.dart';

import '../helpers/document_helpers.dart';

const _page = '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>My  page</title>
  <meta name="description" content="A page about cats">
  <meta name="viewport" content="width=device-width">
  <style>p { color: red; }</style>
  <script>var greeting = "Hello";</script>
</head>
<body>
  <!-- Navigation -->
  <nav><ul>
    <li><a href="/">Home</a></li>
    <li><a href="/about" title="About us">About</a></li>
  </ul></nav>
  <h1>Welcome to <em>our</em> site</h1>
  <p>This is a long
     paragraph with a <a href="https://example.com">link</a>,
     an image <img src="cat.png" alt="A sleepy cat"> and caf&eacute; &amp; more.</p>
  <p>Run <code>npm install</code> first.</p>
  <pre>
  keep   this
  </pre>
  <p translate="no">Mozhi Brand</p>
  <p>Our product <span class="notranslate">Mozhi</span> is free.</p>
  <form><input type="text" placeholder="Your name"><input type="submit" value="Send"></form>
  <p>Line one<br>Line two</p>
  <p>&nbsp;</p>
</body>
</html>
''';

void main() {
  group('parseHtml', () {
    test('round-trips and lists the visible text', () {
      final document = parseHtml(_page, targetLanguage: 'de');
      expect(document.format, DocumentFormat.html);
      expectRoundTrip(document, _page);
      expect(texts(document), [
        'My page',
        'A page about cats',
        'Home',
        'About us',
        'About',
        'Welcome to ⟨1⟩our⟨2⟩ site',
        'A sleepy cat',
        'This is a long paragraph with a ⟨1⟩link⟨2⟩, an image ⟨3⟩ and '
            'café & more.',
        'Run ⟨1⟩ first.',
        'Our product ⟨1⟩ is free.',
        'Your name',
        'Send',
        'Line one⟨1⟩Line two',
      ]);
    });

    test('writes translations back escaped, and sets lang', () {
      final document = parseHtml(_page, targetLanguage: 'de');
      final output = document.render([
        'Meine Seite',
        'Eine Seite über Katzen',
        'Start',
        'Über uns',
        'Über',
        'Willkommen auf ⟨1⟩unserer⟨2⟩ Seite',
        'Eine "schläfrige" Katze',
        'Dies ist ein langer Absatz mit einem ⟨1⟩Link⟨2⟩, einem Bild ⟨3⟩ '
            'und Café & mehr <3.',
        'Führe ⟨1⟩ zuerst aus.',
        'Unser Produkt ⟨1⟩ ist kostenlos.',
        'Dein Name',
        'Senden',
        'Zeile eins⟨1⟩Zeile zwei',
      ]);
      expect(output, contains('<html lang="de">'));
      expect(output, contains('<title>Meine Seite</title>'));
      expect(
        output,
        contains('<meta name="description" content="Eine Seite über Katzen">'),
      );
      expect(output, contains('<li><a href="/">Start</a></li>'));
      expect(output, contains('<a href="/about" title="Über uns">Über</a>'));
      expect(
        output,
        contains('<h1>Willkommen auf <em>unserer</em> Seite</h1>'),
      );
      expect(
        output,
        contains(
          '<p>Dies ist ein langer Absatz mit einem '
          '<a href="https://example.com">Link</a>, einem Bild '
          '<img src="cat.png" alt="Eine &quot;schläfrige&quot; Katze"> '
          'und Café &amp; mehr &lt;3.</p>',
        ),
      );
      expect(
        output,
        contains('<p>Führe <code>npm install</code> zuerst aus.</p>'),
      );
      expect(output, contains('<pre>\n  keep   this\n  </pre>'));
      expect(output, contains('<p translate="no">Mozhi Brand</p>'));
      expect(
        output,
        contains('Unser Produkt <span class="notranslate">Mozhi</span> ist'),
      );
      expect(output, contains('placeholder="Dein Name"'));
      expect(output, contains('value="Senden"'));
      expect(output, contains('<p>Zeile eins<br>Zeile zwei</p>'));
      expect(output, contains('<script>var greeting = "Hello";</script>'));
      expect(output, contains('<!-- Navigation -->'));
    });

    test('repairs inline tags and keeps XHTML well-formed', () {
      const xhtml =
          '<?xml version="1.0" encoding="ISO-8859-1"?>\n'
          '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">'
          '<body><p>Say <b>hello</b> to <i>everyone</i>!</p>'
          '<p>A<br/>B</p></body></html>';
      final document = parseHtml(xhtml, targetLanguage: 'ar');
      expectRoundTrip(document, xhtml);
      final output = document.render([
        '⟨4⟩قل ⟨1⟩مرحبا⟨3⟩ للجميع ⟨2⟩ & هيا',
        null,
      ]);
      expect(output, contains('encoding="UTF-8"'));
      expect(output, contains('xml:lang="ar"'));
      expect(output, contains('lang="ar"'));
      expect(output, contains('dir="rtl"'));
      expect(XmlDocument.parse(output), isNotNull);
    });

    test('keeps a fragment without html element', () {
      const fragment = '<p>Hello <b>world</b></p>\n<div>Bye</div>';
      final document = parseHtml(fragment, targetLanguage: 'fr');
      expectRoundTrip(document, fragment);
      expect(texts(document), ['Hello ⟨1⟩world⟨2⟩', 'Bye']);
      expect(
        document.render(['Bonjour ⟨1⟩monde⟨2⟩', 'Au revoir']),
        '<p>Bonjour <b>monde</b></p>\n<div>Au revoir</div>',
      );
    });
  });

  group('parseHtml (more)', () {
    test('switches a right-to-left page back and fixes legacy charsets', () {
      const page =
          '<html dir="rtl" lang="ar"><head>'
          '<meta http-equiv="Content-Type" content="text/html; '
          'charset=windows-1256">'
          '<meta charset="ISO-8859-6">'
          '<title></title></head>'
          '<body><p>مرحبا</p></body></html>';
      final document = parseHtml(page, targetLanguage: 'en');
      expectRoundTrip(document, page);
      final output = document.render(['Hello']);
      expect(output, startsWith('<html dir="ltr" lang="en">'));
      expect(output, contains('content="text/html; charset=utf-8"'));
      expect(output, contains('<meta charset="utf-8">'));
      expect(output, contains('<p>Hello</p>'));
      // Without translations nothing changes.
      expect(document.render([null]), page);
    });

    test('handles translate="yes", stray tags and unclosed elements', () {
      const page =
          '<div translate="no">Brand <b>X</b> '
          '<span translate="yes">our slogan</span> tail</div>'
          '<p>Stray </b> end</p></i>'
          '<p>Open <code>never closed</p>'
          '<p>Nested <code>a<code>b</code>c</code> done</p>'
          '<p><a href=/x title=Unquoted>Go</a> &copy &foo; &amp more</p>'
          '<p>Bad <b>nesting <i>here</b> end</i></p>'
          '<p>Line<br/>break <span/> x</p>';
      final document = parseHtml(page, targetLanguage: 'de');
      expectRoundTrip(document, page);
      expect(texts(document), [
        'our slogan',
        'Stray ⟨1⟩ end',
        'Open ⟨1⟩',
        'Nested ⟨1⟩ done',
        'Unquoted',
        '⟨1⟩Go⟨2⟩ © ⟨3⟩ & more',
        'Bad ⟨1⟩nesting ⟨2⟩here⟨3⟩ end⟨4⟩',
        'Line⟨1⟩break ⟨2⟩ x',
      ]);
      final output = document.render([
        'unser Slogan',
        'Verirrt ⟨1⟩ Ende',
        'Offen ⟨1⟩',
        'Verschachtelt ⟨1⟩ fertig',
        'Ohne "Anführung"',
        '⟨1⟩Los⟨2⟩ © ⟨3⟩ & mehr',
        '⟨4⟩Schlecht ⟨1⟩verschachtelt ⟨2⟩hier⟨3⟩ Ende',
        'Zeile⟨1⟩Umbruch ⟨2⟩ x',
      ]);
      expect(output, contains('<span translate="yes">unser Slogan</span>'));
      expect(output, contains('Brand <b>X</b>'));
      expect(output, contains('<p>Verirrt </b> Ende</p></i>'));
      expect(output, contains('<code>a<code>b</code>c</code> fertig'));
      expect(
        output,
        contains(
          'title="Ohne &quot;Anführung&quot;">Los</a> © &foo; &amp; mehr',
        ),
      );
      // The source was not nested properly: no repair.
      expect(
        output,
        contains('</i>Schlecht <b>verschachtelt <i>hier</b> Ende'),
      );
      expect(output, contains('<p>Zeile<br/>Umbruch <span/> x</p>'));
    });

    test('keeps a title marked translate="no" and pages without targets', () {
      const page =
          '<html translate="no"><head><title>Keep</title></head>'
          '<body><p translate="yes">Hello</p></body></html>';
      final document = parseHtml(page);
      expectRoundTrip(document, page);
      expect(texts(document), ['Hello']);
      expect(
        document.render(['Hallo']),
        page.replaceFirst('>Hello<', '>Hallo<'),
      );
    });

    test('refuses huge input', () {
      expect(
        () => parseHtml('<p>${'a' * (16 * 1024 * 1024)}</p>'),
        throwsA(isA<DocumentParseException>()),
      );
    });
  });

  test('keeps comments in untranslated blocks and unclosed code', () {
    const page = '<div translate="no">a <!-- c --> b</div><p>Run <code>x';
    final document = parseHtml(page);
    expectRoundTrip(document, page);
    expect(texts(document), ['Run ⟨1⟩']);
    expect(
      document.render(['Lauf ⟨1⟩']),
      '<div translate="no">a <!-- c --> b</div><p>Lauf <code>x',
    );
  });
}
