// Markup fixtures are built from adjacent strings.
// ignore_for_file: missing_whitespace_between_adjacent_strings
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/core/parsers/icu_inlines.dart';
import 'package:mozhi/documents/core/parsers/json_tree.dart';
import 'package:mozhi/documents/core/parsers/locale_rules.dart';
import 'package:mozhi/documents/core/parsers/markup_content.dart';
import 'package:mozhi/documents/core/parsers/markup_lexer.dart';
import 'package:mozhi/documents/core/parsers/xml_tree.dart';

import '../helpers/document_helpers.dart';

String _join(String source, List<MarkupToken> tokens) =>
    tokens.map((token) => token.raw(source)).join();

void main() {
  group('lexMarkup', () {
    test('covers the input with tokens, whatever it is', () {
      for (final source in [
        '<p class=a id="b" data-x=\'c\' hidden>Hi</p>',
        'a < b and <3 and </> and </ x> end',
        '<!DOCTYPE note [<!ENTITY a "x>y">]><note/>',
        '<?php echo 1; ?><![CDATA[x]]><!-- c -->',
        '<script>if (a<b) {}</script><style>p{}</style>',
        '<title>T &amp; x</title><textarea>raw <b></textarea>',
        '<p a="unterminated',
        '<p a=',
        '<p ',
        '<a <b>',
        '</p',
        '</p a=">',
        '<!-- open',
        '<![CDATA[open',
        '<!DOCTYPE "open',
        '<!DOCTYPE x [ open',
        '<script>never closed',
        '<x:g id="1"/>tail <',
      ]) {
        final html = lexMarkup(source, html: true);
        expect(_join(source, html), source, reason: source);
        final xml = lexMarkup(source, html: false);
        expect(_join(source, xml), source, reason: source);
      }
    });

    test('reads tags and attributes with their positions', () {
      const source = '<IMG SRC="a.png" alt=\'A "cat"\' data-x=y checked/>';
      final token = lexMarkup(source, html: true).single;
      expect(token.kind, MarkupKind.startTag);
      expect(token.name, 'IMG');
      expect(token.lowerName, 'img');
      expect(token.selfClosing, isTrue);
      expect(token.attributes.map((a) => a.name), [
        'SRC',
        'alt',
        'data-x',
        'checked',
      ]);
      final alt = token.attribute('ALT', ignoreCase: true)!;
      expect(alt.quote, "'");
      expect(alt.rawValue(source), 'A "cat"');
      expect(token.attribute('data-x')!.quote, '');
      expect(token.attribute('checked')!.hasValue, isFalse);
      expect(token.attribute('checked')!.rawValue(source), '');
      expect(token.attribute('nope'), isNull);
      expect(lexMarkup('<xliff:g id="1"/>', html: false).single.localName, 'g');
    });

    test('reads raw text elements and processing instructions', () {
      const source = '<script>a</b></SCRIPT><?pi a > b?>';
      final html = lexMarkup(source, html: true);
      expect(html.map((token) => token.kind), [
        MarkupKind.startTag,
        MarkupKind.rawText,
        MarkupKind.endTag,
        MarkupKind.processing,
        MarkupKind.text,
      ]);
      final xml = lexMarkup(source, html: false);
      expect(xml.last.kind, MarkupKind.processing);
      expect(xml.last.raw(source), '<?pi a > b?>');
    });
  });

  group('references and escaping', () {
    test('decodes character references', () {
      expect(decodeReference('&amp;', html: false), '&');
      expect(decodeReference('&eacute;', html: false), isNull);
      expect(decodeReference('&eacute;', html: true), 'é');
      expect(decodeReference('&#233;', html: false), 'é');
      expect(decodeReference('&#xE9;', html: false), 'é');
      expect(decodeReference('&#xE9', html: false), isNull);
      expect(decodeReference('&#xE9', html: true), 'é');
      expect(decodeReference('&#0;', html: true), isNull);
      expect(decodeReference('&#xD800;', html: true), isNull);
      expect(decodeReference('&#x;', html: true), isNull);
      expect(decodeReference('&copy', html: true), '©');
      expect(decodeReference('&copy', html: false), isNull);
      expect(decodeReference('&zzz', html: true), isNull);
      expect(decodeReference('&a', html: true), isNull);
      expect(
        decodeAttributeValue('a &amp; b &x; c', html: false),
        'a & b &x; c',
      );
      expect(decodeAttributeValue('plain', html: false), 'plain');
    });

    test('splits text into decoded pieces and codes', () {
      const source = 'A&amp;B&nbsp;C &#8203; &foo; &bar AT&T  x';
      final html = textInlines(
        source,
        0,
        source.length,
        html: true,
        collapse: true,
      );
      expect(
        [
          for (final item in html)
            switch (item) {
              InlineText(:final source, :final text) => 'T($source|$text)',
              InlineCode(:final nodes) => 'C(${identityText(nodes)})',
            },
        ],
        [
          'T(A|A)',
          'T(&amp;|&)',
          'T(B|B)',
          'C(&nbsp;)',
          'T(C |C )',
          'C(&#8203;)',
          'T( | )',
          'C(&foo;)',
          'T( | )',
          'T(&bar|&bar)',
          'T( AT| AT)',
          'T(&T|&T)',
          'T(  | )',
          'T(x|x)',
        ],
      );
      final xml = textInlines('a &bar b', 0, 8, html: false);
      expect(xml.whereType<InlineCode>(), isEmpty);
    });

    test('protects patterns across decoded text, never inside references', () {
      const source = 'Use &lt;b&gt;bold&lt;/b&gt;  now';
      final inlines = protectInlines(
        textInlines(source, 0, source.length, html: true, collapse: true),
        RegExp('<b>|> n'),
      );
      final codes = [
        for (final item in inlines)
          if (item is InlineCode) identityText(item.nodes),
      ];
      expect(codes, ['&lt;b&gt;', '&gt;  n']);
      expect(protectInlines(inlines, null), same(inlines));

      // A match is widened to whole references.
      final widened = protectInlines([
        const InlineText('a'),
        const InlineText('&xy;', 'xy'),
        const InlineText('b'),
        InlineCode.text('<br>'),
        const InlineText('c'),
      ], RegExp('yb|c'));
      expect(
        [
          for (final item in widened)
            switch (item) {
              InlineText(:final source) => 'T($source)',
              InlineCode(:final nodes) => 'C(${identityText(nodes)})',
            },
        ],
        ['T(a)', 'C(&xy;b)', 'C(<br>)', 'C(c)'],
      );
    });

    test('escapes text and attributes', () {
      expect(escapeMarkupText('a < b & c > d'), 'a &lt; b &amp; c &gt; d');
      expect(escapeMarkupText('plain'), 'plain');
      expect(
        escapeMarkupAttribute('say "hi"\nnow', '"'),
        'say &quot;hi&quot; now',
      );
      expect(escapeMarkupAttribute("it's <", "'"), 'it&#39;s &lt;');
      expect(escapeCdata('a]]>b'), 'a]]]]><![CDATA[>b');
    });
  });

  group('repairInlineTags', () {
    test('drops stray end tags and closes open elements', () {
      expect(repairInlineTags('a</b>c', html: false), 'ac');
      expect(repairInlineTags('<b>a', html: false), '<b>a</b>');
      expect(
        repairInlineTags('<b><i>x</b>y</i>', html: false),
        '<b><i>x</i></b>y',
      );
      expect(repairInlineTags('<B>x</b>', html: true), '<B>x</b>');
      expect(
        repairInlineTags('<br><img src=x>ok', html: true),
        '<br><img src=x>ok',
      );
      expect(
        repairInlineTags('<x/>ok<!-- c -->', html: false),
        '<x/>ok<!-- c -->',
      );
    });
  });

  group('setAttributes', () {
    test('replaces values in place and adds missing ones', () {
      const source = "<html lang='en' dir=ltr hidden>";
      final tag = lexMarkup(source, html: true).single;
      expect(
        setAttributes(source, tag, {
          'lang': 'de',
          'dir': 'rtl',
          'hidden': 'yes',
          'xml:lang': 'a"b',
        }),
        '<html lang=\'de\' dir="rtl" hidden="yes" xml:lang="a&quot;b">',
      );
      const bare = '<segment>';
      expect(
        setAttributes(bare, lexMarkup(bare, html: false).single, {
          'state': 'translated',
        }),
        '<segment state="translated">',
      );
    });

    test('changes a prefix only once something is translated', () {
      final builder = DocumentBuilder();
      final children = [
        const TextNode('<p>'),
        ...builder.content([const TextPiece('Hi')]),
      ];
      expect(
        replacePrefixWhenTranslated(children, '<p>', '<p>'),
        same(children),
      );
      expect(replacePrefixWhenTranslated([const TextNode('x')], 'x', 'y'), [
        isA<TextNode>(),
      ]);
      final nodes = replacePrefixWhenTranslated(children, '<p>', '<q>');
      builder.add(nodes);
      final document = builder.build(DocumentFormat.html);
      expect(document.render(), '<p>Hi');
      expect(document.render(['Hallo']), '<q>Hallo');
    });
  });

  group('locale rules', () {
    test('canonicalises and compares language tags', () {
      expect(canonicalLanguageTag('pt_br'), 'pt-BR');
      expect(canonicalLanguageTag('ZH-hans-tw'), 'zh-Hans-TW');
      expect(canonicalLanguageTag('es-419'), 'es-419');
      expect(canonicalLanguageTag('sl-rozaj'), 'sl-rozaj');
      expect(canonicalLanguageTag('Pirate speak'), isNull);
      expect(canonicalLanguageTag(null), isNull);
      expect(sameLanguage('de', 'de_DE'), isTrue);
      expect(sameLanguage('de-AT', 'de-DE'), isFalse);
      expect(sameLanguage('zh-Hans', 'zh-Hant'), isFalse);
      expect(sameLanguage('Klingon!', 'klingon!'), isTrue);
      expect(isRightToLeft('ar'), isTrue);
      expect(isRightToLeft('fa-IR'), isTrue);
      expect(isRightToLeft('az-Arab'), isTrue);
      expect(isRightToLeft('ku-Latn'), isFalse);
      expect(isRightToLeft('de'), isFalse);
      expect(isRightToLeft('???'), isFalse);
    });

    test('knows plural categories and gettext plural forms', () {
      expect(pluralCategories('ja'), ['other']);
      expect(pluralCategories('ru-RU'), ['one', 'few', 'many', 'other']);
      expect(pluralCategories('xx'), isNull);
      expect(pluralCategories('???'), isNull);
      expect(gettextPluralForms('pt-PT'), 'nplurals=2; plural=(n != 1);');
      expect(gettextPluralForms('pt-BR'), 'nplurals=2; plural=(n > 1);');
      expect(gettextPluralForms('xx'), isNull);
      expect(gettextPluralForms(null), isNull);
    });

    test('evaluates plural expressions', () {
      int form(String language, int n) =>
          PluralForms.parse(gettextPluralForms(language))!.formFor(n);
      expect(
        [
          for (final n in [1, 2, 5, 11, 21, 22, 25]) form('ru', n),
        ],
        [0, 1, 2, 2, 0, 1, 2],
      );
      expect(
        [
          for (final n in [0, 1, 2, 3, 11, 100]) form('ar', n),
        ],
        [0, 1, 2, 3, 4, 5],
      );
      expect(
        [
          for (final n in [1, 2, 5]) form('cs', n),
        ],
        [0, 1, 2],
      );
      expect(
        [
          for (final n in [0, 1, 2]) form('fr', n),
        ],
        [0, 0, 1],
      );
      expect(form('ja', 7), 0);
      expect(
        [
          for (final n in [1, 11, 21]) form('is', n),
        ],
        [0, 1, 0],
      );
      expect(
        [
          for (final n in [1, 2, 3, 6, 9]) form('cy', n),
        ],
        [1, 2, 3, 4, 5],
      );
      expect(
        [
          for (final n in [1, 2, 4, 5]) form('sl', n),
        ],
        [0, 1, 2, 3],
      );

      final custom = PluralForms.parse(
        'nplurals=3; plural=!(n - 1) ? 0 : n * 2 / 4 >= 2 ? 1 : n <= -1 ? 9 : 2;',
      )!;
      expect(custom.count, 3);
      expect(
        [
          for (final n in [1, 4, 3, -1]) custom.formFor(n),
        ],
        [0, 1, 2, 2],
      );
      expect(
        PluralForms.parse('nplurals=2; plural=n / 0 + n % 0;')!.formFor(3),
        0,
      );
      for (final bad in [
        null,
        'nplurals=INTEGER; plural=EXPRESSION;',
        'nplurals=0; plural=0;',
        'nplurals=2; plural=(n;',
        'nplurals=2; plural=n ? 1;',
        'nplurals=2; plural=x;',
        'nplurals=2; plural=n n;',
        'nplurals=2; plural=n +;',
      ]) {
        expect(PluralForms.parse(bad), isNull, reason: bad);
      }
    });

    test('linear patterns match what the shared ones match', () {
      List<(int, int)> spans(RegExp pattern, String text) => [
        for (final match in pattern.allMatches(text)) (match.start, match.end),
      ];
      const texts = [
        '<b>bold</b> and <a href="x">link</a> <br/> <br /> <img alt=x>',
        '<p\nclass="x"> <a/b> <x:y z="1"> </ b> <1a> < a> <a\t>',
        '<!-- note --> text <!----> <!-- a -- b --> <a <b>',
        r'%05d %-05d %00012d %1$05.2f %(n)05d %s %.2f %10s %0s %+0#5x',
        'see ![alt](img.png) and ![a](b(c)d "t") [^1] [x](y) <http://a.b>',
        r'<a@b.c> $$x$$ `code` ``co`de`` [a](b) ![x](y)',
        'mail me: a.b@example.com, www.example.com/x. https://a.b/(c)',
        r'&amp; &#160; &#x2014; {{name}} ${x} $t(key) @:key {0} {name}',
      ];
      for (final text in texts) {
        for (final (fast, slow) in [
          (
            ProtectedPatterns.combine([LocalisationPatterns.htmlTag]),
            ProtectedPatterns.combine([ProtectedPatterns.htmlTag]),
          ),
          (LocalisationPatterns.json, ProtectedPatterns.json),
          (LocalisationPatterns.markdown, ProtectedPatterns.markdown),
        ]) {
          expect(spans(fast, text), spans(slow, text), reason: text);
        }
      }
      final printf = RegExp(LocalisationPatterns.printf);
      final python = RegExp(LocalisationPatterns.pythonNamed);
      for (final spec in ['%05d', '%-05d', '%00012d', r'%1$05.2f', '%0s']) {
        expect(printf.stringMatch('x $spec y'), spec, reason: spec);
      }
      expect(python.stringMatch('a %(n)05d'), '%(n)05d');
      // A comment never contains `<!--`: the inner one is the comment.
      final tag = RegExp(LocalisationPatterns.htmlTag);
      expect(tag.stringMatch('<!-- a <!-- b -->'), '<!-- b -->');
    });

    test('protects format specifiers', () {
      final printf = RegExp(LocalisationPatterns.printf);
      final inText = RegExp(LocalisationPatterns.printfInText);
      for (final spec in [
        '%s',
        r'%1$d',
        '%.2f',
        '%lld',
        '%@',
        '%%',
        '%#@files@',
        '%arg',
      ]) {
        expect(printf.stringMatch('x $spec y'), spec, reason: spec);
      }
      expect(inText.hasMatch('50%off'), isFalse);
      expect(inText.stringMatch(r'%1$sMB'), r'%1$s');
      expect(inText.stringMatch('%@x'), '%@');
      expect(
        RegExp(LocalisationPatterns.pythonNamed).stringMatch('a %(name)s'),
        '%(name)s',
      );
      expect(
        RegExp(LocalisationPatterns.braces).stringMatch('{0:.2f}'),
        '{0:.2f}',
      );
      expect(RegExp(LocalisationPatterns.qt).stringMatch('%L1 of'), '%L1');
    });
  });

  group('parseXmlTree', () {
    test('reads elements, attributes and text', () {
      const source =
          '﻿ <?xml version="1.0"?><a x="1 &amp; 2" p:y="3">t<b/>'
          '<![CDATA[<c>]]><!-- c --></a>';
      final tree = parseXmlTree(source, format: 'Test');
      expect(tree.declaration!.raw(source), '<?xml version="1.0"?>');
      expect(tree.root.name, 'a');
      expect(tree.root.attribute(source, 'x'), '1 & 2');
      expect(tree.root.attribute(source, 'z'), isNull);
      expect(tree.root.localAttribute(source, 'y'), '3');
      expect(tree.root.localAttribute(source, 'z'), isNull);
      expect(tree.root.child('b'), isNotNull);
      expect(tree.root.child('c'), isNull);
      expect(tree.root.textContent(source), 't<c>');
    });

    test('refuses entities, deep nesting, size and bad XML', () {
      expect(
        () => parseXmlTree(
          '<!DOCTYPE a [<!ENTITY x SYSTEM "file:///etc/passwd">]><a>&x;</a>',
          format: 'Test',
        ),
        throwsA(
          isA<DocumentParseException>().having(
            (error) => error.message,
            'message',
            contains('entity'),
          ),
        ),
      );
      expect(
        () => parseXmlTree('${'<a>' * 300}${'</a>' * 300}', format: 'Test'),
        throwsA(
          isA<DocumentParseException>().having(
            (error) => error.message,
            'message',
            contains('deeply'),
          ),
        ),
      );
      expect(
        () =>
            parseXmlTree('<a>${'x' * (16 * 1024 * 1024)}</a>', format: 'Test'),
        throwsA(isA<DocumentParseException>()),
      );
      expect(
        () => parseXmlTree('<a>\n<b></a>', format: 'Test'),
        throwsA(
          isA<DocumentParseException>().having(
            (error) => error.message,
            'message',
            startsWith('Test: '),
          ),
        ),
      );
      expect(
        () => parseXmlTree('<a></a><b/>', format: 'Test'),
        throwsA(isA<DocumentParseException>()),
      );
    });
  });

  group('parseJsonTree', () {
    test('keeps positions and refuses deep nesting', () {
      const source = '﻿{"a": [1, {"b": "c"}], "d": {}, "e": []}';
      final root = parseJsonTree(source, format: 'Test') as JsonObject;
      expect(root.member('a')!.keyStart, source.indexOf('"a"'));
      final array = root['a']! as JsonArray;
      expect(array.items.first, isA<JsonLiteral>());
      expect(((array.items.last as JsonObject)['b']! as JsonString).value, 'c');
      expect(root['missing'], isNull);
      expect(
        () => parseJsonTree('${'[' * 100}${']' * 100}', format: 'Test'),
        throwsA(isA<DocumentParseException>()),
      );
      expect(
        () => parseJsonTree('{', format: 'Test'),
        throwsA(isA<DocumentParseException>()),
      );
    });
  });

  group('more helpers', () {
    test('reads spaced attributes and quoted end tags', () {
      const source = '<p a = "1" b= 2></p a=">">';
      final tokens = lexMarkup(source, html: true);
      expect(tokens.first.attribute('a')!.rawValue(source), '1');
      expect(tokens.first.attribute('b')!.rawValue(source), '2');
      expect(tokens.last.kind, MarkupKind.endTag);
      expect(tokens.last.end, source.length);
    });

    test('repairs around CDATA and instructions', () {
      expect(
        repairInlineTags('<![CDATA[x]]><?pi?><!DOCTYPE y><b>z', html: false),
        '<![CDATA[x]]><?pi?><!DOCTYPE y><b>z</b>',
      );
    });

    test('reads processing instructions and doctypes in the tree', () {
      const source = '<!DOCTYPE a><a><?pi x?></a>';
      final tree = parseXmlTree(source, format: 'Test');
      expect(tree.root.children.single, isA<MarkupToken>());
      expect(tree.declaration, isNull);
    });

    test('rejects operators where a value belongs', () {
      expect(PluralForms.parse('nplurals=2; plural=*n;'), isNull);
    });

    test('flags binary formats', () {
      expect(DocumentFormat.docx.isBinary, isTrue);
      expect(DocumentFormat.html.isBinary, isFalse);
      expect(
        DocumentFormat.sniff('<x:xliff xmlns:x="urn:x"/>'),
        DocumentFormat.xliff,
      );
    });
  });

  group('icuInlines', () {
    List<DocNode> variant(DocumentBuilder builder, List<Inline> inlines) =>
        inlineContent(builder, inlines);

    String describe(List<Inline> inlines) => [
      for (final item in inlines)
        switch (item) {
          InlineText(:final source) => source,
          InlineCode(:final nodes) => '[${identityText(nodes)}]',
        },
    ].join();

    test('reads simple, typed and nested arguments', () {
      final builder = DocumentBuilder();
      final inlines = icuInlines(
        [
          const InlineText(
            '{n, plural, offset:1 =0 {none} other {{n, number} and {who} '
            '{{x}}}} {d, date, short}',
          ),
        ],
        builder,
        (items) => variant(builder, items),
      );
      expect(
        describe(inlines),
        '[{n, plural, offset:1 =0 {none} other {{n, number} and {who} '
        '{{x}}}}] [{d, date, short}]',
      );
      expect(texts(builder.build(DocumentFormat.xliff)), [
        'none',
        '⟨1⟩ and ⟨2⟩ ⟨3⟩',
      ]);
    });

    test('keeps the inlines when the syntax is broken', () {
      for (final broken in [
        '{n, plural, other {x}',
        '{n, plural, other {x}}}',
        '{n, plural, }',
        '{n, plural, other x}',
        '{n, plural, {x}}',
        '{n, plural other {x}}',
        '{, plural, other {x}}',
        '{n, plural, other {{{x}}',
        '{n, number {x}, plural, other {y}}',
        '{n, plural, other {x}} {a',
        '{n, plural, other {x}} {a b}',
      ]) {
        final inlines = [InlineText(broken)];
        final result = icuInlines(
          inlines,
          DocumentBuilder(),
          (items) => const [],
        );
        expect(result, same(inlines), reason: broken);
      }
    });

    test('keeps codes inside arguments', () {
      final builder = DocumentBuilder();
      final inlines = icuInlines(
        [
          const InlineText('{n, plural, other {# '),
          InlineCode.text('<x/>'),
          const InlineText(' items}} {a, select, b {c'),
          const InlineText('&amp;', '&'),
          const InlineText('}} {m, number, '),
          InlineCode.text('<y/>'),
          const InlineText('}'),
        ],
        builder,
        (items) => variant(builder, items),
      );
      expect(
        describe(inlines),
        '[{n, plural, other {# <x/> items}}] '
        '[{a, select, b {c&amp;}}] [{m, number, <y/>}]',
      );
      expect(texts(builder.build(DocumentFormat.xliff)), [
        '⟨1⟩ ⟨2⟩ items',
        'c&',
      ]);
    });
  });
}
