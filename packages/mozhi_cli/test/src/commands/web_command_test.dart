import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi_cli/src/errors.dart';
import 'package:mozhi_cli/src/web/web_page_reader.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers.dart';

void main() {
  setUpAll(registerFallbacks);

  group('extractReadableArticle', () {
    test('prefers <article>, strips nav/script/style, decodes entities', () {
      const html = '''
<!doctype html>
<html>
  <head><title>Hello &amp; Welcome &#8212; Blog</title></head>
  <body>
    <nav><p>Menu item</p></nav>
    <article>
      <h1>First &lt;Heading&gt;</h1>
      <p>Body paragraph with <b>bold</b> and &quot;quotes&quot;.</p>
      <ul><li>Point one</li><li>Point two</li></ul>
      <blockquote>Famous quote</blockquote>
      <script>alert("ignore")</script>
      <style>.x { color: red; }</style>
    </article>
    <footer><p>Copyright footer</p></footer>
  </body>
</html>
''';
      final article = extractReadableArticle(
        FetchedPage(
          url: Uri.parse('https://example.com/post'),
          body: html,
          contentType: 'text/html',
        ),
      );
      expect(article.title, 'Hello & Welcome — Blog');
      expect(article.blocks.map((b) => (b.kind, b.level, b.text)), [
        (ReadableBlockKind.heading, 1, 'First <Heading>'),
        (
          ReadableBlockKind.paragraph,
          0,
          'Body paragraph with bold and "quotes".',
        ),
        (ReadableBlockKind.listItem, 0, 'Point one'),
        (ReadableBlockKind.listItem, 0, 'Point two'),
        (ReadableBlockKind.quote, 0, 'Famous quote'),
      ]);
    });

    test('extracts plain-text pages paragraph by paragraph', () {
      final article = extractReadableArticle(
        FetchedPage(
          url: Uri.parse('https://example.com/readme.txt'),
          body: 'First line\ncontinued.\n\nSecond paragraph.',
          contentType: 'text/plain',
        ),
      );
      expect(article.title, isNull);
      expect(article.blocks.map((b) => b.text), [
        'First line continued.',
        'Second paragraph.',
      ]);
    });
  });

  group('fetchWebPage', () {
    test('follows redirects and rejects binary content types', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        if (request.uri.path == '/redirect') {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set(HttpHeaders.locationHeader, '/article');
          await request.response.close();
        } else if (request.uri.path == '/article') {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.html
            ..write('<html><title>Hi</title><body><p>Hello</p></body></html>');
          await request.response.close();
        } else if (request.uri.path == '/binary') {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType('application', 'pdf')
            ..add([0x25, 0x50, 0x44, 0x46]);
          await request.response.close();
        }
      });

      final base = 'http://127.0.0.1:${server.port}';
      final page = await fetchWebPage(Uri.parse('$base/redirect'));
      expect(page.url.path, '/article');
      expect(page.body, contains('<p>Hello</p>'));

      await expectLater(
        () => fetchWebPage(Uri.parse('$base/binary')),
        throwsA(isA<CliException>()),
      );
    });
  });

  group('web command', () {
    late Harness h;

    setUp(() {
      h = Harness();
      when(() => h.repository.getTargetLanguages(any()))
          .thenAnswer((_) async => [english, french, german]);
      when(() => h.repository.getSourceLanguages(any()))
          .thenAnswer((_) async => [Language.auto, english, french, german]);
      when(() => h.repository.translate(any(), any())).thenAnswer((invocation) {
        final req = invocation.positionalArguments[1] as TranslationRequest;
        return Stream.value(
          TranslationResult(
            engineId: 'mozhi:google',
            engineName: 'Google',
            text: '[${req.target.code}] ${req.text}',
          ),
        );
      });
      h.webFetcher = (uri) async => FetchedPage(
        url: uri,
        body:
            '<html><head><title>News</title></head> '
            '<body><article><h2>Headline</h2><p>Hello world.</p></article> '
            '</body></html>',
        contentType: 'text/html',
      );
    });

    tearDown(() => h.dispose());

    test(
      'translates a web page to Markdown and supports --bilingual',
      () async {
        final code = await h.run([
          'web',
          '-f',
          'en',
          '-t',
          'de',
          'example.com/news',
        ]);
        expect(code, ExitCode.success.code);
        final md = h.written.toString();
        expect(md, contains('# [de] News'));
        expect(md, contains('Source: https://example.com/news'));
        expect(md, contains('## [de] Headline'));
        expect(md, contains('[de] Hello world.'));

        h.written.clear();
        expect(
          await h.run([
            'page',
            '-t',
            'fr',
            '--bilingual',
            'https://example.com/news',
          ]),
          0,
        );
        final bi = h.written.toString();
        expect(bi, contains('# [fr] News\n\n*News*'));
        expect(bi, contains('## Headline\n\n## [fr] Headline'));
      },
    );

    test('supports --dry-run, --json and --output', () async {
      expect(
        await h.run(['web', '--dry-run', '--json', 'https://example.com']),
        0,
      );
      final dry = h.json()! as Map<String, Object?>;
      expect(dry['dryRun'], isTrue);
      expect(dry['title'], 'News');
      verifyNever(() => h.repository.translate(any(), any()));

      h.out.clear();
      final outPath = '${h.directory.path}/article.md';
      expect(
        await h.run([
          'web',
          '-t',
          'de',
          '-o',
          outPath,
          '--json',
          'https://example.com',
        ]),
        0,
      );
      final json = h.json()! as Map<String, Object?>;
      expect(json['translatedTitle'], '[de] News');
      expect(json['outputFile'], outPath);
      expect(File(outPath).readAsStringSync(), contains('[de] Hello world.'));
    });
  });
}
