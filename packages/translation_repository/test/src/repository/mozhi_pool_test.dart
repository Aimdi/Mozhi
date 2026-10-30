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

      test('tries instances added while a request is in flight', () async {
        pool.update([instanceA, instanceB]);
        final visited = <MozhiInstance>[];
        final result = await pool.run((client, instance) async {
          visited.add(instance);
          if (instance == instanceA) {
            // "Reset to defaults" replaced the list; A's client is closed.
            pool.update([instanceC]);
            throw const MozhiApiException(
              'HTTP request failed. Client is already closed.',
            );
          }
          return instance.url;
        });
        expect(result, instanceC.url);
        expect(visited, [instanceA, instanceC]);
        expect(pool.active, instanceC);
      });

      test('continues after the failed instance in the new order', () async {
        pool.update([instanceA, instanceB]);
        final visited = <MozhiInstance>[];
        await pool.run((client, instance) async {
          visited.add(instance);
          if (instance == instanceA) {
            pool.update([instanceA, instanceC, instanceB]);
            throw serverError();
          }
          if (instance == instanceC) throw serverError();
        });
        expect(visited, [instanceA, instanceC, instanceB]);
      });

      test('fails over on instance-level HTTP statuses', () async {
        for (final status in [301, 302, 401, 403, 404, 405, 408, 410]) {
          pool
            ..update([instanceA, instanceB])
            ..resetPreferred();
          final visited = <MozhiInstance>[];
          final result = await pool.run((client, instance) async {
            visited.add(instance);
            if (instance == instanceA) {
              throw MozhiApiException('instance', statusCode: status);
            }
            return 'ok';
          });
          expect(result, 'ok', reason: '$status');
          expect(visited, [instanceA, instanceB], reason: '$status');
        }
      });

      test('rethrows Mozhi input errors reported as 500 without failing '
          'over', () async {
        const ttsError =
            "Engine does not exist and/or doesn't support TTS and/or has "
            'been disabled.';
        for (final message in [
          'Target Language Code invalid',
          'Target language code invalid',
          'Source language code invalid',
          'Engine does not exist or has been disabled.',
          'Engine nopenot supported or implemented',
          'from, to, engine, text are required query strings.',
          'engine is a required query string.',
          ttsError,
          'there is no uploaded file associated with the given key',
        ]) {
          pool.update([instanceA, instanceB]);
          final visited = <MozhiInstance>[];
          await expectLater(
            pool.run<void>((client, instance) async {
              visited.add(instance);
              throw MozhiApiException(message, statusCode: 500);
            }),
            throwsA(
              isA<MozhiApiException>().having(
                (e) => e.message,
                'message',
                message,
              ),
            ),
            reason: message,
          );
          expect(visited, [instanceA], reason: message);
        }
      });

      test('keeps failing over on upstream failures', () async {
        const host = 'https://api.mymemory.translated.net';
        const mymemoryError = 'Get "$host/get?q=required+arguments": Forbidden';
        const ttsError =
            'ErrTransport: Get "https://translate.google.com/translate_tts": '
            'Forbidden';
        for (final message in [
          'Post "https://translate.google.com/_/x": Forbidden',
          mymemoryError,
          ttsError,
          'runtime error: invalid memory address or nil pointer dereference',
        ]) {
          pool
            ..update([instanceA, instanceB])
            ..resetPreferred();
          final visited = <MozhiInstance>[];
          await pool.run((client, instance) async {
            visited.add(instance);
            if (instance == instanceA) {
              throw MozhiApiException(message, statusCode: 500);
            }
          });
          expect(visited, [instanceA, instanceB], reason: message);
        }
      });

      group('with failOverOnTimeout: false', () {
        test('rethrows timeouts without trying another instance', () async {
          pool.update([instanceA, instanceB]);
          for (final error in <Exception>[
            TimeoutException('slow'),
            const MozhiApiException('No response within 30000 ms'),
          ]) {
            final visited = <MozhiInstance>[];
            await expectLater(
              pool.run<void>((client, instance) async {
                visited.add(instance);
                throw error;
              }, failOverOnTimeout: false),
              throwsA(same(error)),
            );
            expect(visited, [instanceA]);
          }
        });

        test('still fails over on connection errors and 5xx', () async {
          pool.update([instanceA, instanceB, instanceC]);
          final visited = <MozhiInstance>[];
          await pool.run((client, instance) async {
            visited.add(instance);
            if (instance == instanceA) {
              throw const MozhiApiException('Connection refused');
            }
            if (instance == instanceB) throw serverError();
          }, failOverOnTimeout: false);
          expect(visited, [instanceA, instanceB, instanceC]);
        });
      });

      test('sanitises the errors it throws', () async {
        pool.update([instanceA, instanceB]);
        await expectLater(
          pool.run<void>((client, instance) async {
            const query = 'langpair=en%7Cfr&q=my+secret';
            throw MozhiApiException(
              'Get "https://api.mymemory.translated.net/get?$query": Forbidden',
              statusCode: 500,
              uri: Uri.parse('https://a.example/api/tts?text=my+secret'),
            );
          }),
          throwsA(
            isA<MozhiApiException>()
                .having(
                  (e) => e.message,
                  'message',
                  'Get "https://api.mymemory.translated.net": Forbidden',
                )
                .having((e) => e.statusCode, 'statusCode', 500)
                .having(
                  (e) => e.uri,
                  'uri',
                  Uri.parse('https://a.example/api/tts'),
                ),
          ),
        );
        await expectLater(
          pool.run<void>((client, instance) async {
            throw const MozhiApiException(
              'Target language code invalid https://x.example/?q=secret',
              statusCode: 500,
            );
          }),
          throwsA(
            isA<MozhiApiException>().having(
              (e) => e.message,
              'message',
              'Target language code invalid https://x.example',
            ),
          ),
        );
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

      test(
        'keeps the failover preference while the order is unchanged',
        () async {
          pool.update([instanceA, instanceB]);
          await pool.run((client, instance) async {
            if (instance == instanceA) throw serverError();
          });
          expect(pool.active, instanceB);
          pool.update([instanceA, instanceB]);
          expect(pool.active, instanceB);
        },
      );

      test('forgets the failover preference when the order changes', () async {
        pool.update([instanceA, instanceB, instanceC]);
        await pool.run((client, instance) async {});
        expect(pool.active, instanceA);
        // The user prefers C: requests must go there, not stay on A.
        pool.update([instanceC, instanceA, instanceB]);
        expect(pool.active, instanceC);
        final visited = <MozhiInstance>[];
        await pool.run((client, instance) async => visited.add(instance));
        expect(visited, [instanceC]);
      });

      test(
        'forgets the preference when an instance is added or removed',
        () async {
          pool.update([instanceA, instanceB]);
          await pool.run((client, instance) async {
            if (instance == instanceA) throw serverError();
          });
          expect(pool.active, instanceB);
          pool.update([instanceA, instanceB, instanceC]);
          expect(pool.active, instanceA);

          await pool.run((client, instance) async {
            if (instance == instanceA) throw serverError();
          });
          expect(pool.active, instanceB);
          pool.update([instanceA, instanceB]);
          expect(pool.active, instanceA);
        },
      );

      test('resetPreferred starts at the first instance again', () async {
        pool.update([instanceA, instanceB]);
        await pool.run((client, instance) async {
          if (instance == instanceA) throw serverError();
        });
        expect(pool.active, instanceB);
        pool.resetPreferred();
        expect(pool.active, instanceA);
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

      test('sanitises errors', () async {
        pool.update([instanceA]);
        await expectLater(
          pool.withClient<void>(
            instanceA,
            (c) async => throw const MozhiApiException(
              'Post "https://translate.google.com/x?q=1": Forbidden',
              statusCode: 500,
            ),
          ),
          throwsA(
            isA<MozhiApiException>().having(
              (e) => e.message,
              'message',
              'Post "https://translate.google.com": Forbidden',
            ),
          ),
        );
      });

      test('closes the temporary client when the action fails', () async {
        await expectLater(
          pool.withClient<void>(instanceB, (c) async => throw serverError()),
          throwsA(isA<MozhiApiException>()),
        );
        verify(() => clients[instanceB.url]!.close()).called(1);
      });
    });

    group('static helpers', () {
      test('isInputError needs a status code', () {
        expect(
          MozhiPool.isInputError(
            const MozhiApiException('Target language code invalid'),
          ),
          isFalse,
        );
        expect(
          MozhiPool.isInputError(
            const MozhiApiException(
              'Target language code invalid',
              statusCode: 500,
            ),
          ),
          isTrue,
        );
        expect(
          MozhiPool.isInputError(
            const MozhiApiException('Authentication required', statusCode: 401),
          ),
          isFalse,
        );
      });

      test('isTimeout recognises the client timeout only', () {
        expect(
          MozhiPool.isTimeout(
            const MozhiApiException('No response within 30000 ms'),
          ),
          isTrue,
        );
        expect(
          MozhiPool.isTimeout(const MozhiApiException('Connection refused')),
          isFalse,
        );
        expect(
          MozhiPool.isTimeout(
            const MozhiApiException('No response within', statusCode: 504),
          ),
          isFalse,
        );
      });

      test('canFailOver', () {
        expect(MozhiPool.canFailOver(serverError()), isTrue);
        expect(MozhiPool.canFailOver(badRequest()), isFalse);
        const timeout = MozhiApiException('No response within 10 ms');
        expect(MozhiPool.canFailOver(timeout), isTrue);
        expect(
          MozhiPool.canFailOver(timeout, failOverOnTimeout: false),
          isFalse,
        );
      });

      test('sanitize keeps clean errors and caps long messages', () {
        const clean = MozhiApiException('boom', statusCode: 502);
        expect(MozhiPool.sanitize(clean), same(clean));
        final withUri = MozhiApiException(
          'boom',
          uri: Uri.parse('https://a.example/api/translate'),
        );
        expect(MozhiPool.sanitize(withUri), same(withUri));

        final long = MozhiApiException('x' * 1000, statusCode: 500);
        final sanitized = MozhiPool.sanitize(long);
        expect(sanitized.message.length, MozhiPool.maxMessageLength);
        expect(sanitized.message, endsWith('…'));
        expect(sanitized.statusCode, 500);
      });

      test('sanitizeMessage keeps ports and drops credentials', () {
        expect(
          MozhiPool.sanitizeMessage(
            'Get "http://user:pw@10.0.0.2:8080/api?q=hi": refused',
          ),
          'Get "http://10.0.0.2:8080": refused',
        );
        expect(
          MozhiPool.sanitizeMessage('Get "file:///etc/x": no'),
          contains('<url>'),
        );
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

    group('with an InstanceHealth', () {
      late DateTime now;
      late InstanceHealth health;
      late MozhiPool healthy;

      setUp(() {
        now = DateTime.utc(2026, 10, 30);
        health = InstanceHealth(clock: () => now);
        healthy = MozhiPool(
          (uri) => clients.putIfAbsent(uri.toString(), newClient),
          health: health,
        );
      });

      Future<List<MozhiInstance>> visit(
        Set<MozhiInstance> failing, {
        bool recordHealth = true,
        bool failOverOnTimeout = true,
        Exception Function()? error,
      }) async {
        final visited = <MozhiInstance>[];
        try {
          await healthy.run(
            (client, instance) async {
              visited.add(instance);
              if (failing.contains(instance)) throw (error ?? serverError)();
            },
            recordHealth: recordHealth,
            failOverOnTimeout: failOverOnTimeout,
          );
        } on Object {
          // The visits are the result.
        }
        return visited;
      }

      test('exposes it', () => expect(healthy.health, same(health)));

      test('starts at a server that is not cooling down', () async {
        healthy.update([instanceA, instanceB, instanceC]);
        expect(await visit({instanceA}), [instanceA, instanceB]);
        expect(health.isCoolingDown(instanceA.url), isTrue);

        // Another session: no failover preference, the health remains.
        healthy.resetPreferred();
        expect(healthy.active, instanceB);
        expect(healthy.startOrder, [instanceB, instanceC, instanceA]);
        expect(await visit({}), [instanceB]);
      });

      test('the preferred server that just answered goes first', () async {
        healthy.update([instanceA, instanceB, instanceC]);
        await visit({instanceA, instanceB});
        expect(healthy.active, instanceC);
        expect(healthy.startOrder, [instanceC, instanceA, instanceB]);
      });

      test('still tries cooling servers last', () async {
        healthy.update([instanceA, instanceB]);
        expect(await visit({instanceA, instanceB}), [instanceA, instanceB]);
        expect(await visit({instanceA, instanceB}), [instanceA, instanceB]);
      });

      test('an answer ends the cool-down', () async {
        healthy.update([instanceA, instanceB]);
        await visit({instanceA});
        healthy.resetPreferred();
        expect(await visit({instanceB}), [instanceB, instanceA]);
        expect(health.isCoolingDown(instanceA.url), isFalse);
        expect(health.isCoolingDown(instanceB.url), isTrue);
      });

      test('the cool-down ends on its own', () async {
        healthy.update([instanceA, instanceB]);
        await visit({instanceA});
        healthy.resetPreferred();
        now = now.add(health.coolDown);
        expect(healthy.active, instanceA);
      });

      test('input errors, cancellations and timeouts without failover do '
          'not count', () async {
        healthy.update([instanceA, instanceB]);
        await visit(
          {instanceA},
          error: () => const MozhiApiException(
            'Target language code invalid',
            statusCode: 500,
          ),
        );
        await visit({instanceA}, error: MozhiRequestCancelledException.new);
        await visit({instanceA}, error: badRequest);
        await visit(
          {instanceA},
          failOverOnTimeout: false,
          error: () => const MozhiApiException('No response within 30000 ms'),
        );
        await visit(
          {instanceA},
          failOverOnTimeout: false,
          error: () => TimeoutException('slow'),
        );
        expect(health.isCoolingDown(instanceA.url), isFalse);
      });

      test('timeouts that fail over count', () async {
        healthy.update([instanceA, instanceB]);
        await visit({instanceA}, error: () => TimeoutException('slow'));
        expect(health.isCoolingDown(instanceA.url), isTrue);
      });

      test('recordHealth: false neither marks nor clears', () async {
        healthy.update([instanceA, instanceB]);
        expect(await visit({instanceA}, recordHealth: false), [
          instanceA,
          instanceB,
        ]);
        expect(health.isCoolingDown(instanceA.url), isFalse);

        healthy.resetPreferred();
        await visit({instanceA});
        healthy.resetPreferred();
        // B's engine list fails and A's loads: neither counts.
        expect(await visit({instanceB}, recordHealth: false), [
          instanceB,
          instanceA,
        ]);
        expect(health.isCoolingDown(instanceA.url), isTrue);
        expect(health.isCoolingDown(instanceB.url), isFalse);
      });

      test('putting a cooling server first forgets its failure', () async {
        healthy.update([instanceA, instanceB, instanceC]);
        await visit({instanceA, instanceB});
        healthy.update([instanceB, instanceA, instanceC]);
        expect(health.isCoolingDown(instanceB.url), isFalse);
        expect(health.isCoolingDown(instanceA.url), isTrue);
        expect(healthy.active, instanceB);
      });

      test('the first configuration forgets nothing', () async {
        health.markFailed(instanceA.url);
        healthy.update([instanceA, instanceB]);
        expect(healthy.active, instanceB);
        healthy
          ..update([])
          ..update([instanceA, instanceB]);
        expect(health.isCoolingDown(instanceA.url), isTrue);
      });

      test(
        'resetPreferred(forgetHealth: true) forgets every failure',
        () async {
          healthy.update([instanceA, instanceB]);
          await visit({instanceA});
          healthy.resetPreferred(forgetHealth: true);
          expect(healthy.active, instanceA);
          expect(health.isCoolingDown(instanceA.url), isFalse);
        },
      );

      test(
        'with an engine, wraps the last failure of every allowed server',
        () async {
          healthy.update([instanceA, instanceB, instanceC]);
          await expectLater(
            healthy.run<void>(
              (client, instance) async => throw serverError(
                'Get "https://translate.google.com/?q=secret": EOF',
              ),
              engine: googleEngine,
              allow: (instance) => instance != instanceB,
            ),
            throwsA(
              isA<AllInstancesFailedException>()
                  .having((e) => e.engine, 'engine', googleEngine)
                  .having((e) => e.instances, 'instances', [
                    instanceA,
                    instanceC,
                  ])
                  .having((e) => e.statusCode, 'statusCode', 502)
                  .having(
                    (e) => e.message,
                    'message',
                    'Get "https://translate.google.com": EOF',
                  )
                  .having((e) => e.cause, 'cause', isA<MozhiApiException>()),
            ),
          );
        },
      );

      test('with an engine, wraps a timeout that was failed over', () async {
        healthy.update([instanceA]);
        await expectLater(
          healthy.run<void>(
            (client, instance) async => throw TimeoutException('slow'),
            engine: googleEngine,
          ),
          throwsA(
            isA<AllInstancesFailedException>()
                .having((e) => e.statusCode, 'statusCode', isNull)
                .having((e) => e.cause, 'cause', isA<TimeoutException>())
                .having(
                  (e) => '$e',
                  'toString',
                  startsWith(
                    'AllInstancesFailedException(mozhi:google, 1 '
                    'server): TimeoutException',
                  ),
                ),
          ),
        );
      });

      test('with an engine, input errors are not wrapped', () async {
        healthy.update([instanceA, instanceB]);
        await expectLater(
          healthy.run<void>(
            (client, instance) async => throw badRequest(),
            engine: googleEngine,
          ),
          throwsA(isNot(isA<AllInstancesFailedException>())),
        );
      });
    });
  });
}
