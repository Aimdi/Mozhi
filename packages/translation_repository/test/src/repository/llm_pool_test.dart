import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:translation_repository/src/repository/llm_pool.dart';
import 'package:translation_repository/translation_repository.dart';

import 'test_helpers.dart';

void main() {
  group(LlmPool, () {
    late List<MockLlmClient> built;
    late List<Uri> endpoints;
    late LlmPool pool;

    setUp(() {
      built = [];
      endpoints = [];
      pool = LlmPool((endpoint) {
        endpoints.add(endpoint.baseUrl);
        final client = MockLlmClient();
        built.add(client);
        return client;
      });
    });

    group('clientFor', () {
      test('creates the client from the config endpoint once', () {
        final first = pool.clientFor(claudeConfig);
        final second = pool.clientFor(claudeConfig);
        expect(first, same(second));
        expect(built, hasLength(1));
        expect(endpoints, [Uri.parse(claudeConfig.baseUrl)]);
      });

      test('keeps one client per provider id', () {
        final claude = pool.clientFor(claudeConfig);
        final openAi = pool.clientFor(openAiConfig);
        expect(claude, isNot(same(openAi)));
        expect(pool.clientFor(claudeConfig), same(claude));
        expect(pool.clientFor(openAiConfig), same(openAi));
      });

      test('reuses the client when only request settings change', () {
        final client = pool.clientFor(claudeConfig);
        final changed = claudeConfig.copyWith(
          model: 'claude-haiku-5-5',
          temperature: 1,
          effort: 'high',
          name: 'Renamed',
        );
        expect(pool.clientFor(changed), same(client));
        verifyNever(client.close);
      });

      test('replaces and closes the client when the connection changes', () {
        final client = pool.clientFor(claudeConfig);
        final replaced = pool.clientFor(claudeConfig.copyWith(apiKey: 'new'));
        expect(replaced, isNot(same(client)));
        verify(client.close).called(1);
      });
    });

    group('update', () {
      test('closes clients of removed providers', () {
        final claude = pool.clientFor(claudeConfig);
        final openAi = pool.clientFor(openAiConfig);
        pool.update([openAiConfig]);
        verify(claude.close).called(1);
        verifyNever(openAi.close);
        expect(pool.clientFor(openAiConfig), same(openAi));
      });

      test('closes clients whose connection settings changed', () {
        final claude = pool.clientFor(claudeConfig);
        pool.update([claudeConfig.copyWith(baseUrl: 'https://proxy/v1')]);
        verify(claude.close).called(1);
        expect(pool.clientFor(claudeConfig), isNot(same(claude)));
      });

      test('keeps clients whose settings did not change', () {
        final claude = pool.clientFor(claudeConfig);
        pool.update([claudeConfig.copyWith(model: 'other', enabled: false)]);
        verifyNever(claude.close);
      });
    });

    group('withTemporaryClient', () {
      test('uses an uncached client and closes it', () async {
        final cached = pool.clientFor(claudeConfig);
        final used = await pool.withTemporaryClient(
          claudeConfig,
          (client) async => client,
        );
        expect(used, isNot(same(cached)));
        verify((used as MockLlmClient).close).called(1);
        verifyNever(cached.close);
      });

      test('closes the client when the action fails', () async {
        await expectLater(
          pool.withTemporaryClient<void>(
            claudeConfig,
            (client) async => throw const LlmApiException('nope'),
          ),
          throwsA(isA<LlmApiException>()),
        );
        verify(built.single.close).called(1);
      });
    });

    test('dispose closes every cached client', () {
      final claude = pool.clientFor(claudeConfig);
      final openAi = pool.clientFor(openAiConfig);
      pool.dispose();
      verify(claude.close).called(1);
      verify(openAi.close).called(1);
    });

    group('connectionKey', () {
      test('ignores header order', () {
        final a = claudeConfig.copyWith(headers: {'a': '1', 'b': '2'});
        final b = claudeConfig.copyWith(headers: {'b': '2', 'a': '1'});
        expect(LlmPool.connectionKey(a), LlmPool.connectionKey(b));
      });

      test('changes with protocol, URL, key and headers', () {
        final base = LlmPool.connectionKey(claudeConfig);
        for (final changed in [
          claudeConfig.copyWith(provider: LlmProvider.openAiCompatible),
          claudeConfig.copyWith(baseUrl: 'https://other/v1'),
          claudeConfig.copyWith(apiKey: 'other'),
          claudeConfig.copyWith(headers: {'x': 'y'}),
        ]) {
          expect(LlmPool.connectionKey(changed), isNot(base));
        }
      });
    });
  });
}
