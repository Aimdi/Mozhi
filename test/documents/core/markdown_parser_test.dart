import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';

import '../helpers/document_helpers.dart';

void main() {
  group('parseMarkdown', () {
    test('translates headings and paragraphs, keeping markers', () {
      const text =
          '# Title #\n'
          '\n'
          'First paragraph\n'
          'continues here.\n'
          '\n'
          '## Sub heading\n';
      final document = parseMarkdown(text);
      expect(document.format, DocumentFormat.markdown);
      expect(texts(document), [
        'Title',
        'First paragraph\ncontinues here.',
        'Sub heading',
      ]);
      expectRoundTrip(document, text);
      expect(
        renderUpper(document),
        '# TITLE #\n\nFIRST PARAGRAPH\nCONTINUES HERE.\n\n## SUB HEADING\n',
      );
    });

    test('keeps closing sequences of headings', () {
      const text =
          '# Title ##  \n'
          '## Title#\n'
          '### C# and F#\n'
          '#### Spaced   #\t\n'
          '##### ##\n';
      final document = parseMarkdown(text);
      expect(texts(document), ['Title', 'Title#', 'C# and F#', 'Spaced']);
      expectRoundTrip(document, text);
      expect(
        renderUpper(document),
        '# TITLE ##  \n## TITLE#\n### C# AND F#\n#### SPACED   #\t\n'
        '##### ##\n',
      );
    });

    test('never translates fenced, tilde and indented code blocks', () {
      const text =
          'Intro\n'
          '\n'
          '```dart\n'
          'print("Hello world");\n'
          '\n'
          'var x = 1;\n'
          '```\n'
          '\n'
          '~~~~\n'
          'Some ``` inside\n'
          '~~~~\n'
          '\n'
          '    indented code here\n'
          '    more code\n'
          '\n'
          'Outro\n';
      final document = parseMarkdown(text);
      expect(texts(document), ['Intro', 'Outro']);
      expectRoundTrip(document, text);
    });

    test('tab-indented code after a blank line stays verbatim', () {
      const text = 'Intro\n\n\tcode here\n  \tmore code\n\nOutro';
      final document = parseMarkdown(text);
      expect(texts(document), ['Intro', 'Outro']);
      expectRoundTrip(document, text);
    });

    test('unterminated fences run to the end of the document', () {
      const text = 'Text\n```\ncode only\n';
      final document = parseMarkdown(text);
      expect(texts(document), ['Text']);
      expectRoundTrip(document, text);
    });

    test('protects inline code, URLs, link targets and images', () {
      const text =
          'Run `flutter test` or see [the docs](https://docs.flutter.dev '
          '"Docs") and ![logo](img/logo.png). Visit https://x.dev, or '
          '<https://auto.link>.\n';
      final document = parseMarkdown(text);
      expect(texts(document), [
        'Run ⟨1⟩ or see [the docs]⟨2⟩ and ⟨3⟩. Visit ⟨4⟩, or ⟨5⟩.',
      ]);
      expectRoundTrip(document, text);
      expect(
        document.render([
          'Ejecuta ⟨1⟩ o mira [la documentación] ⟨2⟩ y ⟨3⟩. Visita ⟨4⟩, o ⟨5⟩.',
        ]),
        'Ejecuta `flutter test` o mira '
        '[la documentación](https://docs.flutter.dev "Docs") y '
        '![logo](img/logo.png). Visita https://x.dev, o <https://auto.link>.\n',
      );
    });

    test('keeps reference links, footnotes, HTML and entities', () {
      const text =
          'See [this][ref] and a note[^1]. Bold<br>text&nbsp;here.\n'
          '\n'
          '[ref]: https://example.com "Title"\n'
          '[^1]: The footnote text.\n';
      final document = parseMarkdown(text);
      expect(texts(document), [
        'See [this]⟨1⟩ and a note⟨2⟩. Bold⟨3⟩text⟨4⟩here.',
        'The footnote text.',
      ]);
      expectRoundTrip(document, text);
    });

    test('lists keep bullets, numbering, task boxes and nesting', () {
      const text =
          '- First item\n'
          '  continued line\n'
          '- [x] Done task\n'
          '  - Nested item\n'
          '1. Numbered\n'
          '2) Other style\n'
          '* \n'
          '+ Plus item\n';
      final document = parseMarkdown(text);
      expect(texts(document), [
        'First item\ncontinued line',
        'Done task',
        'Nested item',
        'Numbered',
        'Other style',
        'Plus item',
      ]);
      expectRoundTrip(document, text);
      expect(
        document.render([
          'Erstes\nfortgesetzt\nnoch mehr',
          'Erledigt',
          'Verschachtelt',
          'Nummeriert',
          'Anders',
          'Plus',
        ]),
        '- Erstes\n'
        '  fortgesetzt\n'
        '  noch mehr\n'
        '- [x] Erledigt\n'
        '  - Verschachtelt\n'
        '1. Nummeriert\n'
        '2) Anders\n'
        '* \n'
        '+ Plus\n',
      );
    });

    test('list items without continuation lines indent new lines', () {
      const text = '10. Item\n';
      final document = parseMarkdown(text);
      expect(
        document.render(['Line one\nline two']),
        '10. Line one\n    line two\n',
      );
    });

    test('block quotes keep their markers on every line', () {
      const text =
          '> Quoted text\n'
          '> on two lines.\n'
          '>\n'
          '> > Nested quote\n'
          '> - quoted list\n';
      final document = parseMarkdown(text);
      expect(texts(document), [
        'Quoted text\non two lines.',
        'Nested quote',
        'quoted list',
      ]);
      expectRoundTrip(document, text);
      expect(
        document.render(['Zitat\nzwei\ndrei', 'Verschachtelt', 'Liste']),
        '> Zitat\n'
        '> zwei\n'
        '> drei\n'
        '>\n'
        '> > Verschachtelt\n'
        '> - Liste\n',
      );
    });

    test('code fences inside quotes are not translated', () {
      const text = '> Text\n> ```\n> code\n> ```\n';
      final document = parseMarkdown(text);
      expect(texts(document), ['Text']);
      expectRoundTrip(document, text);
    });

    test('tables translate cells but keep pipes and the delimiter row', () {
      const text =
          '| Name | Description |\n'
          '|:-----|------------:|\n'
          '| `id` | The unique id \\| key |\n'
          '| 42   | Some value |\n'
          '\n'
          'After\n';
      final document = parseMarkdown(text);
      expect(texts(document), [
        'Name',
        'Description',
        r'The unique id \| key',
        'Some value',
        'After',
      ]);
      expectRoundTrip(document, text);
      expect(
        renderUpper(document),
        '| NAME | DESCRIPTION |\n'
        '|:-----|------------:|\n'
        '| `id` | THE UNIQUE ID \\| KEY |\n'
        '| 42   | SOME VALUE |\n'
        '\n'
        'AFTER\n',
      );
    });

    test('keeps front matter, comments, math, HTML blocks and rules', () {
      const text =
          '---\n'
          'title: Hello\n'
          '---\n'
          'Body\n'
          '\n'
          '<!-- a comment\n'
          'over lines -->\n'
          '\$\$\n'
          'E = mc^2\n'
          '\$\$\n'
          r'$$ x + y $$'
          '\n'
          '<pre>\n'
          'preformatted\n'
          '</pre>\n'
          '***\n'
          'Setext heading\n'
          '==============\n'
          'Another\n'
          '-------\n';
      final document = parseMarkdown(text);
      expect(texts(document), ['Body', 'Setext heading', 'Another']);
      expectRoundTrip(document, text);
    });

    test('front matter without end is a paragraph', () {
      const text = '---\nNot front matter\n';
      final document = parseMarkdown(text);
      expect(texts(document), ['Not front matter']);
      expectRoundTrip(document, text);
    });

    test('paragraph lines stop at following blocks', () {
      const text =
          'Para one\n'
          '# Heading\n'
          'Para two\n'
          '> quote\n'
          'Para three\n'
          '| a | b |\n'
          '|---|---|\n'
          'Para four\n'
          '```\n'
          'code\n'
          '```\n';
      final document = parseMarkdown(text);
      expect(texts(document), [
        'Para one',
        'Heading',
        'Para two',
        'quote\nPara three',
        'a',
        'b',
        'Para four',
      ]);
      expectRoundTrip(document, text);
    });

    test('keeps CRLF line endings', () {
      const text = '# Title\r\n\r\n- one\r\n  two\r\n';
      final document = parseMarkdown(text);
      expect(texts(document), ['Title', 'one\ntwo']);
      expectRoundTrip(document, text);
      expect(
        document.render(['Titel', 'eins\nzwei']),
        '# Titel\r\n\r\n- eins\r\n  zwei\r\n',
      );
    });

    test('drops a duplicated placeholder and appends a lost one', () {
      const text = 'Use `a` and `b`.';
      final document = parseMarkdown(text);
      expect(texts(document), ['Use ⟨1⟩ and ⟨2⟩.']);
      expect(document.render(['Nutze ⟨1⟩ ⟨1⟩.']), 'Nutze `a` . `b`');
    });

    test('lines with only markup or symbols stay verbatim', () {
      const text = '- `code`\n- 123\n# \n';
      final document = parseMarkdown(text);
      expect(document.segments, isEmpty);
      expectRoundTrip(document, text);
    });

    test('a complex README round-trips', () {
      const text =
          '<h1 align="center">Mozhi</h1>\n'
          '<p align="center"><img src="logo.svg" width="96"></p>\n'
          '\n'
          '[![Build](https://img.shields.io/badge.svg)](https://ci.example)\n'
          '\n'
          'A **fast**, _private_ translator.\n'
          '\n'
          '## Install\n'
          '\n'
          '1. Download the [latest release][rel].\n'
          '2. Run:\n'
          '\n'
          '   ```sh\n'
          '   flutter run\n'
          '   ```\n'
          '\n'
          '[rel]: https://github.com/x/releases\n';
      final document = parseMarkdown(text);
      expect(texts(document), [
        '⟨1⟩Mozhi⟨2⟩',
        'A **fast**, _private_ translator.',
        'Install',
        'Download the [latest release]⟨1⟩.',
        'Run:',
      ]);
      expectRoundTrip(document, text);
    });
  });
}
