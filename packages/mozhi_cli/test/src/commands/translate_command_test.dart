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
      when(() => h.repository.getTargetLanguages(any()))
          .thenAnswer((_) async => [english, french, german]);
      when(() => h.repository.getSourceLanguages(any()))
          .thenAnswer((_) async => [Language.auto, english, french, german]);
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
        verify(() => h.repository.translate(any(), captureAny()))
                .captured
                .single
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
      expect(await h.run(['translate', '-f', 'French', '-t', 'deu', 'x']), 0);
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
          verify(() => h.repository.translate(captureAny(), any()))
                  .captured
                  .single
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
        'instance': MozhiInstance.publicInstances.first.url,
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
      final host = Uri.parse(MozhiInstance.publicInstances.first.url).host;
      expect(h.stderr, contains('Detected French → English · Google ($host)'));
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
          const CliConfig(providers: [ProviderEntry(ollamaProvider)]),
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
        expect(h.written.toString(), '"Hallo"\r\x1B[JHallo\n');
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
        Stream<TranslationResult> refuse() async* {
          yield const TranslationResult(
            engineId: 'ai:local',
            engineName: 'Local',
            text: 'Hal',
            isComplete: false,
          );
          throw const LlmRefusalException('no', category: 'cyber');
        }

        when(() => h.repository.translate(any(), any()))
            .thenAnswer((_) => refuse());
        expect(
          await h.run(['translate', '-e', 'ai', 'x']),
          ExitCode.unavailable.code,
        );
        expect(h.written.toString(), 'Hal\r\x1B[J');
        expect(h.stderr, contains('declined the request (cyber)'));
      });

      test('fails when the stream ends without a result', () async {
        h.terminal();
        when(() => h.repository.translate(any(), any()))
            .thenAnswer((_) => const Stream.empty());
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

      test(
        'wires formality-context, speaker/addressee gender and saved glossary',
        () async {
          h.writeConfig(
            const CliConfig(
              providers: [ProviderEntry(ollamaProvider)],
              glossary: {'cloud': 'Wolke', 'hi': 'servus'},
            ),
          );
          final code = await h.run([
            'translate',
            '-e',
            'ai',
            '--formality',
            'more',
            '--formality-context',
            'email to my professor',
            '--speaker-gender',
            'feminine',
            '--addressee-gender',
            'masculine',
            '-g',
            'hi=guten Tag',
            'Hello',
          ]);
          expect(code, 0);
          final request = capturedRequest();
          expect(request.options.formality, Formality.more);
          expect(request.options.formalityContext, 'email to my professor');
          expect(request.options.speakerGender, Gender.feminine);
          expect(request.options.addresseeGender, Gender.masculine);
          expect(request.options.glossary, {
            'cloud': 'Wolke',
            'hi': 'guten Tag',
          });
        },
      );

      test('supports --alternatives, --explain, --insights, --romanize '
          'in terminal and JSON', () async {
        when(() => h.repository.getAlternatives(any(), any(), any()))
            .thenAnswer(
              (_) async => const AlternativeTranslations(
                description: 'Standard polite greeting.',
                alternatives: [
                  Alternative(text: 'Guten Tag', explanation: 'more formal'),
                ],
              ),
            );
        when(() => h.repository.getInsights(any(), any(), any())).thenAnswer(
          (_) async => const [
            WordInsight(
              sourceText: 'Hello',
              targetText: 'Hallo',
              explanation: 'Casual greeting.',
              variations: [Alternative(text: 'Hi', explanation: 'informal')],
            ),
          ],
        );
        when(() => h.repository.explain(any(), any(), any()))
            .thenAnswer((_) => Stream.fromIterable(['A common ', 'greeting.']));
        when(
          () => h.repository.romanize(
            any(),
            text: any(named: 'text'),
            language: any(named: 'language'),
          ),
        ).thenAnswer((_) async => 'ha-lo');
        when(
          () => h.repository.checkMeaning(
            any(),
            source: any(named: 'source'),
            translation: any(named: 'translation'),
            sourceLanguage: any(named: 'sourceLanguage'),
            targetLanguage: any(named: 'targetLanguage'),
          ),
        ).thenAnswer(
          (_) async => const MeaningCheck(
            verdict: MeaningVerdict.minor,
            backTranslation: 'Hi',
            issues: [
              MeaningIssue(
                type: MeaningIssueType.omission,
                problem: 'Slightly more casual.',
                suggestion: 'Guten Tag',
              ),
            ],
          ),
        );

        final code = await h.run([
          'translate',
          '-e',
          'ai',
          '--alternatives',
          '--insights',
          '--explain',
          '--romanize',
          '--check-meaning',
          'Hello',
        ]);
        expect(code, 0);
        expect(h.stdout, contains('Hallo'));
        expect(h.stdout, contains('Meaning check:'));
        expect(h.stdout, contains('Minor differences'));
        expect(h.stdout, contains('Back-translation: Hi'));
        expect(h.stdout, contains('Slightly more casual.'));
        expect(h.stdout, contains('Romanization:'));
        expect(h.stdout, contains('ha-lo'));
        expect(h.stdout, contains('Alternatives:'));
        expect(h.stdout, contains('Guten Tag'));
        expect(h.stdout, contains('Insights:'));
        expect(h.stdout, contains('Casual greeting.'));
        expect(h.stdout, contains('Explanation:'));
        expect(h.stdout, contains('A common greeting.'));

        h.out.clear();
        final jsonCode = await h.run([
          'translate',
          '-e',
          'ai',
          '--json',
          '--alternatives',
          '--insights',
          '--explain',
          '--romanize',
          'Hello',
        ]);
        expect(jsonCode, 0);
        final json = h.json()! as Map<String, Object?>;
        expect(json['romanization'], 'ha-lo');
        expect(json['explanation'], 'A common greeting.');
        expect(json['alternatives'], isA<Map<String, Object?>>());
        expect(json['insights'], hasLength(1));
      });

      test('rejects AI extras on Mozhi engines or with --compare', () async {
        expect(
          await h.run(['translate', '-e', 'google', '--explain', 'Hello']),
          ExitCode.usage.code,
        );
        expect(h.stderr, contains('require an AI provider'));

        h.err.clear();
        expect(
          await h.run(['translate', '--compare', '--alternatives', 'Hello']),
          ExitCode.usage.code,
        );
        expect(h.stderr, contains('cannot be used with --compare'));
      });

      test('translates with a direct MT provider', () async {
        h.writeConfig(
          const CliConfig(providers: [ProviderEntry(deeplMtProvider)]),
        );
        final code = await h.run([
          'translate',
          '-e',
          'mt',
          '--formality',
          'more',
          '-t',
          'de',
          'Hello',
        ]);
        expect(code, 0);
        final captured = verify(
          () => h.repository.translate(captureAny(), captureAny()),
        ).captured;
        expect((captured[0] as TranslationEngine).id, 'mt:deepl-api');
        expect(
          (captured[1] as TranslationRequest).options.formality,
          Formality.more,
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
            verify(() => h.repository.compare(captureAny(), any()))
                    .captured
                    .single
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
            verify(() => h.repository.compare(captureAny(), any()))
                    .captured
                    .single
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
