// HTML fragments are deliberately split into adjacent string literals.
// ignore_for_file: missing_whitespace_between_adjacent_strings, no_adjacent_strings_in_list

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/web_translate/core/charset.dart';
import 'package:mozhi/web_translate/core/readable_extractor.dart';

import '../helpers/fixtures.dart';

const extractor = ReadableExtractor();

List<String> texts(ReadablePage page) => [
  for (final block in page.blocks) block.text,
];

String allText(ReadablePage page) => texts(page).join('\n');

void main() {
  group('ReadableBlockKind', () {
    test('headings', () {
      expect(ReadableBlockKind.heading(1), ReadableBlockKind.heading1);
      expect(ReadableBlockKind.heading(9), ReadableBlockKind.heading6);
      expect(ReadableBlockKind.heading3.isHeading, isTrue);
      expect(ReadableBlockKind.heading3.headingLevel, 3);
      expect(ReadableBlockKind.paragraph.isHeading, isFalse);
      expect(ReadableBlockKind.paragraph.headingLevel, isNull);
    });
  });

  group('ReadableBlock', () {
    test('translatable unless code or blank', () {
      const paragraph = ReadableBlock(
        kind: ReadableBlockKind.paragraph,
        text: 'Hi',
      );
      expect(paragraph.isTranslatable, isTrue);
      expect(
        const ReadableBlock(
          kind: ReadableBlockKind.code,
          text: 'x',
        ).isTranslatable,
        isFalse,
      );
      expect(
        const ReadableBlock(
          kind: ReadableBlockKind.paragraph,
          text: ' ',
        ).isTranslatable,
        isFalse,
      );
      expect(paragraph.copyWith(text: 'Hola').text, 'Hola');
      expect(paragraph.copyWith(), paragraph);
      expect(paragraph.toString(), contains('paragraph'));
    });
  });

  group('ReadableExtractor', () {
    group('news article', () {
      final page = extractor.extract(
        newsArticleHtml,
        baseUri: Uri.parse('https://news.example.com/2025/03/rivers'),
      );

      test('reads title, site name and language', () {
        expect(page.title, 'Rivers return to the city as old canals reopen');
        expect(page.siteName, 'The Daily Ledger');
        expect(page.language, 'en-GB');
      });

      test('keeps the article body in order with block kinds', () {
        final kinds = page.blocks.map((b) => b.kind).toList();
        expect(kinds, contains(ReadableBlockKind.heading2));
        expect(kinds, contains(ReadableBlockKind.quote));
        expect(
          page.blocks.where((b) => b.kind == ReadableBlockKind.listItem),
          hasLength(3),
        );
        final body = texts(page);
        final first = body.indexWhere((t) => t.startsWith('For more than'));
        final heading = body.indexOf('A slow, expensive revival');
        final last = body.indexWhere((t) => t.startsWith('Similar projects'));
        expect(first, isNonNegative);
        expect(heading, greaterThan(first));
        expect(last, greaterThan(heading));
        expect(
          page.blocks.firstWhere((b) => b.kind == ReadableBlockKind.quote).text,
          '“We are not building something new. We are giving back what was '
          'always there.”',
        );
      });

      test('keeps the lead image with its alt text and absolute source', () {
        final image = page.blocks.singleWhere(
          (b) => b.kind == ReadableBlockKind.image,
        );
        expect(image.text, 'Boats on a reopened canal at sunset');
        expect(image.src, 'https://news.example.com/images/canal.jpg');
      });

      test('decodes entities and collapses whitespace', () {
        expect(allText(page), contains('€48 million'));
        expect(allText(page), contains('“daylighted”'));
        expect(allText(page), isNot(contains('  ')));
      });

      test('drops navigation, ads, share bars, scripts and comments', () {
        final text = allText(page);
        for (final junk in [
          'World',
          'Business',
          'Advertisement',
          'Share on',
          'dataLayer',
          'renderAd',
          'Comments',
          'Great news',
          'Most read',
          'morning briefing',
          'All rights reserved',
          'Topics',
          'Read more',
          'Skip to content',
          'NewsArticle',
        ]) {
          expect(text, isNot(contains(junk)), reason: junk);
        }
      });

      test('does not repeat the title as a heading', () {
        expect(
          page.blocks.where((b) => b.kind == ReadableBlockKind.heading1),
          isEmpty,
        );
      });
    });

    group('blog with <main>', () {
      final page = extractor.extract(
        blogWithMainHtml,
        baseUri: Uri.parse('https://blog.example.de/sauerteig'),
      );

      test('uses the h1 as title and the application name', () {
        expect(page.title, 'Sauerteig für Anfänger');
        expect(page.siteName, 'Brot & Code');
        expect(page.language, 'de');
      });

      test('keeps lists with numbers and nesting', () {
        final items = page.blocks
            .where((b) => b.kind == ReadableBlockKind.listItem)
            .toList();
        expect(items.map((b) => b.text), [
          'Roggenmehl (Type 1150)',
          'Lauwarmes Wasser',
          'Leitungswasser reicht',
          'Ein Glas mit Deckel',
        ]);
        expect(items.map((b) => b.number), [1, 2, null, 3]);
        expect(items.map((b) => b.depth), [0, 0, 1, 0]);
      });

      test('keeps code verbatim and line breaks', () {
        final code = page.blocks.singleWhere(
          (b) => b.kind == ReadableBlockKind.code,
        );
        expect(
          code.text,
          'def feed(starter, flour=50, water=50):\n'
          '    starter.weight += flour + water\n'
          '    return starter',
        );
        expect(
          texts(page),
          contains(
            'Nach etwa einer Woche riecht der Starter angenehm säuerlich, und '
            'er verdoppelt sein Volumen in vier bis sechs Stunden.\n'
            'Dann ist er bereit für das erste Brot.',
          ),
        );
      });

      test('inlines emoji images and joins wrapped lines', () {
        expect(
          texts(page),
          contains(
            'Sauerteig klingt kompliziert, ist aber nur Mehl, Wasser und '
            'Geduld. In diesem Beitrag zeige ich, wie ich meinen Starter '
            'füttere 🍞.',
          ),
        );
      });

      test('keeps headings and leaves out the page chrome', () {
        expect(page.blocks.where((b) => b.kind.isHeading).map((b) => b.text), [
          'Was du brauchst',
          'Mein Fütterungsplan',
        ]);
        expect(page.blocks.first.text, 'Veröffentlicht am 3. Mai 2024');
        expect(allText(page), isNot(contains('Archiv')));
        expect(allText(page), isNot(contains('Impressum')));
      });
    });

    test('decodes entity-heavy text', () {
      final page = extractor.extract(entityHeavyHtml);
      expect(page.title, 'Café & Crème');
      expect(texts(page), [
        'Prices: 3 € – 5 € — ½ price after 6 pm.',
        '“Quoted” ‘single’ «guillemets» … © ® ™ °C',
        'Numeric: ABc 😀 😀 – � � �',
        'Legacy without semicolon: © 2024 & more étude AT&T &unknown; &;',
        'Escaped markup: <b>not bold</b> and a lone < sign, plus 5 < 6 and '
            '7 > 3.',
        'Greek αβγ Ω math ≤ ≥ ≠ ∞ →',
      ]);
    });

    test('recovers from malformed nesting', () {
      final page = extractor.extract(malformedHtml);
      expect(page.title, 'Broken page');
      expect(texts(page), [
        'Unclosed things',
        'First paragraph has bold and italic text mixed up.',
        'Second paragraph starts without closing the first.',
        'Item one',
        'Item two with link text inside and more words',
        'Item three',
        'Cell A | Cell B',
        'Cell C | Cell D',
        'Paragraph after list, with a stray end tag here.',
        'Text continues after the stray closing tags, still part of the page '
            'body and readable.',
        'Last words kept.',
      ]);
      expect(page.blocks.first.kind, ReadableBlockKind.heading2);
      expect(page.blocks[1].kind, ReadableBlockKind.paragraph);
      expect(allText(page), isNot(contains('hidden')));
    });

    test('decodes a latin-1 page declared by <meta charset>', () {
      final bytes = latin1.encode(latin1Html);
      final decoded = decodeHtmlBytes(bytes, contentType: 'text/html');
      expect(decoded.charset, 'windows-1252');
      final page = extractor.extract(decoded.text);
      expect(page.title, 'Crème brûlée');
      expect(
        texts(page).first,
        'Für vier Personen: Sahne, Eigelb, Zucker und ein wenig Vanille. '
        'Ça marche très bien, señor Müller!',
      );
      expect(texts(page)[1], contains('150 °C'));
    });

    test('decodes a windows-1251 page declared by http-equiv', () {
      final decoded = decodeHtmlBytes(encodeWindows1251(cyrillicHtml));
      expect(decoded.charset, 'windows-1251');
      final page = extractor.extract(decoded.text);
      expect(page.title, 'Новости');
      expect(
        texts(page).first,
        'Сегодня в городе открылся новый парк. '
        'Жители довольны — «наконец-то!» №1.',
      );
      expect(texts(page)[1], startsWith('Ёлки и ели'));
    });

    test('finds the content by text density without semantic markup', () {
      final page = extractor.extract(densityHtml);
      expect(page.title, 'How tides work');
      expect(page.blocks, hasLength(3));
      expect(texts(page).first, startsWith('Tides are the rise and fall'));
      expect(allText(page), isNot(contains('Previous post')));
      expect(allText(page), isNot(contains('Archive')));
    });

    test('strips the site name from <title>', () {
      expect(
        extractor
            .extract(
              '<title>Ten ways to grow tomatoes | Garden Weekly</title>'
              '<p>Tomatoes like sun.</p>',
            )
            .title,
        'Ten ways to grow tomatoes',
      );
      expect(
        extractor
            .extract(
              '<title>Garden Weekly - Tomatoes</title>'
              '<meta property="og:site_name" content="Garden Weekly">'
              '<p>Tomatoes like sun.</p>',
            )
            .title,
        'Tomatoes',
      );
      expect(
        extractor
            .extract(
              '<title>Tomatoes - Garden Weekly</title>'
              '<meta property="og:site_name" content="Garden Weekly">'
              '<p>Tomatoes like sun.</p>',
            )
            .title,
        'Tomatoes',
      );
      expect(
        extractor.extract('<title>A - B</title><p>Text here.</p>').title,
        'A - B',
      );
    });

    test('uses twitter:title, then the first heading', () {
      expect(
        extractor
            .extract(
              '<meta name="twitter:title" content="From Twitter">'
              '<p>Body text.</p>',
            )
            .title,
        'From Twitter',
      );
      final page = extractor.extract('<h2>Only heading</h2><p>Body text.</p>');
      expect(page.title, 'Only heading');
      expect(texts(page), ['Body text.']);
    });

    test('removes a leading heading equal to the title', () {
      final page = extractor.extract(
        '<title>Same title</title><h2>Same title!</h2><p>Body.</p>',
      );
      expect(page.title, 'Same title');
      expect(texts(page), ['Body.']);
    });

    test('keeps a different h1 as a block', () {
      final page = extractor.extract(
        '<meta property="og:title" content="SEO title">'
        '<p>Intro</p><h1>Real headline</h1><p>Body.</p>',
      );
      expect(page.title, 'SEO title');
      expect(texts(page), ['Intro', 'Real headline', 'Body.']);
    });

    test('ignores svg titles', () {
      final page = extractor.extract(
        '<svg><title>Icon</title></svg><p>Text</p><title>Real</title>',
      );
      expect(page.title, 'Real');
    });

    test('drops hidden elements and ARIA landmarks', () {
      final page = extractor.extract('''
        <div role="navigation">Menu entries</div>
        <div hidden>Hidden text</div>
        <div aria-hidden="true">Decoration</div>
        <div style="display: none">Invisible</div>
        <div style="visibility:hidden">Also invisible</div>
        <p>Visible text stays.</p>
      ''');
      expect(texts(page), ['Visible text stays.']);
    });

    test('prefers the dominant article over teasers', () {
      final long = 'Main story sentence, with commas, and detail. ' * 12;
      final page = extractor.extract('''
        <article><h2>Teaser</h2><p>Short teaser text here.</p></article>
        <article><p>$long</p></article>
        <article><p>Another teaser.</p></article>
      ''');
      expect(texts(page), [long.trim()]);
    });

    test('uses articleBody, then main', () {
      final long = 'Body sentence, with commas, and more words here. ' * 8;
      expect(
        texts(
          extractor.extract(
            '<div>Chrome text outside</div>'
            '<div itemprop="articleBody"><p>$long</p></div>',
          ),
        ),
        [long.trim()],
      );
      expect(
        texts(
          extractor.extract(
            '<div class="x">Chrome text outside</div>'
            '<div role="main"><p>$long</p></div>',
          ),
        ),
        [long.trim()],
      );
    });

    test('does not treat a blog index as one article', () {
      final excerpt = 'An excerpt of a post, with some words, and commas. ' * 3;
      final page = extractor.extract('''
        <title>My blog</title>
        <main>
          <article><h2>Post one</h2><p>$excerpt</p></article>
          <article><h2>Post two</h2><p>$excerpt</p></article>
          <article><h2>Post three</h2><p>$excerpt</p></article>
        </main>
      ''');
      expect(
        page.blocks.where((b) => b.kind == ReadableBlockKind.heading2),
        hasLength(3),
      );
    });

    test('retries without class heuristics when they remove everything', () {
      final page = extractor.extract('''
        <div class="sidebar-layout">
          <p>The only content of this page sits in a container whose class
          name looks like a sidebar, so the strict pass removes it.</p>
        </div>
      ''');
      expect(texts(page).single, startsWith('The only content'));
    });

    test('skips tracking pixels and images without alt text', () {
      final page = extractor.extract('''
        <p>Text before.</p>
        <img src="/pixel.gif" width="1" height="1" alt="tracking">
        <img src="/no-alt.png">
        <img src="data:image/png;base64,AAAA" data-src="/lazy.jpg" alt="Lazy loaded picture">
        <img src="javascript:alert(1)" alt="Bad source image">
        <img src="/small.png" width="16" alt="small icon text">
      ''', baseUri: Uri.parse('https://example.com/a/b'));
      final images = page.blocks
          .where((b) => b.kind == ReadableBlockKind.image)
          .toList();
      expect(images.map((b) => b.text), [
        'Lazy loaded picture',
        'Bad source image',
      ]);
      expect(images.first.src, 'https://example.com/lazy.jpg');
      expect(images.last.src, isNull);
      expect(texts(page).last, 'small icon text');
    });

    test('resolves images against <base href>', () {
      final page = extractor.extract(
        '<base href="https://cdn.example.org/assets/">'
        '<p>Text.</p><img src="pic.jpg" alt="A picture of a cat">',
        baseUri: Uri.parse('https://example.com/post'),
      );
      expect(page.blocks.last.src, 'https://cdn.example.org/assets/pic.jpg');
    });

    test('drops link-only navigation leftovers', () {
      final page = extractor.extract('''
        <p>A real paragraph with a <a href="/x">link</a> inside it.</p>
        <p><a href="/prev">Previous article</a></p>
        <ul><li><a href="/1">Related story</a></li></ul>
      ''');
      expect(texts(page), ['A real paragraph with a link inside it.']);
    });

    test('handles ordered list start/value and quotes with paragraphs', () {
      final page = extractor.extract('''
        <ol start="5"><li>five</li><li value="9">nine</li><li>ten</li></ol>
        <blockquote><p>Line one</p><p>Line two</p></blockquote>
      ''');
      expect(page.blocks.map((b) => b.number), [5, 9, 10, null, null]);
      expect(page.blocks.skip(3).map((b) => b.kind), [
        ReadableBlockKind.quote,
        ReadableBlockKind.quote,
      ]);
    });

    test('numbers only the first block of a multi-paragraph item', () {
      final page = extractor.extract(
        '<ol><li><p>First para</p><p>Second para</p></li></ol>',
      );
      expect(page.blocks.map((b) => b.number), [1, null]);
      expect(page.blocks.map((b) => b.kind), [
        ReadableBlockKind.listItem,
        ReadableBlockKind.listItem,
      ]);
    });

    test('splits layout tables into blocks', () {
      final page = extractor.extract(
        '<table><tr><td><p>Left column text.</p></td>'
        '<td><p>Right column text.</p></td></tr></table>',
      );
      expect(texts(page), ['Left column text.', 'Right column text.']);
    });

    test('removes consecutive duplicates and ignores empty pre', () {
      final page = extractor.extract(
        '<p>Same</p><p>Same</p><pre>  \n </pre><hr><p>Other</p>',
      );
      expect(texts(page), ['Same', 'Other']);
    });

    test('returns an empty page for script-only documents', () {
      final page = extractor.extract(
        '<html><body><div id="app"></div><script>boot()</script></body></html>',
      );
      expect(page.isEmpty, isTrue);
      expect(page.textLength, 0);
      expect(page.title, '');
    });

    test('keeps related siblings of the densest container', () {
      String sentences(int n, int times) =>
          'Sentence $n of the story, with a few commas, and more words. ' *
          times;
      final page = extractor.extract('''
        <div id="wrap">
          <div class="nav-links"><a href="/">Home</a> <a href="/b">Blog</a></div>
          <div class="chunk">
            <p>${sentences(1, 3)}</p><p>${sentences(2, 2)}</p>
            <p>${sentences(3, 2)}</p>
          </div>
          <div class="chunk"><p>${sentences(4, 2)}</p></div>
          <div class="other"><p>${sentences(5, 2)}</p><p>${sentences(6, 1)}</p></div>
          <p>A short closing remark.</p>
        </div>
      ''');
      expect(page.blocks, hasLength(7));
      expect(texts(page).last, 'A short closing remark.');
      expect(allText(page), isNot(contains('Home')));
    });

    test('treats list items outside lists as items', () {
      final page = extractor.extract('<div><li>Orphan item</li></div>');
      expect(page.blocks.single.kind, ReadableBlockKind.listItem);
      expect(page.blocks.single.text, 'Orphan item');
    });

    test('keeps line breaks and markup text inside code', () {
      final page = extractor.extract(
        '<pre><code>a <b>b</b><br>c</code></pre><p>after</p>',
      );
      expect(page.blocks.first.text, 'a b\nc');
      expect(page.blocks.first.kind, ReadableBlockKind.code);
    });

    test('handles empty input', () {
      expect(extractor.extract('').isEmpty, isTrue);
    });

    test('fromPlainText splits paragraphs at blank lines', () {
      final page = ReadableExtractor.fromPlainText(
        'First   line\nsecond line\r\n\r\n\n  Next paragraph  \n\n',
        title: 'notes.txt',
      );
      expect(page.title, 'notes.txt');
      expect(texts(page), ['First line\nsecond line', 'Next paragraph']);
      expect(
        page.blocks.every((b) => b.kind == ReadableBlockKind.paragraph),
        isTrue,
      );
    });

    test('page equality', () {
      expect(
        extractor.extract(entityHeavyHtml),
        extractor.extract(entityHeavyHtml),
      );
    });
  });
}
