import 'dart:async';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers.dart';

void main() {
  setUpAll(registerFallbacks);

  group('translate', () {
    late Harness h;

    setUp(() {
      h = Harness();
      when(
        () => h.repository.getTargetLanguages(any()),
      ).thenAnswer((_) async => [english, french, german]);
      when(
        () => h.repository.getSourceLanguages(any()),
      ).thenAnswer((_) async => [Language.auto, english, french, german]);
      when(() => h.repository.translate(any(), any())).thenAnswer(
        (_) => Stream.value(
          const TranslationResult(
            engineId: 'mozhi:google',
            engineName: 'Google',
            text: 'Hello world',
            detectedSource: 'fr',
            targetTransliteration: 'helo',
            elapsed: Duration(milliseconds: 120),
          ),
        ),
      );
    });

    tearDown(() => h.dispose());

    TranslationRequest capturedRequest() =>
        verify(
              () => h.repository.translate(any(), captureAny()),
            ).captured.single
            as TranslationRequest;

    test('translates the argument with Mozhi google by default', () async {
      final code = await h.run(['translate', 'Bonjour', 'le', 'monde']);
      expect(code, ExitCode.success.code);
      expect(h.out, ['Hello world']);
      final request = capturedRequest();
      expect(request.text, 'Bonjour le monde');
      expect(request.source, Language.auto);
      expect(request.target.code, 'en');
      verify(
        () => h.repository.updateConfiguration(
          instances: MozhiInstance.publicInstances,
          providers: const [],
        ),
      ).called(1);
      verify(() => h.repository.dispose()).called(1);
    });

    test('reads standard input', () async {
      h.pipe('Bonjour\n');
      expect(await h.run(['translate', '--to', 'de']), 0);
      expect(capturedRequest().text, 'Bonjour\n');
    });

    test('fails with usage when there is no input', () async {
      expect(await h.run(['translate']), ExitCode.usage.code);
      expect(h.stderr, contains('No text given.'));
    });

    test('fails with usage when stdin is empty', () async {
      h.pipe('  ');
      expect(await h.run(['translate', '-']), ExitCode.usage.code);
      expect(h.stderr, contains('The text is empty.'));
    });

    test('maps languages onto the engine list', () async {
      expect(
        await h.run(['translate', '-f', 'French', '-t', 'deu', 'x']),
        0,
      );
      final request = capturedRequest();
      expect(request.source, french);
      expect(request.target, german);
    });

    test('rejects languages the engine does not support', () async {
      final code = await h.run(['translate', '-t', 'Pirate speak', 'x']);
      expect(code, ExitCode.usage.code);
      expect(h.stderr, contains('Google does not support "Pirate speak"'));
      expect(h.stderr, contains('Free-form targets need an AI engine'));
    });

    test('rejects unsupported source languages', () async {
      final code = await h.run(['translate', '-f', 'Klingon', 'x']);
      expect(code, ExitCode.usage.code);
      expect(h.stderr, contains('as a source language'));
      expect(h.stderr, contains('--source'));
    });

    test('uses the configured instance, engine and target', () async {
      h.writeConfig(
        const CliConfig(
          instance: 'https://mozhi.example.org',
          engine: 'deepl',
          target: 'de',
        ),
      );
      expect(await h.run(['translate', 'x']), 0);
      final engine =
          verify(
                () => h.repository.translate(captureAny(), any()),
              ).captured.single
              as TranslationEngine;
      expect(engine.id, 'mozhi:deepl');
      verify(
        () => h.repository.updateConfiguration(
          instances: const [MozhiInstance(url: 'https://mozhi.example.org')],
          providers: const [],
        ),
      ).called(1);
    });

    test('--instance overrides the configured instance', () async {
      expect(await h.run(['translate', '-i', 'localhost:3000', 'x']), 0);
      verify(
        () => h.repository.updateConfiguration(
          instances: const [MozhiInstance(url: 'http://localhost:3000')],
          providers: const [],
        ),
      ).called(1);
    });

    test('rejects an invalid instance URL', () async {
      final code = await h.run(['translate', '-i', 'ftp://x', 'x']);
      expect(code, ExitCode.usage.code);
      expect(h.stderr, contains('Invalid instance URL'));
    });

    test('prints JSON', () async {
      expect(await h.run(['translate', '--json', 'Bonjour']), 0);
      expect(h.json(), {
        'engine': 'mozhi:google',
        'engineName': 'Google',
        'instance': 'https://mozhi.aryak.me',
        'source': 'auto',
        'detectedSource': 'fr',
        'target': 'en',
        'text': 'Hello world',
        'targetTransliteration': 'helo',
        'elapsedMs': 120,
      });
    });

    test('shows a summary on terminals', () async {
      when(() => h.console.stdoutHasTerminal).thenReturn(true);
      expect(await h.run(['translate', 'Bonjour']), 0);
      expect(h.stderr, contains('helo'));
      expect(
        h.stderr,
        contains('Detected French → English · Google (mozhi.aryak.me)'),
      );
      expect(h.stderr, contains('120 ms'));
    });

    test('warns that AI options are ignored by Mozhi engines', () async {
      expect(await h.run(['translate', '--formality', 'more', 'x']), 0);
      expect(h.warnings.single, contains('ignored by Mozhi engines'));
    });

    test('rejects several engines without --compare', () async {
      final code = await h.run(['translate', '-e', 'google,deepl', 'x']);
      expect(code, ExitCode.usage.code);
    });

    test('maps Mozhi errors to exit code 69', () async {
      when(() => h.repository.translate(any(), any())).thenAnswer(
        (_) => Stream.error(
          MozhiApiException(
            'connection refused',
            uri: Uri.parse('https://mozhi.aryak.me/api/translate'),
          ),
        ),
      );
      expect(await h.run(['translate', 'x']), ExitCode.unavailable.code);
      expect(h.stderr, contains('from mozhi.aryak.me: connection refused'));
      expect(h.stderr, contains('mozhi instances ping'));
    });

    group('AI engines', () {
      setUp(() {
        h.writeConfig(
          const CliConfig(
            providers: [ProviderEntry(ollamaProvider)],
          ),
        );
        when(() => h.repository.translate(any(), any())).thenAnswer(
          (_) => Stream.fromIterable(const [
            TranslationResult(
              engineId: 'ai:local',
              engineName: 'Local',
              text: '"Hal',
              isComplete: false,
            ),
            TranslationResult(
              engineId: 'ai:local',
              engineName: 'Local',
              text: '"Hallo"',
              isComplete: false,
            ),
            TranslationResult(
              engineId: 'ai:local',
              engineName: 'Local',
              text: 'Hallo',
            ),
          ]),
        );
      });

      test('passes the options to the model', () async {
        final glossary = File('${h.directory.path}/glossary.tsv')
          ..writeAsStringSync('# terms\ncloud\tWolke\n\nserver=Server\n');
        final code = await h.run([
          'translate',
          '-e',
          'ai',
          '-t',
          'Pirate speak',
          '--formality',
          'prefer-less',
          '--style',
          'literal',
          '--reading-level',
          'b1',
          '--context',
          'a chat',
          '-g',
          'hi=ahoy',
          '--glossary-file',
          glossary.path,
          '--instructions',
          'short',
          'Hello',
        ]);
        expect(code, 0);
        final request = capturedRequest();
        expect(request.target, const Language.custom('Pirate speak'));
        expect(
          request.options,
          const TranslationOptions(
            formality: Formality.preferLess,
            style: TranslationStyle.literal,
            readingLevel: ReadingLevel.b1,
            context: 'a chat',
            glossary: {'cloud': 'Wolke', 'server': 'Server', 'hi': 'ahoy'},
            instructions: 'short',
          ),
        );
        expect(h.out, ['Hallo']);
        verifyNever(() => h.repository.getTargetLanguages(any()));
      });

      test('streams to terminals and redraws the cleaned text', () async {
        h.terminal();
        expect(await h.run(['translate', '-e', 'local', 'Hello']), 0);
        expect(h.written.toString(), '"Hal\r\x1B[JHallo\n');
        expect(h.out, isEmpty);
        expect(h.stderr, contains('Local (gemma3)'));
      });

      test('--no-stream prints only the final text', () async {
        h.terminal();
        expect(
          await h.run(['translate', '-e', 'ai:local', '--no-stream', 'x']),
          0,
        );
        expect(h.written.toString(), isEmpty);
        expect(h.out, ['Hallo']);
      });

      test('erases partial output when the model refuses', () async {
        h.terminal();
        when(() => h.repository.translate(any(), any())).thenAnswer(
          (_) => Stream.fromIterable(const [
            TranslationResult(
              engineId: 'ai:local',
              engineName: 'Local',
              text: 'Hal',
              isComplete: false,
            ),
          ]).followedBy(const LlmRefusalException('no', category: 'cyber')),
        );
        expect(
          await h.run(['translate', '-e', 'ai', 'x']),
          ExitCode.unavailable.code,
        );
        expect(h.written.toString(), 'Hal\r\x1B[J');
        expect(h.stderr, contains('declined the request (cyber)'));
      });

      test('fails when the stream ends without a result', () async {
        h.terminal();
        when(
          () => h.repository.translate(any(), any()),
        ).thenAnswer((_) => const Stream.empty());
        expect(
          await h.run(['translate', '-e', 'ai', 'x']),
          ExitCode.unavailable.code,
        );
        expect(h.stderr, contains('no output'));
      });

      test('reports unknown providers', () async {
        expect(
          await h.run(['translate', '-e', 'ai:nope', 'x']),
          ExitCode.usage.code,
        );
        expect(h.stderr, contains('Configured providers: local'));
      });

      test('reports invalid glossary entries', () async {
        expect(
          await h.run(['translate', '-e', 'ai', '-g', 'oops', 'x']),
          ExitCode.usage.code,
        );
        expect(h.stderr, contains('Invalid glossary entry "oops"'));
      });

      test('reports a missing glossary file', () async {
        expect(
          await h.run([
            'translate',
            '-e',
            'ai',
            '--glossary-file',
            '${h.directory.path}/missing.txt',
            'x',
          ]),
          ExitCode.noInput.code,
        );
      });
    });

    group('--compare', () {
      setUp(() {
        when(
          () => h.repository.getEngines(),
        ).thenAnswer((_) async => [googleEngine, deeplEngine, aiEngineFor()]);
        when(() => h.repository.compare(any(), any())).thenAnswer(
          (_) => Stream.fromIterable([
            const CompareEntry.failure(
              engineId: 'mozhi:deepl',
              engineName: 'DeepL',
              error: MozhiApiException('quota', statusCode: 456),
            ),
            const CompareEntry.success(
              TranslationResult(
                engineId: 'mozhi:google',
                engineName: 'Google',
                text: 'Hola',
                elapsed: Duration(milliseconds: 1500),
              ),
            ),
          ]),
        );
      });

      test('compares every Mozhi engine', () async {
        expect(await h.run(['translate', '-c', '-t', 'es', 'Hi']), 0);
        final engines =
            verify(
                  () => h.repository.compare(captureAny(), any()),
                ).captured.single
                as List<TranslationEngine>;
        expect(engines, [googleEngine, deeplEngine]);
        expect(h.out[0], contains('DeepL'));
        expect(h.out[0], contains('quota'));
        expect(h.out[1], contains('Google'));
        expect(h.out[1], contains('1.5 s'));
        expect(h.out[1], contains('Hola'));
      });

      test('prints JSON in engine order', () async {
        expect(await h.run(['translate', '-c', '--json', 'Hi']), 0);
        expect(h.json(), [
          {
            'engine': 'mozhi:google',
            'engineName': 'Google',
            'ok': true,
            'text': 'Hola',
            'elapsedMs': 1500,
          },
          {
            'engine': 'mozhi:deepl',
            'engineName': 'DeepL',
            'ok': false,
            'error': 'Mozhi instance error (HTTP 456): quota',
          },
        ]);
      });

      test('compares the engines given with --engine', () async {
        expect(
          await h.run(['translate', '-c', '-e', 'yandex', '-e', 'deepl', 'x']),
          0,
        );
        final engines =
            verify(
                  () => h.repository.compare(captureAny(), any()),
                ).captured.single
                as List<TranslationEngine>;
        expect(engines.map((e) => e.id), ['mozhi:yandex', 'mozhi:deepl']);
        verifyNever(() => h.repository.getEngines());
      });

      test('fails with 69 when every engine fails', () async {
        when(() => h.repository.compare(any(), any())).thenAnswer(
          (_) => Stream.value(
            CompareEntry.failure(
              engineId: 'mozhi:google',
              engineName: 'Google',
              error: TimeoutException('slow'),
            ),
          ),
        );
        expect(
          await h.run(['translate', '-c', 'x']),
          ExitCode.unavailable.code,
        );
        expect(h.stderr, contains('Every engine failed.'));
      });

      test('fails when the instance has no engines', () async {
        when(() => h.repository.getEngines()).thenAnswer((_) async => []);
        expect(
          await h.run(['translate', '-c', 'x']),
          ExitCode.unavailable.code,
        );
      });
    });
  });
}

TranslationEngine aiEngineFor() => const TranslationEngine(
  id: 'ai:local',
  kind: EngineKind.ai,
  name: 'Local',
  providerId: 'local',
);
