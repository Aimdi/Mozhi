import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers.dart';

void main() {
  setUpAll(registerFallbacks);

  group('document', () {
    late Harness h;
    late File jsonFile;

    setUp(() {
      h = Harness();
      jsonFile = File('${h.directory.path}/en.json')
        ..writeAsStringSync('{\n  "hello": "Hello",\n  "bye": "Goodbye"\n}\n');
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
    });

    tearDown(() => h.dispose());

    test('translates a JSON file to --output', () async {
      final outPath = '${h.directory.path}/out/fr.json';
      final code = await h.run([
        'document',
        '-f',
        'en',
        '-t',
        'fr',
        '-o',
        outPath,
        jsonFile.path,
      ]);
      expect(code, ExitCode.success.code);
      expect(h.stdout, contains('Translated 2 segments (json)'));
      final written = File(outPath).readAsStringSync();
      expect(written, contains('"hello": "[fr] Hello"'));
      expect(written, contains('"bye": "[fr] Goodbye"'));
    });

    test('supports --in-place (-i)', () async {
      final code = await h.run(['doc', '-t', 'de', '-i', jsonFile.path]);
      expect(code, 0);
      expect(jsonFile.readAsStringSync(), contains('"hello": "[de] Hello"'));
    });

    test('writes translated output to stdout when no -o/-i is given', () async {
      final code = await h.run(['document', '-t', 'fr', jsonFile.path]);
      expect(code, 0);
      expect(h.written.toString(), contains('"hello": "[fr] Hello"'));
    });

    test(
      'supports --dry-run in text and --json modes without translating',
      () async {
        final code = await h.run([
          'document',
          '--dry-run',
          '-t',
          'fr',
          jsonFile.path,
        ]);
        expect(code, 0);
        expect(h.stdout, contains('Dry run: 2 translatable segments'));
        expect(h.stdout, contains('[hello] Hello'));
        verifyNever(() => h.repository.translate(any(), any()));

        h.out.clear();
        expect(
          await h.run([
            'document',
            '--dry-run',
            '--json',
            '-t',
            'fr',
            jsonFile.path,
          ]),
          0,
        );
        final json = h.json()! as Map<String, Object?>;
        expect(json['dryRun'], isTrue);
        expect(json['segments'], 2);
        expect(json['translated'], 0);
        expect((json['entries']! as List<Object?>).length, 2);
      },
    );

    test('prints --json summary and merges saved + CLI glossaries', () async {
      h.writeConfig(
        const CliConfig(
          providers: [ProviderEntry(ollamaProvider)],
          glossary: {'Hello': 'Salut', 'cloud': 'nuage'},
        ),
      );
      final code = await h.run([
        'document',
        '-e',
        'ai',
        '-t',
        'fr',
        '-g',
        'Hello=Bonjour',
        '--json',
        jsonFile.path,
      ]);
      expect(code, 0);
      final json = h.json()! as Map<String, Object?>;
      expect(json['format'], 'json');
      expect(json['translated'], 2);
      expect(json['text'], contains('"hello": "[fr] Hello"'));
      final captured = verify(() => h.repository.translate(any(), captureAny()))
          .captured
          .cast<TranslationRequest>();
      expect(captured.first.options.glossary, {
        'Hello': 'Bonjour',
        'cloud': 'nuage',
      });
    });

    test(
      'rejects combining --output and --in-place, and missing files',
      () async {
        expect(
          await h.run(['document', '-o', 'a.json', '-i', jsonFile.path]),
          ExitCode.usage.code,
        );
        expect(h.stderr, contains('Cannot combine'));

        expect(
          await h.run(['document', '${h.directory.path}/missing.json']),
          ExitCode.noInput.code,
        );
      },
    );

    test(
      'translates multiple files to --output-dir and reports --json',
      () async {
        final xmlFile = File('${h.directory.path}/strings.xml')
          ..writeAsStringSync(
            '<resources><string name="hi">Hello</string></resources>\n',
          );
        final outDir = '${h.directory.path}/translated';
        final code = await h.run([
          'document',
          '-f',
          'en',
          '-t',
          'de',
          '--output-dir',
          outDir,
          '--json',
          jsonFile.path,
          xmlFile.path,
        ]);
        expect(code, ExitCode.success.code);
        final json = h.json()! as Map<String, Object?>;
        expect(json['totalSegments'], 3);
        expect(json['totalTranslated'], 3);
        expect((json['files']! as List<Object?>).length, 2);
        expect(
          File('$outDir/en.json').readAsStringSync(),
          contains('"hello": "[de] Hello"'),
        );
        expect(
          File('$outDir/strings.xml').readAsStringSync(),
          contains('<string name="hi">[de] Hello</string>'),
        );
      },
    );

    test('supports multi-file --dry-run and validates batch flags', () async {
      final second = File('${h.directory.path}/notes.txt')
        ..writeAsStringSync('Second file\n');
      expect(
        await h.run([
          'document',
          '--dry-run',
          '--json',
          '-t',
          'fr',
          jsonFile.path,
          second.path,
        ]),
        ExitCode.success.code,
      );
      final json = h.json()! as Map<String, Object?>;
      expect(json['dryRun'], isTrue);
      expect(json['totalSegments'], 3);

      expect(
        await h.run(['document', '-t', 'fr', jsonFile.path, second.path]),
        ExitCode.usage.code,
      );
      expect(
        await h.run([
          'document',
          '-o',
          'single.out',
          jsonFile.path,
          second.path,
        ]),
        ExitCode.usage.code,
      );
    });
  });
}
