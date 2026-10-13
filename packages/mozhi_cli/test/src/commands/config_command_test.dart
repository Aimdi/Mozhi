import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:test/test.dart';

import '../../helpers.dart';

void main() {
  setUpAll(registerFallbacks);

  group('config', () {
    late Harness h;

    setUp(() => h = Harness());
    tearDown(() => h.dispose());

    test('path prints the file location', () async {
      expect(await h.run(['config', 'path']), 0);
      expect(h.out, [h.configPath]);
    });

    test('show prints defaults when there is no file', () async {
      expect(await h.run(['config', 'show']), 0);
      expect(h.stdout, contains('(not created yet)'));
      expect(h.stdout, contains('public instances, with failover'));
      expect(h.stdout, contains('mozhi:google'));
      expect(h.stdout, contains('No AI providers'));
    });

    test('show lists providers and warns about exposed files', () async {
      h.writeConfig(
        const CliConfig(
          target: 'de',
          engine: 'ai:claude',
          providers: [
            ProviderEntry(claudeProvider),
            ProviderEntry(ollamaProvider, apiKeyEnv: 'OLLAMA_KEY'),
          ],
        ),
      );
      Process.runSync('chmod', ['644', h.configPath]);
      expect(await h.run(['config', 'show']), 0);
      expect(h.stdout, contains('claude *'));
      expect(h.stdout, contains(r'$OLLAMA_KEY'));
      expect(h.stdout, contains('stored'));
      expect(h.stdout, isNot(contains('sk-stored')));
      expect(h.warnings.single, contains('readable by other users'));
    });

    test('show --json hides API keys', () async {
      h.writeConfig(
        const CliConfig(providers: [ProviderEntry(claudeProvider)]),
      );
      expect(await h.run(['config', 'show', '--json']), 0);
      final json = h.json()! as Map<String, Object?>;
      expect(json['path'], h.configPath);
      final providers = json['providers']! as List<Object?>;
      expect(providers.single, containsPair('apiKey', '********'));
    });

    group('set', () {
      test('normalises and stores values', () async {
        expect(await h.run(['config', 'set', 'instance', 'mozhi.home']), 0);
        expect(await h.run(['config', 'set', 'engine', 'deepl']), 0);
        expect(await h.run(['config', 'set', 'from', 'French']), 0);
        expect(await h.run(['config', 'set', 'to', 'Pirate', 'speak']), 0);
        final config = h.readConfig();
        expect(config.instance, 'https://mozhi.home');
        expect(config.engine, 'mozhi:deepl');
        expect(config.source, 'fr');
        expect(config.target, 'Pirate speak');
        expect(h.out, [
          'Set instance to https://mozhi.home.',
          'Set engine to mozhi:deepl (DeepL).',
          'Set source to fr (French).',
          'Set target to Pirate speak.',
        ]);
      });

      test('creates the file with owner-only permissions', () async {
        expect(await h.run(['config', 'set', 'target', 'ja']), 0);
        final mode = File(h.configPath).statSync().mode & 0x1ff;
        expect(mode, 0x180); // 0600
        final directory = Directory(File(h.configPath).parent.path);
        expect(directory.statSync().mode & 0x1ff, 0x1c0); // 0700
        expect(h.chmods.map((c) => c.$2), ['700', '600']);
      });

      test('rejects unknown keys and missing values', () async {
        expect(
          await h.run(['config', 'set', 'colour', 'red']),
          ExitCode.usage.code,
        );
        expect(h.stderr, contains('Unknown setting "colour"'));
        expect(await h.run(['config', 'set', 'target']), ExitCode.usage.code);
      });

      test('rejects auto as the target', () async {
        expect(
          await h.run(['config', 'set', 'target', 'auto']),
          ExitCode.usage.code,
        );
      });
    });

    test('unset resets a value', () async {
      h.writeConfig(const CliConfig(target: 'de', source: 'fr'));
      expect(await h.run(['config', 'unset', 'target']), 0);
      expect(h.readConfig().target, isNull);
      expect(h.readConfig().source, 'fr');
      expect(await h.run(['config', 'unset']), ExitCode.usage.code);
    });

    test('reports malformed files with exit code 78', () async {
      File(h.configPath)
        ..createSync(recursive: true)
        ..writeAsStringSync('{oops');
      expect(await h.run(['config', 'show']), ExitCode.config.code);
      expect(h.stderr, contains('is not valid'));
    });
  });
}
