import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers.dart';

void main() {
  setUpAll(registerFallbacks);

  group('config providers', () {
    late Harness h;

    setUp(() => h = Harness());
    tearDown(() => h.dispose());

    group('add', () {
      test('adds a preset with a key from the environment', () async {
        final code = await h.run([
          'config',
          'providers',
          'add',
          '--preset',
          'anthropic',
          '--api-key-env',
          'ANTHROPIC_API_KEY',
          '--default',
        ]);
        expect(code, 0);
        final config = h.readConfig();
        expect(config.engine, 'ai:anthropic');
        final entry = config.providers.single;
        expect(entry.apiKeyEnv, 'ANTHROPIC_API_KEY');
        expect(entry.config.provider, LlmProvider.anthropic);
        expect(entry.config.model, 'claude-opus-5-5');
        expect(entry.config.effort, 'low');
        expect(entry.config.apiKey, isNull);
        expect(h.stdout, contains('Added Anthropic (claude-opus-5-5)'));
        expect(h.warnings.single, contains(r'$ANTHROPIC_API_KEY is not set'));
      });

      test('reads the key from standard input', () async {
        h.pipe('sk-secret\n');
        expect(
          await h.run([
            'config',
            'providers',
            'add',
            '-p',
            'openai',
            '--name',
            'Work GPT',
            '--api-key-stdin',
          ]),
          0,
        );
        final entry = h.readConfig().providers.single;
        expect(entry.id, 'work-gpt');
        expect(entry.config.apiKey, 'sk-secret');
      });

      test('prompts for the key on terminals', () async {
        when(() => h.logger.prompt(any(), hidden: true)).thenReturn('sk-typed');
        expect(await h.run(['config', 'providers', 'add', '-p', 'gemini']), 0);
        expect(h.readConfig().providers.single.config.apiKey, 'sk-typed');
      });

      test('warns when a required key is skipped', () async {
        when(() => h.logger.prompt(any(), hidden: true)).thenReturn('');
        expect(await h.run(['config', 'providers', 'add', '-p', 'groq']), 0);
        expect(h.warnings.single, contains('usually needs an API key'));
      });

      test('adds a custom provider with headers and options', () async {
        final code = await h.run([
          'config',
          'providers',
          'add',
          '--protocol',
          'openai',
          '--name',
          'vLLM',
          '--base-url',
          'http://gpu.lan:8000/v1',
          '--model',
          'qwen3',
          '--api-key',
          'k',
          '--temperature',
          '0.2',
          '--effort',
          'high',
          '--header',
          'X-Team: mozhi',
          '--vision',
        ]);
        expect(code, 0);
        final provider = h.readConfig().providers.single.config;
        expect(provider.id, 'vllm');
        expect(provider.provider, LlmProvider.openAiCompatible);
        expect(provider.temperature, 0.2);
        expect(provider.effort, 'high');
        expect(provider.headers, {'X-Team': 'mozhi'});
        expect(provider.supportsVision, isTrue);
        expect(provider.apiKey, 'k');
      });

      test('picks the first model of local servers', () async {
        when(() => h.repository.listModels(any())).thenAnswer(
          (_) async => const [LlmModel(id: 'qwen3-8b'), LlmModel(id: 'x')],
        );
        expect(
          await h.run(['config', 'providers', 'add', '-p', 'lmstudio']),
          0,
        );
        expect(h.readConfig().providers.single.config.model, 'qwen3-8b');
        expect(h.stdout, contains('Using model qwen3-8b (2 available'));
        verify(() => h.repository.dispose()).called(1);
      });

      test('asks for --model when the server has none', () async {
        when(() => h.repository.listModels(any()))
            .thenAnswer((_) async => const []);
        expect(
          await h.run(['config', 'providers', 'add', '-p', 'llamacpp']),
          ExitCode.usage.code,
        );
        when(() => h.repository.listModels(any()))
            .thenThrow(const LlmApiException('refused'));
        expect(
          await h.run(['config', 'providers', 'add', '-p', 'llamacpp']),
          ExitCode.usage.code,
        );
        expect(h.stderr, contains('Pass --model'));
      });

      test('validates the arguments', () async {
        Future<int> add(List<String> args) =>
            h.run(['config', 'providers', 'add', ...args]);
        expect(await add([]), ExitCode.usage.code);
        expect(await add(['--protocol', 'openai']), ExitCode.usage.code);
        expect(
          await add(['--protocol', 'openai', '--name', '!!']),
          ExitCode.usage.code,
        );
        expect(
          await add(['--protocol', 'openai', '--name', 'x']),
          ExitCode.usage.code,
        );
        expect(
          await add(['-p', 'ollama', '--temperature', 'hot']),
          ExitCode.usage.code,
        );
        expect(
          await add(['-p', 'ollama', '--header', 'nocolon']),
          ExitCode.usage.code,
        );
        h.pipe('');
        expect(
          await add(['-p', 'openai', '--api-key-stdin']),
          ExitCode.usage.code,
        );
      });

      test('refuses to replace a provider without --force', () async {
        h.writeConfig(
          const CliConfig(providers: [ProviderEntry(ollamaProvider)]),
        );
        final args = [
          'config',
          'providers',
          'add',
          '-p',
          'ollama',
          '--id',
          'local',
        ];
        expect(await h.run(args), ExitCode.usage.code);
        expect(h.stderr, contains('already exists'));
        expect(await h.run([...args, '--force', '--model', 'qwen3']), 0);
        expect(h.readConfig().providers.single.config.model, 'qwen3');
        expect(h.stdout, contains('Replaced Ollama'));
      });
    });

    test('list shows a table, JSON or a hint', () async {
      expect(await h.run(['config', 'providers', 'list']), 0);
      expect(h.stdout, contains('No AI providers'));
      h.writeConfig(
        const CliConfig(
          providers: [
            ProviderEntry(claudeProvider),
            ProviderEntry(
              AiProviderConfig(
                id: 'off',
                name: 'Off',
                provider: LlmProvider.gemini,
                baseUrl: 'x',
                model: 'm',
                enabled: false,
              ),
            ),
          ],
        ),
      );
      h.out.clear();
      expect(await h.run(['config', 'providers', 'ls']), 0);
      expect(h.stdout, contains('anthropic'));
      expect(h.stdout, contains('off (disabled)'));
      h.out.clear();
      expect(await h.run(['config', 'providers', 'list', '--json']), 0);
      final json = h.json()! as List<Object?>;
      expect(json.first, containsPair('apiKeySource', 'stored'));
      expect(json.first, isNot(contains('apiKey')));
    });

    test('remove deletes the provider and resets the default', () async {
      h.writeConfig(
        const CliConfig(
          engine: 'ai:claude',
          providers: [
            ProviderEntry(claudeProvider),
            ProviderEntry(ollamaProvider),
          ],
        ),
      );
      expect(await h.run(['config', 'providers', 'rm', 'Claude']), 0);
      final config = h.readConfig();
      expect(config.engine, isNull);
      expect(config.providers.map((p) => p.id), ['local']);
      expect(h.stdout, contains('It was the default engine'));
      expect(
        await h.run(['config', 'providers', 'remove', 'claude']),
        ExitCode.usage.code,
      );
      expect(h.stderr, contains('Configured: local'));
      expect(
        await h.run(['config', 'providers', 'remove']),
        ExitCode.usage.code,
      );
    });

    test('test sends a test translation with the resolved key', () async {
      h
        ..writeConfig(
          const CliConfig(
            providers: [ProviderEntry(claudeProvider, apiKeyEnv: 'KEY')],
          ),
        )
        ..environment['KEY'] = 'sk-env';
      when(() => h.repository.testProvider(any()))
          .thenAnswer((_) async => 'Bonjour, le monde !');
      expect(await h.run(['config', 'providers', 'test', 'claude']), 0);
      final config =
          verify(() => h.repository.testProvider(captureAny())).captured.single
              as AiProviderConfig;
      expect(config.apiKey, 'sk-env');
      expect(h.stdout, contains('Claude works'));
      expect(h.stdout, contains('Bonjour, le monde !'));
    });

    test('test reports authentication errors', () async {
      h.writeConfig(
        const CliConfig(providers: [ProviderEntry(claudeProvider)]),
      );
      when(
        () => h.repository.testProvider(any()),
      ).thenThrow(const LlmApiException('invalid x-api-key', statusCode: 401));
      expect(
        await h.run(['config', 'providers', 'test', 'claude']),
        ExitCode.unavailable.code,
      );
      expect(h.stderr, contains('AI provider error (HTTP 401)'));
      expect(h.stderr, contains('Check the API key'));
      verify(() => h.repository.dispose()).called(1);
    });

    test('models lists the models of a provider', () async {
      h.writeConfig(
        const CliConfig(providers: [ProviderEntry(ollamaProvider)]),
      );
      when(() => h.repository.listModels(any())).thenAnswer(
        (_) async => const [
          LlmModel(id: 'gemma3', displayName: 'Gemma 3'),
          LlmModel(id: 'qwen3', contextWindow: 32768),
        ],
      );
      expect(await h.run(['config', 'providers', 'models', 'local']), 0);
      expect(h.stdout, contains('gemma3 *'));
      expect(h.stdout, contains('Gemma 3'));
      h.out.clear();
      expect(
        await h.run(['config', 'providers', 'models', 'local', '--json']),
        0,
      );
      expect(h.json(), [
        {'id': 'gemma3', 'name': 'Gemma 3'},
        {'id': 'qwen3', 'contextWindow': 32768},
      ]);
      when(() => h.repository.listModels(any()))
          .thenAnswer((_) async => const []);
      h.out.clear();
      expect(await h.run(['config', 'providers', 'models', 'local']), 0);
      expect(h.stdout, contains('did not report any models'));
    });
  });
}
