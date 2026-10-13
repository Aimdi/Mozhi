import 'dart:async';

import 'package:mocktail/mocktail.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:test/test.dart';
import 'package:translation_repository/src/repository/mozhi_pool.dart';
import 'package:translation_repository/translation_repository.dart';

import 'test_helpers.dart';

void main() {
  group(MozhiPool, () {
    late Map<String, MockMozhiApiClient> clients;
    late List<Uri> built;
    late MozhiPool pool;

    MockMozhiApiClient newClient() => MockMozhiApiClient();

    setUp(() {
      clients = {};
      built = [];
      pool = MozhiPool((uri) {
        built.add(uri);
        return clients.putIfAbsent(uri.toString(), newClient);
      });
    });

    group('run', () {
      test('throws when no instance is configured', () async {
        await expectLater(
          pool.run((client, instance) async => 1),
          throwsA(isA<MozhiApiException>()),
        );
        expect(built, isEmpty);
      });

      test('starts at the first instance and remembers it', () async {
        pool.update([instanceA, instanceB]);
        expect(pool.active, instanceA);
        final visited = <MozhiInstance>[];
        final result = await pool.run((client, instance) async {
          visited.add(instance);
          return instance.url;
        });
        expect(result, instanceA.url);
        expect(visited, [instanceA]);
        expect(pool.active, instanceA);
      });

      test('passes the client built for the instance URL', () async {
        pool.update([instanceA]);
        final client = await pool.run((client, _) async => client);
        expect(client, same(clients[instanceA.url]));
        expect(built, [Uri.parse(instanceA.url)]);
      });

      test('fails over on retryable errors and prefers the instance that '
          'worked', () async {
        pool.update([instanceA, instanceB, instanceC]);
        final visited = <MozhiInstance>[];
        final result = await pool.run((client, instance) async {
          visited.add(instance);
          if (instance == instanceA) throw serverError();
          if (instance == instanceB) {
            throw const MozhiApiException('rate', statusCode: 429);
          }
          return 'ok';
        });
        expect(result, 'ok');
        expect(visited, [instanceA, instanceB, instanceC]);
        expect(pool.active, instanceC);

        visited.clear();
        await pool.run((client, instance) async => visited.add(instance));
        expect(visited, [instanceC]);
      });

      test('treats network errors and timeouts as retryable', () async {
        pool.update([instanceA, instanceB, instanceC]);
        final visited = <MozhiInstance>[];
        await pool.run((client, instance) async {
          visited.add(instance);
          if (instance == instanceA) {
            throw const MozhiApiException('offline');
          }
          if (instance == instanceB) throw TimeoutException('slow');
          return null;
        });
        expect(visited, [instanceA, instanceB, instanceC]);
      });

      test('wraps around starting from the preferred instance', () async {
        pool.update([instanceA, instanceB, instanceC]);
        await pool.run((client, instance) async {
          if (instance != instanceB) throw serverError();
        });
        expect(pool.active, instanceB);

        final visited = <MozhiInstance>[];
        await pool.run((client, instance) async {
          visited.add(instance);
          if (instance != instanceA) throw serverError();
        });
        expect(visited, [instanceB, instanceC, instanceA]);
        expect(pool.active, instanceA);
      });

      test('rethrows non-retryable errors immediately', () async {
        pool.update([instanceA, instanceB]);
        final visited = <MozhiInstance>[];
        await expectLater(
          pool.run<void>((client, instance) async {
            visited.add(instance);
            throw badRequest('invalid language');
          }),
          throwsA(
            isA<MozhiApiException>().having(
              (e) => e.statusCode,
              'statusCode',
              400,
            ),
          ),
        );
        expect(visited, [instanceA]);
        expect(pool.active, instanceA);
      });

      test('does not catch other errors', () async {
        pool.update([instanceA, instanceB]);
        final visited = <MozhiInstance>[];
        await expectLater(
          pool.run<void>((client, instance) async {
            visited.add(instance);
            throw StateError('bug');
          }),
          throwsStateError,
        );
        expect(visited, [instanceA]);
      });

      test('throws the last error when every instance fails', () async {
        pool.update([instanceA, instanceB]);
        await expectLater(
          pool.run<void>((client, instance) async {
            throw serverError(instance.url);
          }),
          throwsA(
            isA<MozhiApiException>().having(
              (e) => e.message,
              'message',
              instanceB.url,
            ),
          ),
        );
        expect(pool.active, instanceA);
      });

      test('skips instances removed while failing over', () async {
        pool.update([instanceA, instanceB, instanceC]);
        final visited = <MozhiInstance>[];
        await pool.run((client, instance) async {
          visited.add(instance);
          if (instance == instanceA) {
            pool.update([instanceA, instanceC]);
            throw serverError();
          }
        });
        expect(visited, [instanceA, instanceC]);
        expect(pool.active, instanceC);
      });

      test('does not prefer an instance removed during the request', () async {
        pool.update([instanceA, instanceB]);
        await pool.run((client, instance) async {
          pool.update([instanceB]);
        });
        expect(pool.active, instanceB);
      });
    });

    group('update', () {
      test('reports whether the list changed', () {
        expect(pool.update([instanceA]), isTrue);
        expect(pool.update([instanceA]), isFalse);
        expect(
          pool.update([const MozhiInstance(url: 'https://a.example')]),
          isTrue,
          reason: 'label changed',
        );
        expect(pool.update([instanceB, instanceA]), isTrue);
        expect(pool.update([instanceA, instanceB]), isTrue, reason: 'order');
        expect(pool.update([]), isTrue);
        expect(pool.instances, isEmpty);
        expect(pool.active, isNull);
      });

      test('closes clients of removed instances only', () async {
        pool.update([instanceA, instanceB]);
        await pool.run((client, _) async {});
        await pool.withClient(instanceB, (client) async {});
        pool.update([instanceB]);
        verify(() => clients[instanceA.url]!.close()).called(1);
        verifyNever(() => clients[instanceB.url]!.close());
      });

      test('keeps the preferred instance while it is configured', () async {
        pool.update([instanceA, instanceB]);
        await pool.run((client, instance) async {
          if (instance == instanceA) throw serverError();
        });
        expect(pool.active, instanceB);
        pool.update([instanceC, instanceB]);
        expect(pool.active, instanceB);
        pool.update([instanceC, instanceA]);
        expect(pool.active, instanceC);
      });

      test('picks up a new label for the preferred instance', () async {
        pool.update([instanceA, instanceB]);
        await pool.run((client, instance) async {
          if (instance == instanceA) throw serverError();
        });
        const relabelled = MozhiInstance(url: 'https://b.example', label: 'B');
        pool.update([instanceA, relabelled]);
        expect(pool.active?.label, 'B');
      });

      test('reuses one client per URL', () async {
        pool.update([instanceA]);
        await pool.run((client, _) async {});
        await pool.run((client, _) async {});
        expect(built, [Uri.parse(instanceA.url)]);
      });
    });

    group('withClient', () {
      test('uses the cached client of a configured instance', () async {
        pool.update([instanceA]);
        final first = await pool.withClient(instanceA, (c) async => c);
        final second = await pool.run((c, _) async => c);
        expect(first, same(second));
        verifyNever(() => clients[instanceA.url]!.close());
      });

      test('uses and closes a temporary client otherwise', () async {
        pool.update([instanceA]);
        final client = await pool.withClient(instanceB, (c) async => c);
        expect(client, same(clients[instanceB.url]));
        verify(() => clients[instanceB.url]!.close()).called(1);
      });

      test('closes the temporary client when the action fails', () async {
        await expectLater(
          pool.withClient<void>(instanceB, (c) async => throw serverError()),
          throwsA(isA<MozhiApiException>()),
        );
        verify(() => clients[instanceB.url]!.close()).called(1);
      });
    });

    test('dispose closes every cached client', () async {
      pool.update([instanceA, instanceB]);
      await pool.withClient(instanceA, (c) async {});
      await pool.withClient(instanceB, (c) async {});
      pool.dispose();
      verify(() => clients[instanceA.url]!.close()).called(1);
      verify(() => clients[instanceB.url]!.close()).called(1);
    });
  });
}
