import 'package:mozhi_cli/src/documents/document_handler.dart';
import 'package:mozhi_cli/src/errors.dart';
import 'package:test/test.dart';

String _translate(String text) => 'TR[$text]';

String _roundTrip(String filePath, String content) {
  final doc = DocumentHandlers.parse(filePath, content);
  return doc.rebuild([for (final s in doc.segments) _translate(s.text)]);
}

void main() {
  group('DocumentHandlers', () {
    test('.txt preserves paragraphs, blank lines and CRLF', () {
      const input = 'Hello world.\r\nSecond line.\r\n\r\nNext para.\r\n';
      final doc = DocumentHandlers.parse('notes.txt', input);
      expect(doc.format, 'txt');
      expect(doc.segments.map((s) => s.text), [
        'Hello world.\nSecond line.',
        'Next para.',
      ]);
      expect(
        _roundTrip('notes.txt', input),
        'TR[Hello world.\nSecond line.]\r\n\r\nTR[Next para.]\r\n',
      );
    });

    test('.md preserves frontmatter, fenced code blocks and prefixes', () {
      const input =
          '---\ntitle: Keep\n---\n\n# Welcome\n\n- First item\n> Quoted\n\n'
          '```dart\nfinal x = "do not translate";\n```\n\nBody text.\n';
      final doc = DocumentHandlers.parse('README.md', input);
      expect(doc.format, 'md');
      expect(doc.segments.map((s) => s.text), [
        'Welcome',
        'First item',
        'Quoted',
        'Body text.',
      ]);
      final out = _roundTrip('README.md', input);
      expect(out, contains('---\ntitle: Keep\n---'));
      expect(out, contains('# TR[Welcome]'));
      expect(out, contains('- TR[First item]'));
      expect(out, contains('> TR[Quoted]'));
      expect(out, contains('final x = "do not translate";'));
      expect(out, contains('TR[Body text.]'));
    });

    test('.json translates leaf strings while keeping keys and primitives', () {
      const input =
          '{\n  "title": "Hello {name}",\n  "count": 3,\n  '
          '"nested": {\n    "ok": true,\n    "items": ["One", "Two"]\n  }\n}\n';
      final doc = DocumentHandlers.parse('en.json', input);
      expect(doc.format, 'json');
      expect(doc.segments.map((s) => (s.id, s.text)), [
        ('title', 'Hello {name}'),
        ('nested.items[0]', 'One'),
        ('nested.items[1]', 'Two'),
      ]);
      final out = _roundTrip('en.json', input);
      expect(out, contains('"title": "TR[Hello {name}]"'));
      expect(out, contains('"count": 3'));
      expect(out, contains('"ok": true'));
      expect(out, contains('"TR[One]"'));
    });

    test('.arb skips @ metadata keys', () {
      const input =
          '{\n  "@@locale": "en",\n  "greeting": "Hello {name}",\n'
          '  "@greeting": {\n    "description": "Welcome message"\n  }\n}\n';
      final doc = DocumentHandlers.parse('app_en.arb', input);
      expect(doc.format, 'arb');
      expect(doc.segments.map((s) => s.id), ['greeting']);
      final out = _roundTrip('app_en.arb', input);
      expect(out, contains('"@@locale": "en"'));
      expect(out, contains('"greeting": "TR[Hello {name}]"'));
      expect(out, contains('"description": "Welcome message"'));
    });

    test('.srt preserves cue numbers and timestamps', () {
      const input =
          '1\n00:00:01,000 --> 00:00:03,500\nHello world\nLine two\n\n'
          '2\n00:00:04,000 --> 00:00:06,000\nGoodbye\n';
      final doc = DocumentHandlers.parse('movie.srt', input);
      expect(doc.format, 'srt');
      expect(doc.segments.map((s) => s.text), [
        'Hello world\nLine two',
        'Goodbye',
      ]);
      final out = _roundTrip('movie.srt', input);
      expect(
        out,
        '1\n00:00:01,000 --> 00:00:03,500\nTR[Hello world\nLine two]\n\n'
        '2\n00:00:04,000 --> 00:00:06,000\nTR[Goodbye]\n',
      );
    });

    test('.vtt preserves WEBVTT header, NOTE blocks and cue ids', () {
      const input =
          'WEBVTT\n\nNOTE translator comment\n\nintro\n'
          '00:00:01.000 --> 00:00:02.500 align:center\nWelcome!\n';
      final doc = DocumentHandlers.parse('captions.vtt', input);
      expect(doc.format, 'vtt');
      expect(doc.segments.map((s) => s.text), ['Welcome!']);
      final out = _roundTrip('captions.vtt', input);
      expect(out, contains('WEBVTT'));
      expect(out, contains('NOTE translator comment'));
      expect(out, contains('00:00:01.000 --> 00:00:02.500 align:center'));
      expect(out, contains('TR[Welcome!]'));
    });

    test('.po preserves header, comments, msgid and plural forms', () {
      const input =
          'msgid ""\nmsgstr ""\n"Content-Type: text/plain; charset=UTF-8\\n"\n\n'
          '#: app.dart:10\nmsgid "Hello %s"\nmsgstr ""\n\n'
          'msgid "One file"\nmsgid_plural "%d files"\n'
          'msgstr[0] ""\nmsgstr[1] ""\n';
      final doc = DocumentHandlers.parse('messages.po', input);
      expect(doc.format, 'po');
      expect(doc.segments.map((s) => s.text), [
        'Hello %s',
        'One file',
        '%d files',
      ]);
      final out = _roundTrip('messages.po', input);
      expect(out, contains(r'"Content-Type: text/plain; charset=UTF-8\n"'));
      expect(out, contains('#: app.dart:10'));
      expect(out, contains('msgstr "TR[Hello %s]"'));
      expect(out, contains('msgstr[0] "TR[One file]"'));
      expect(out, contains('msgstr[1] "TR[%d files]"'));
    });

    test(
      '.properties preserves comments, keys, delimiters and continuations',
      () {
        const input =
            '# App strings\n! Ignore me\napp.title = Hello World\n'
            'app.desc: First \\\n  Second\n';
        final doc = DocumentHandlers.parse('messages.properties', input);
        expect(doc.format, 'properties');
        expect(doc.segments.map((s) => (s.id, s.text)), [
          ('app.title', 'Hello World'),
          ('app.desc', 'First Second'),
        ]);
        final out = _roundTrip('messages.properties', input);
        expect(out, contains('# App strings'));
        expect(out, contains('! Ignore me'));
        expect(out, contains('app.title = TR[Hello World]'));
        expect(out, contains('app.desc: TR[First Second]'));
      },
    );

    test('.yaml preserves comments, keys, quotes, block scalars and types', () {
      const input =
          '# Locale\nen:\n  greeting: "Hello"\n  plain: Good morning # note\n'
          '  count: 42\n  enabled: true\n  items:\n    - First\n'
          '  bio: |\n    Line one\n    Line two\n';
      final doc = DocumentHandlers.parse('en.yaml', input);
      expect(doc.format, 'yaml');
      expect(doc.segments.map((s) => s.text), [
        'Hello',
        'Good morning',
        'First',
        'Line one\nLine two',
      ]);
      final out = _roundTrip('en.yaml', input);
      expect(out, contains('# Locale'));
      expect(out, contains('greeting: "TR[Hello]"'));
      expect(out, contains('plain: TR[Good morning] # note'));
      expect(out, contains('count: 42'));
      expect(out, contains('enabled: true'));
      expect(out, contains('    - TR[First]'));
      expect(out, contains('    TR[Line one\n    Line two]'));
    });

    test('.csv and .tsv preserve delimiters, quoting and numeric cells', () {
      const csv = 'id,label,count\n1,"Hello, ""world""",42\n';
      final csvDoc = DocumentHandlers.parse('strings.csv', csv);
      expect(csvDoc.format, 'csv');
      expect(csvDoc.segments.map((s) => s.text), [
        'id',
        'label',
        'count',
        'Hello, "world"',
      ]);
      final csvOut = _roundTrip('strings.csv', csv);
      expect(
        csvOut,
        'TR[id],TR[label],TR[count]\n1,"TR[Hello, ""world""]",42\n',
      );

      const tsv = '1\tHello\ttrue\n';
      final tsvDoc = DocumentHandlers.parse('strings.tsv', tsv);
      expect(tsvDoc.format, 'tsv');
      expect(_roundTrip('strings.tsv', tsv), '1\tTR[Hello]\ttrue\n');
    });

    test('.toml preserves tables, comments, types and multiline strings', () {
      const input =
          '# App config\ntitle = "Hello"\n'
          'count = 42\nenabled = true\n\n'
          '[messages]\n'
          "literal = 'Good morning' # note\n"
          'body = """\nLine one\nLine two"""\n';
      final doc = DocumentHandlers.parse('strings.toml', input);
      expect(doc.format, 'toml');
      expect(doc.segments.map((s) => (s.id, s.text)), [
        ('title', 'Hello'),
        ('messages.literal', 'Good morning'),
        ('messages.body', 'Line one\nLine two'),
      ]);
      final out = _roundTrip('strings.toml', input);
      expect(out, contains('# App config'));
      expect(out, contains('title = "TR[Hello]"'));
      expect(out, contains('count = 42'));
      expect(out, contains('enabled = true'));
      expect(out, contains("literal = 'TR[Good morning]' # note"));
      expect(out, contains('body = """\nTR[Line one\nLine two]"""'));
    });

    test('.tmx inserts or updates target <tuv> while keeping XML intact', () {
      const input =
          '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<tmx version="1.4">\n'
          '  <header srclang="en"/>\n'
          '  <body>\n'
          '    <tu>\n'
          '      <tuv xml:lang="en"><seg>Hello &amp; welcome</seg></tuv>\n'
          '    </tu>\n'
          '    <tu>\n'
          '      <tuv xml:lang="en"><seg>Goodbye</seg></tuv>\n'
          '      <tuv xml:lang="de"><seg>Old</seg></tuv>\n'
          '    </tu>\n'
          '  </body>\n'
          '</tmx>\n';
      final doc = DocumentHandlers.parse(
        'memory.tmx',
        input,
        targetLanguage: 'de',
      );
      expect(doc.format, 'tmx');
      expect(doc.segments.map((s) => (s.id, s.text)), [
        ('tu-1', 'Hello & welcome'),
        ('tu-2', 'Goodbye'),
      ]);
      final out = doc.rebuild(['Hallo & willkommen', 'Tschüss']);
      expect(
        out,
        contains(
          '<tuv xml:lang="en"><seg>Hello &amp; welcome</seg></tuv>\n'
          '      <tuv xml:lang="de"><seg>Hallo &amp; willkommen</seg></tuv>',
        ),
      );
      expect(out, contains('<tuv xml:lang="de"><seg>Tschüss</seg></tuv>'));
      expect(out, isNot(contains('<seg>Old</seg>')));
    });

    test('.html skips script/style/code/pre and updates html lang', () {
      const input =
          '<!doctype html>\n'
          '<html lang="en">\n'
          '<head><title>Hello &amp; Hi</title> '
          '<style>.a { color: red; }</style></head>\n'
          '<body>\n'
          '  <!-- Ignore comment -->\n'
          '  <h1>Welcome</h1>\n'
          '  <p>Use <code>mozhi doc</code> now.</p>\n'
          '  <script>console.log("keep");</script>\n'
          '</body>\n'
          '</html>\n';
      final doc = DocumentHandlers.parse(
        'index.html',
        input,
        targetLanguage: 'fr',
      );
      expect(doc.format, 'html');
      expect(doc.segments.map((s) => s.text), [
        'Hello & Hi',
        'Welcome',
        'Use',
        'now.',
      ]);
      final out = doc.rebuild([
        for (final s in doc.segments) _translate(s.text),
      ]);
      expect(out, contains('<html lang="fr">'));
      expect(out, contains('<title>TR[Hello &amp; Hi]</title>'));
      expect(out, contains('<style>.a { color: red; }</style>'));
      expect(out, contains('<!-- Ignore comment -->'));
      expect(out, contains('<h1>TR[Welcome]</h1>'));
      expect(out, contains('<p>TR[Use] <code>mozhi doc</code> TR[now.]</p>'));
      expect(out, contains('console.log("keep");'));
    });

    test('.xml handles Android strings, string-array, plurals, CDATA and '
        'translatable="false"', () {
      const input =
          '<?xml version="1.0" encoding="utf-8"?>\n'
          '<resources>\n'
          '  <!-- <string name="commented">Skip me</string> -->\n'
          '  <string name="app_name" translatable="false">Mozhi</string>\n'
          '  <string name="greeting">It\\\'s ready &amp; fast</string>\n'
          '  <string name="html_note"><![CDATA[<b>Bold</b> text]]></string>\n'
          '  <string-array name="days">\n'
          '    <item>Monday</item>\n'
          '    <item>Tuesday</item>\n'
          '  </string-array>\n'
          '  <plurals name="items">\n'
          '    <item quantity="one">%d item</item>\n'
          '    <item quantity="other">%d items</item>\n'
          '  </plurals>\n'
          '</resources>\n';
      final doc = DocumentHandlers.parse('strings.xml', input);
      expect(doc.format, 'xml');
      expect(doc.segments.map((s) => (s.id, s.text)), [
        ('greeting', "It's ready & fast"),
        ('html_note', '<b>Bold</b> text'),
        ('days[0]', 'Monday'),
        ('days[1]', 'Tuesday'),
        ('items:one', '%d item'),
        ('items:other', '%d items'),
      ]);
      final out = _roundTrip('strings.xml', input);
      expect(
        out,
        contains('<!-- <string name="commented">Skip me</string> -->'),
      );
      expect(
        out,
        contains('<string name="app_name" translatable="false">Mozhi</string>'),
      );
      expect(
        out,
        contains(
          '<string name="greeting">TR[It\\\'s ready &amp; fast]</string>',
        ),
      );
      expect(out, contains('<![CDATA[TR[<b>Bold</b> text]]]>'));
      expect(out, contains('<item>TR[Monday]</item>'));
      expect(out, contains('<item quantity="other">TR[%d items]</item>'));
    });

    test('.strings preserves Apple Localizable.strings comments and keys', () {
      const input =
          '/* Header comment */\n'
          '"welcome_title" = "Hello \\"world\\"";\n'
          '// Single line note\n'
          '"multiline" = "Line 1\\nLine 2";\n';
      final doc = DocumentHandlers.parse('Localizable.strings', input);
      expect(doc.format, 'strings');
      expect(doc.segments.map((s) => (s.id, s.text)), [
        ('welcome_title', 'Hello "world"'),
        ('multiline', 'Line 1\nLine 2'),
      ]);
      final out = _roundTrip('Localizable.strings', input);
      expect(out, contains('/* Header comment */'));
      expect(out, contains('// Single line note'));
      expect(out, contains(r'"welcome_title" = "TR[Hello \"world\"]";'));
      expect(out, contains(r'"multiline" = "TR[Line 1\nLine 2]";'));
    });

    test('.xliff updates or inserts <target>, target-language and skips '
        'translate="no"', () {
      const input =
          '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<xliff version="1.2">\n'
          '  <file source-language="en" target-language="fr">\n'
          '    <body>\n'
          '      <trans-unit id="u1">\n'
          '        <source>Hello &amp; welcome</source>\n'
          '      </trans-unit>\n'
          '      <trans-unit id="u2">\n'
          '        <source>Goodbye</source>\n'
          '        <target state="needs-translation">Old</target>\n'
          '      </trans-unit>\n'
          '      <trans-unit id="u3" translate="no">\n'
          '        <source>Keep verbatim</source>\n'
          '      </trans-unit>\n'
          '    </body>\n'
          '  </file>\n'
          '</xliff>\n';
      final doc = DocumentHandlers.parse(
        'app.xliff',
        input,
        targetLanguage: 'de',
      );
      expect(doc.format, 'xliff');
      expect(doc.segments.map((s) => (s.id, s.text)), [
        ('u1', 'Hello & welcome'),
        ('u2', 'Goodbye'),
      ]);
      final out = doc.rebuild(['Hallo & willkommen', 'Tschüss']);
      expect(out, contains('target-language="de"'));
      expect(
        out,
        contains(
          '<source>Hello &amp; welcome</source>\n'
          '        <target>Hallo &amp; willkommen</target>',
        ),
      );
      expect(
        out,
        contains('<target state="needs-translation">Tschüss</target>'),
      );
      expect(out, contains('<source>Keep verbatim</source>'));
    });

    test('rejects unsupported extensions', () {
      expect(
        () => DocumentHandlers.parse('file.bin', 'abc'),
        throwsA(isA<CliException>()),
      );
    });
  });
}
