import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers.dart';

void main() {
  setUpAll(() {
    registerFallbacks();
    registerFallbackValue(WritingTone.automatic);
  });

  group('proofread', () {
    late Harness h;

    const result = ProofreadResult(
      correctedText: 'I have a cat.',
      detectedLanguage: 'en',
      summary: 'Clear and simple.',
      edits: [
        ProofreadEdit(
          original: 'has',
          replacement: 'have',
          explanation: 'Subject-verb agreement.',
        ),
        ProofreadEdit(
          original: ' really',
          replacement: '',
          category: 'word_choice',
        ),
      ],
    );

    setUp(() {
      h = Harness()
        ..writeConfig(
          const CliConfig(
            providers: [
              ProviderEntry(ollamaProvider),
              ProviderEntry(claudeProvider),
            ],
          ),
        );
      when(
        () => h.repository.proofread(
          any(),
          any(),
          style: any(named: 'style'),
          level: any(named: 'level'),
          formality: any(named: 'formality'),
          context: any(named: 'context'),
          tone: any(named: 'tone'),
        ),
      ).thenAnswer((_) async => result);
    });

    tearDown(() => h.dispose());

    setUpAll(() {
      registerFallbackValue(WritingStyle.general);
      registerFallbackValue(CorrectionLevel.standard);
      registerFallbackValue(Formality.automatic);
    });

    test('prints the corrected text and the changes', () async {
      expect(await h.run(['proofread', 'I has a really cat.']), 0);
      expect(h.out.first, 'I have a cat.');
      expect(h.stdout, contains('2 changes:'));
      expect(h.stdout, contains('has → have'));
      expect(h.stdout, contains('(grammar)'));
      expect(h.stdout, contains('Subject-verb agreement.'));
      expect(h.stdout, contains('-  really'));
      expect(h.stdout, contains('(word choice)'));
      expect(h.stdout, contains('Clear and simple.'));
      final engine =
          verify(
                () =>
                    h.repository.proofread(captureAny(), 'I has a really cat.'),
              ).captured.single
              as TranslationEngine;
      expect(engine.id, 'ai:local');
    });

    test('passes options and uses the default AI engine', () async {
      h.writeConfig(h.readConfig().withValue(ConfigKey.engine, 'ai:claude'));
      final code = await h.run([
        'proofread',
        '--style',
        'email',
        '--level',
        'light',
        '--formality',
        'more',
        '--context',
        'to my boss',
        '-q',
        'x',
      ]);
      expect(code, 0);
      expect(h.out, ['I have a cat.']);
      final engine =
          verify(
                () => h.repository.proofread(
                  captureAny(),
                  'x',
                  style: WritingStyle.email,
                  level: CorrectionLevel.light,
                  formality: Formality.more,
                  context: 'to my boss',
                ),
              ).captured.single
              as TranslationEngine;
      expect(engine.id, 'ai:claude');
    });

    test('passes the tone', () async {
      expect(
        await h.run(['proofread', '--tone', 'diplomatic', '-e', 'claude', 'x']),
        0,
      );
      verify(
        () => h.repository.proofread(any(), 'x', tone: WritingTone.diplomatic),
      ).called(1);
    });

    test('keeps the tone by default', () async {
      expect(await h.run(['proofread', '-e', 'claude', 'x']), 0);
      verify(() => h.repository.proofread(any(), 'x')).called(1);
    });

    test('rejects an unknown tone', () async {
      expect(await h.run(['proofread', '--tone', 'grumpy', 'x']), isNot(0));
    });

    test('prints JSON', () async {
      expect(await h.run(['proofread', '--json', '-e', 'claude', 'x']), 0);
      expect(h.json(), {
        'correctedText': 'I have a cat.',
        'detectedLanguage': 'en',
        'summary': 'Clear and simple.',
        'edits': [
          {
            'original': 'has',
            'replacement': 'have',
            'category': 'grammar',
            'explanation': 'Subject-verb agreement.',
          },
          {'original': ' really', 'replacement': '', 'category': 'word_choice'},
        ],
      });
    });

    test('says when nothing needs to change', () async {
      when(
        () => h.repository.proofread(
          any(),
          any(),
          style: any(named: 'style'),
          level: any(named: 'level'),
          formality: any(named: 'formality'),
          context: any(named: 'context'),
        ),
      ).thenAnswer((_) async => const ProofreadResult(correctedText: 'Fine.'));
      expect(await h.run(['proofread', 'Fine.']), 0);
      expect(h.stdout, contains('No changes needed.'));
    });

    test('rejects Mozhi engines', () async {
      expect(
        await h.run(['proofread', '-e', 'google', 'x']),
        ExitCode.usage.code,
      );
      expect(h.stderr, contains('needs an AI provider, not Google'));
    });

    test('needs a provider', () async {
      h.writeConfig(const CliConfig(engine: 'deepl'));
      expect(await h.run(['proofread', 'x']), ExitCode.usage.code);
      expect(h.stderr, contains('none is configured'));
    });
  });
}
