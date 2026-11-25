import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi_cli/src/commands/repl_command.dart';
import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers.dart';

void main() {
  setUpAll(registerFallbacks);

  group('repl', () {
    late Harness h;

    setUp(() {
      h = Harness()
        ..writeConfig(
          const CliConfig(
            providers: [
              ProviderEntry(ollamaProvider),
              ProviderEntry(deeplMtProvider),
            ],
            glossary: {'cloud': 'Wolke'},
          ),
        );
      when(() => h.repository.translate(any(), any())).thenAnswer((invocation) {
        final engine = invocation.positionalArguments[0] as TranslationEngine;
        final req = invocation.positionalArguments[1] as TranslationRequest;
        return Stream.value(
          TranslationResult(
            engineId: engine.id,
            engineName: engine.name,
            text:
                '[${engine.id} ${req.source.code}->${req.target.code}] '
                '${req.text}',
            detectedSource: req.source.isAuto ? 'fr' : null,
          ),
        );
      });
      when(
        () => h.repository.proofread(
          any(),
          any(),
          formality: any(named: 'formality'),
        ),
      ).thenAnswer(
        (_) async => const ProofreadResult(
          correctedText: 'He goes home.',
          edits: [ProofreadEdit(original: 'go', replacement: 'goes')],
        ),
      );
      when(
        () => h.repository.lookUp(
          any(),
          any(),
          source: any(named: 'source'),
          target: any(named: 'target'),
        ),
      ).thenAnswer(
        (_) async => const DictionaryEntry(
          word: 'maison',
          senses: [
            DictionarySense(definition: 'A building for human habitation.'),
          ],
        ),
      );
    });

    tearDown(() => h.dispose());

    test(
      'handles translation lines and all slash commands via stdin stream',
      () async {
        when(() => h.console.readLines()).thenAnswer(
          (_) => Stream.fromIterable([
            '/help',
            '/status',
            'Bonjour',
            '/swap',
            '/from de',
            '/to es',
            '/swap',
            '/engine ai',
            '/formality more',
            '/style literal',
            '/context Technical documentation',
            '/glossary list',
            '/glossary add widget=Komponente',
            'Hola mundo',
            '/glossary remove cloud',
            '/glossary clear',
            '/context clear',
            '/proofread He go home.',
            '/dict maison',
            '/unknown',
            '/quit',
            'should not run after quit',
          ]),
        );

        final code = await h.run(['repl', '-t', 'en']);
        expect(code, ExitCode.success.code);

        final out = h.stdout;
        expect(out, contains('Mozhi interactive session'));
        expect(out, contains('/from <code>'));
        expect(out, contains('/glossary <cmd>'));
        expect(out, contains('Engine: mozhi:google'));
        expect(out, contains('Glossary: 1 term'));
        expect(out, contains('[mozhi:google auto->en] Bonjour'));
        // Swap after auto-detect uses detected 'fr' -> en->fr
        expect(out, contains('Swapped languages: en → fr.'));
        expect(out, contains('Source language set to de (German).'));
        expect(out, contains('Target language set to es (Spanish).'));
        expect(out, contains('Swapped languages: es → de.'));
        expect(out, contains('Engine set to ai:local (Local).'));
        expect(out, contains('Formality set to more.'));
        expect(out, contains('Style set to literal.'));
        expect(out, contains('Context set to "Technical documentation".'));
        expect(out, contains('cloud → Wolke'));
        expect(out, contains('Glossary term set: widget → Komponente'));
        expect(out, contains('[ai:local es->de] Hola mundo'));
        expect(out, contains('Removed glossary term "cloud".'));
        expect(out, contains('Glossary cleared.'));
        expect(out, contains('Context cleared.'));
        expect(out, contains('He goes home.'));
        expect(out, contains('go → goes'));
        expect(out, contains('A building for human habitation.'));
        expect(out, contains('Unknown command "/unknown"'));
        expect(out, contains('Bye.'));
        expect(out, isNot(contains('should not run after quit')));

        final captured = verify(
          () => h.repository.translate(any(), captureAny()),
        ).captured.cast<TranslationRequest>();
        final aiReq = captured.last;
        expect(aiReq.options.style, TranslationStyle.literal);
        expect(aiReq.options.formality, Formality.more);
        expect(aiReq.options.context, 'Technical documentation');
        expect(aiReq.options.glossary, {
          'cloud': 'Wolke',
          'widget': 'Komponente',
        });
      },
    );

    test('ReplSession works with directly injected streams and recovers '
        'from errors', () async {
      when(() => h.repository.translate(any(), any())).thenAnswer(
        (_) => Stream.error(
          const MozhiApiException('server down', statusCode: 503),
        ),
      );
      final buffer = StringBuffer();
      final session = ReplSession(
        repository: h.repository,
        config: const CliConfig(),
        providers: const [ollamaProvider],
        engine: googleEngine,
        source: Language.auto,
        target: english,
        output: buffer,
        showPrompt: true,
      );

      await session.run(
        Stream.fromIterable([
          '/swap',
          'Hello',
          '/engine mt:missing',
          '/status',
        ]),
      );

      final out = buffer.toString();
      expect(out, contains('Cannot swap while source is "auto"'));
      expect(
        out,
        contains('Error: Mozhi instance error (HTTP 503): server down'),
      );
      expect(out, contains('Error: No direct MT provider is configured.'));
      expect(out, contains('[auto→en] > '));
    });
  });
}
