import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/core/office/office.dart';
import 'package:mozhi/documents/data/document_worker.dart';

import '../core/office/office_fixtures.dart';

void main() {
  group('parseTextCooperatively', () {
    test(
      'chunks large plain text identically to sync parseDocument and yields',
      () async {
        final paragraphs = [
          for (var i = 0; i < 2500; i++)
            'Paragraph $i with https://example.com/$i\nSecond line of text.',
        ];
        final text =
            '${paragraphs.join('\r\n\r\n')}\r\n\r\n   \r\n\r\nFinal line';
        expect(text.length, greaterThan(webTextChunkThreshold));

        var yields = 0;
        final coop = await parseTextCooperatively(
          parseDocument,
          text,
          DocumentFormat.plainText,
          yieldTurn: () async {
            yields++;
            await Future<void>.delayed(Duration.zero);
          },
        );
        final sync = parseDocument(text, DocumentFormat.plainText);

        // Yielded before starting and between chunks.
        expect(yields, greaterThanOrEqualTo(3));
        expect(coop.format, sync.format);
        expect(coop.segments, sync.segments);
        expect(coop.characterCount, sync.characterCount);
        expect(coop.render(), text);
        expect(coop.render(), sync.render());

        final translations = [
          for (final s in sync.segments) s.text.toUpperCase(),
        ];
        expect(coop.render(translations), sync.render(translations));
        for (final idx in [
          0,
          1,
          sync.segments.length ~/ 2,
          sync.segments.length - 1,
        ]) {
          expect(coop.segmentSource(idx), sync.segmentSource(idx));
          expect(
            coop.segmentOutput(idx, translations[idx]),
            sync.segmentOutput(idx, translations[idx]),
          );
        }
      },
    );

    test(
      'handles large single-paragraph plain text without blank lines',
      () async {
        final text = List<String>.filled(
          2000,
          'Line without blank separator',
        ).join('\n');
        var yields = 0;
        final coop = await parseTextCooperatively(
          parseDocument,
          text,
          DocumentFormat.plainText,
          chunkThreshold: 1000,
          chunkSize: 500,
          yieldTurn: () async {
            yields++;
            await Future<void>.delayed(Duration.zero);
          },
        );
        final sync = parseDocument(text, DocumentFormat.plainText);
        expect(yields, 1);
        expect(coop.segments, sync.segments);
        expect(coop.render(), text);
      },
    );

    test('yields for non-plainText formats and propagates errors', () async {
      var yields = 0;
      const json =
          '{"title": "Hello world", "body": "Testing cooperative parse"}';
      final coop = await parseTextCooperatively(
        parseDocument,
        json,
        DocumentFormat.json,
        yieldTurn: () async {
          yields++;
          await Future<void>.delayed(Duration.zero);
        },
      );
      final sync = parseDocument(json, DocumentFormat.json);
      expect(yields, 1);
      expect(coop.segments, sync.segments);

      await expectLater(
        parseTextCooperatively(parseDocument, '{bad json', DocumentFormat.json),
        throwsA(isA<DocumentParseException>()),
      );
    });

    test('invokes custom injected parser once after yielding', () async {
      var calls = 0;
      var yields = 0;
      final big = List<String>.filled(400, 'Some paragraph text.').join('\n\n');
      final doc = await parseTextCooperatively(
        (text, format, {targetLanguage}) {
          calls++;
          return parseDocument(text, format, targetLanguage: targetLanguage);
        },
        big,
        DocumentFormat.plainText,
        chunkThreshold: 100,
        chunkSize: 100,
        yieldTurn: () async {
          yields++;
          await Future<void>.delayed(Duration.zero);
        },
      );
      expect(yields, 1);
      expect(calls, 1);
      expect(doc.segments, hasLength(400));
    });

    test(
      'chunks large SRT and VTT subtitles identically to sync parseDocument',
      () async {
        for (final format in [DocumentFormat.srt, DocumentFormat.vtt]) {
          String cue(int i) {
            final s = (i % 60).toString().padLeft(2, '0');
            final e = ((i + 1) % 60).toString().padLeft(2, '0');
            return '$i\n00:00:$s,000 --> 00:00:$e,500\n'
                'Subtitle line $i with <i>tag</i>';
          }

          final cues = <String>[
            if (format == DocumentFormat.vtt) 'WEBVTT\n\nNOTE header note',
            for (var i = 1; i <= 60; i++) cue(i),
          ];
          final text = '${cues.join('\n\n')}\n';
          var yields = 0;
          final coop = await parseTextCooperatively(
            parseDocument,
            text,
            format,
            chunkThreshold: 400,
            chunkSize: 400,
            yieldTurn: () async {
              yields++;
              await Future<void>.delayed(Duration.zero);
            },
          );
          final sync = parseDocument(text, format);

          expect(yields, greaterThanOrEqualTo(3), reason: format.name);
          expect(coop.segments, sync.segments, reason: format.name);
          expect(coop.render(), text, reason: format.name);
          final translations = [
            for (final s in sync.segments) s.text.toUpperCase(),
          ];
          expect(
            coop.render(translations),
            sync.render(translations),
            reason: format.name,
          );
        }
      },
    );

    test(
      'chunks large Java .properties without breaking backslash continuations',
      () async {
        final entries = [
          for (var i = 0; i < 80; i++)
            if (i.isEven)
              'key.$i = Hello world number $i'
            else
              'multi.$i = First line of $i \\\n  continued line $i',
        ];
        final text = '\uFEFF# Header comment\n${entries.join('\n')}\n';
        var yields = 0;
        final coop = await parseTextCooperatively(
          parseDocument,
          text,
          DocumentFormat.properties,
          chunkThreshold: 400,
          chunkSize: 300,
          yieldTurn: () async {
            yields++;
            await Future<void>.delayed(Duration.zero);
          },
        );
        final sync = parseDocument(text, DocumentFormat.properties);

        expect(yields, greaterThanOrEqualTo(3));
        expect(coop.segments, sync.segments);
        expect(coop.render(), text);
        final translations = [
          for (final s in sync.segments) s.text.toUpperCase(),
        ];
        expect(coop.render(translations), sync.render(translations));
      },
    );

    test('chunks large Markdown identically to sync parseDocument', () async {
      final sections = <String>[
        '---\ntitle: Keep me\nauthor: Mozhi\n---',
        for (var i = 0; i < 40; i++) ...[
          '## Section $i',
          'Paragraph $i with `inlineCode` and [link](https://example.com/$i).',
          '```dart\n// Blank line in fence\n\nfinal x = $i;\n```',
          '\$\$\na_$i = b_$i\n\n+ c_$i\n\$\$',
          '<!-- multi-line\n\nHTML comment $i -->',
          '<pre>\nraw html $i\n\nstill pre\n</pre>',
          '    indented code $i\n\n    still indented $i',
          '- List item $i\n\n    indented list continuation $i',
          '---',
          '| Col A | Col B |\n| --- | --- |\n| Val $i | Text $i |',
        ],
      ];
      final text = '${sections.join('\n\n')}\n';
      var yields = 0;
      final coop = await parseTextCooperatively(
        parseDocument,
        text,
        DocumentFormat.markdown,
        chunkThreshold: 500,
        chunkSize: 400,
        yieldTurn: () async {
          yields++;
          await Future<void>.delayed(Duration.zero);
        },
      );
      final sync = parseDocument(text, DocumentFormat.markdown);

      expect(yields, greaterThanOrEqualTo(4));
      expect(coop.segments, sync.segments);
      expect(coop.render(), text);
      final translations = [
        for (final s in sync.segments) s.text.toUpperCase(),
      ];
      expect(coop.render(translations), sync.render(translations));
    });

    test(
      'chunks large Apple .strings identically to sync parseDocument',
      () async {
        final entries = List.generate(
          60,
          (i) =>
              '/* Comment with ; inside $i */\n'
              '"key_$i" = "Hello world ; number $i with %@";',
        );
        final text = '\uFEFF// Header\n${entries.join('\n')}\n';
        var yields = 0;
        final coop = await parseTextCooperatively(
          parseDocument,
          text,
          DocumentFormat.appleStrings,
          chunkThreshold: 400,
          chunkSize: 300,
          yieldTurn: () async {
            yields++;
            await Future<void>.delayed(Duration.zero);
          },
        );
        final sync = parseDocument(text, DocumentFormat.appleStrings);

        expect(yields, greaterThanOrEqualTo(3));
        expect(coop.segments, sync.segments);
        expect(coop.render(), text);
        final translations = [
          for (final s in sync.segments) s.text.toUpperCase(),
        ];
        expect(coop.render(translations), sync.render(translations));
      },
    );

    test(
      'chunks large TOML identically to sync parseDocument across tables',
      () async {
        final sections = [
          'title = "Top level"\n',
          ...List.generate(
            30,
            (i) =>
                '[section_$i]\n'
                'label = "Section $i label"\n'
                'body = """\n[not_a_table]\nLine $i\n"""\n'
                'items = [\n  "Item $i a",\n  "Item $i b",\n]\n',
          ),
        ];
        final text = sections.join('\n');
        var yields = 0;
        final coop = await parseTextCooperatively(
          parseDocument,
          text,
          DocumentFormat.toml,
          chunkThreshold: 400,
          chunkSize: 300,
          yieldTurn: () async {
            yields++;
            await Future<void>.delayed(Duration.zero);
          },
        );
        final sync = parseDocument(text, DocumentFormat.toml);

        expect(yields, greaterThanOrEqualTo(3));
        expect(coop.segments, sync.segments);
        expect(coop.render(), text);
        final translations = [
          for (final s in sync.segments) s.text.toUpperCase(),
        ];
        expect(coop.render(translations), sync.render(translations));
      },
    );

    test('chunks large YAML files identically to sync parseDocument', () async {
      final buf = StringBuffer('# Localization catalogue\n');
      for (var i = 0; i < 40; i++) {
        buf
          ..writeln('section_$i:')
          ..writeln('  title: "Hello section $i"')
          ..writeln('  body: |')
          ..writeln('    First line of section $i.')
          ..writeln('    not_a_key: still inside block scalar $i')
          ..writeln('  multiline: "Line one of $i')
          ..writeln('    still_quoted: not a split point"')
          ..writeln('  tags: [')
          ..writeln('    "Welcome $i",')
          ..writeln('    "Goodbye $i"')
          ..writeln('  ]')
          ..writeln('  count: $i')
          ..writeln();
      }
      final text = buf.toString();
      var yields = 0;
      final coop = await parseTextCooperatively(
        parseDocument,
        text,
        DocumentFormat.yaml,
        chunkThreshold: 400,
        chunkSize: 400,
        yieldTurn: () async {
          yields++;
          await Future<void>.delayed(Duration.zero);
        },
      );
      final sync = parseDocument(text, DocumentFormat.yaml);

      expect(yields, greaterThanOrEqualTo(3));
      expect(coop.segments, sync.segments);
      expect(coop.render(), text);
      final translations = [
        for (final s in sync.segments) s.text.toUpperCase(),
      ];
      expect(coop.render(translations), sync.render(translations));
    });

    test('keeps single-root Rails YAML intact in one chunk', () async {
      final buf = StringBuffer('en:\n');
      for (var i = 0; i < 40; i++) {
        buf.writeln('  key_$i: "Greeting number $i"');
      }
      final text = buf.toString();
      var yields = 0;
      final coop = await parseTextCooperatively(
        parseDocument,
        text,
        DocumentFormat.yaml,
        chunkThreshold: 200,
        chunkSize: 200,
        yieldTurn: () async {
          yields++;
          await Future<void>.delayed(Duration.zero);
        },
      );
      final sync = parseDocument(text, DocumentFormat.yaml);

      expect(yields, 1);
      expect(coop.segments, sync.segments);
      expect(coop.render(), text);
    });

    test('cooperatively parses CSV and TSV identically', () async {
      for (final format in [DocumentFormat.csv, DocumentFormat.tsv]) {
        final sep = format == DocumentFormat.tsv ? '\t' : ',';
        final buf = StringBuffer('id${sep}title${sep}notes\n');
        for (var i = 0; i < 2200; i++) {
          final note = format == DocumentFormat.csv && i % 5 == 0
              ? '"Line 1, item $i\nLine 2 ""quoted"""'
              : 'Detailed description for row $i';
          buf.writeln('SKU-$i${sep}Product name $i$sep$note');
        }
        final text = buf.toString();
        var yields = 0;
        final coop = await parseTextCooperatively(
          parseDocument,
          text,
          format,
          chunkThreshold: 500,
          yieldTurn: () async {
            yields++;
            await Future<void>.delayed(Duration.zero);
          },
        );
        final sync = parseDocument(text, format);

        expect(yields, greaterThanOrEqualTo(3));
        expect(coop.format, sync.format);
        expect(coop.segments, sync.segments);
        expect(coop.render(), text);
        final translations = [
          for (final s in sync.segments) s.text.toUpperCase(),
        ];
        expect(coop.render(translations), sync.render(translations));
      }
    });
  });

  group('OfficePackage async cooperative yielding', () {
    test(
      'parseAsync and renderAsync yield to event loop and match sync',
      () async {
        final body = [
          for (var i = 0; i < 400; i++)
            '<w:p><w:r><w:t>Paragraph $i text.</w:t></w:r></w:p>',
        ].join();
        final bytes = docx(body);

        var timerTicks = 0;
        var running = true;
        void tick() {
          if (!running) return;
          timerTicks++;
          Timer(Duration.zero, tick);
        }

        Timer(Duration.zero, tick);
        final asyncDoc = await OfficePackage.parseAsync(
          bytes,
          DocumentFormat.docx,
          targetLanguage: 'de',
        );
        final translations = [
          for (final s in asyncDoc.segments) s.text.toUpperCase(),
        ];
        final asyncRendered = await asyncDoc.renderAsync(translations);
        running = false;

        final syncDoc = OfficePackage.parse(
          bytes,
          DocumentFormat.docx,
          targetLanguage: 'de',
        );
        expect(timerTicks, greaterThan(0));
        expect(textsOf(asyncDoc), textsOf(syncDoc));
        expect(asyncRendered, syncDoc.render(translations));
      },
    );

    test('multi-chapter EPUB parseAsync and renderAsync match sync', () async {
      final bytes = epub({
        for (var i = 0; i < 12; i++)
          'chapter$i.xhtml':
              '<p>Chapter $i opening paragraph.</p><p>Second sentence $i.</p>',
      });
      final asyncDoc = await OfficePackage.parseAsync(
        bytes,
        DocumentFormat.epub,
        targetLanguage: 'fr',
      );
      final syncDoc = OfficePackage.parse(
        bytes,
        DocumentFormat.epub,
        targetLanguage: 'fr',
      );
      expect(textsOf(asyncDoc), textsOf(syncDoc));
      final translations = [
        for (final s in syncDoc.segments) s.text.toUpperCase(),
      ];
      expect(
        await asyncDoc.renderAsync(translations),
        syncDoc.render(translations),
      );
    });
  });
}
