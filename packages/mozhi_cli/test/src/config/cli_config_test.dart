import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:test/test.dart';

import '../../helpers.dart';

void main() {
  group('ProviderEntry', () {
    test('keeps the API key in JSON', () {
      const entry = ProviderEntry(claudeProvider, apiKeyEnv: 'KEY');
      final json = entry.toJson();
      expect(json['apiKey'], 'sk-stored');
      expect(json['apiKeyEnv'], 'KEY');
      final parsed = ProviderEntry.fromJson(json);
      expect(parsed.config, claudeProvider);
      expect(parsed.apiKeyEnv, 'KEY');
      expect(parsed.keySource, r'$KEY');
    });

    test('ignores empty keys', () {
      final entry = ProviderEntry.fromJson({
        'id': 'x',
        'apiKey': '',
        'apiKeyEnv': '',
      });
      expect(entry.config.apiKey, isNull);
      expect(entry.apiKeyEnv, isNull);
      expect(entry.keySource, 'none');
      expect(entry.toJson(), isNot(contains('apiKey')));
      expect(const ProviderEntry(claudeProvider).keySource, 'stored');
    });

    test('resolves the key from the environment', () {
      const entry = ProviderEntry(claudeProvider, apiKeyEnv: 'KEY');
      expect(entry.resolve({'KEY': ' sk-env '}).apiKey, 'sk-env');
      expect(entry.resolve({'KEY': ' '}).apiKey, 'sk-stored');
      expect(entry.resolve({}).apiKey, 'sk-stored');
      expect(
        const ProviderEntry(ollamaProvider).resolve({'KEY': 'x'}).apiKey,
        isNull,
      );
    });
  });

  group('ConfigKey', () {
    test('parses names and aliases', () {
      expect(ConfigKey.tryParse(' Target '), ConfigKey.target);
      expect(ConfigKey.tryParse('to'), ConfigKey.target);
      expect(ConfigKey.tryParse('from'), ConfigKey.source);
      expect(ConfigKey.tryParse('url'), ConfigKey.instance);
      expect(ConfigKey.tryParse('engine'), ConfigKey.engine);
      expect(ConfigKey.tryParse('nope'), isNull);
    });
  });

  group('CliConfig', () {
    test('round-trips through JSON', () {
      const config = CliConfig(
        instance: 'https://m.example',
        engine: 'mozhi:deepl',
        source: 'fr',
        target: 'de',
        providers: [ProviderEntry(ollamaProvider)],
      );
      final parsed = CliConfig.fromJson(config.toJson());
      expect(parsed.toJson(), config.toJson());
      for (final key in ConfigKey.values) {
        expect(parsed.valueOf(key), config.valueOf(key));
        expect(parsed.withValue(key, null).valueOf(key), isNull);
      }
      expect(parsed.hasSecrets, isFalse);
      expect(
        parsed.withProviders([const ProviderEntry(claudeProvider)]).hasSecrets,
        isTrue,
      );
    });

    test('is tolerant of bad values', () {
      final config = CliConfig.fromJson({
        'instance': 3,
        'target': ' ',
        'providers': 'x',
      });
      expect(config.toJson(), isEmpty);
      expect(
        CliConfig.fromJson({
          'providers': [
            1,
            {'id': 'a'},
          ],
        }).providers.single.id,
        'a',
      );
    });

    test('finds providers by id, then name', () {
      const config = CliConfig(
        providers: [
          ProviderEntry(claudeProvider),
          ProviderEntry(ollamaProvider),
        ],
      );
      expect(config.findProvider('CLAUDE')?.id, 'claude');
      expect(config.findProvider('local')?.id, 'local');
      expect(config.findProvider('Local')?.id, 'local');
      expect(config.findProvider('none'), isNull);
    });
  });
}
