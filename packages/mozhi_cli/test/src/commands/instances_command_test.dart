import 'dart:async';

import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers.dart';

void main() {
  setUpAll(registerFallbacks);

  group('instances', () {
    late Harness h;

    setUp(() => h = Harness());
    tearDown(() => h.dispose());

    group('list', () {
      test('lists public instances', () async {
        when(() => h.console.stdoutHasTerminal).thenReturn(true);
        expect(await h.run(['instances', 'list']), 0);
        expect(h.stdout, contains('https://mozhi.aryak.me'));
        expect(h.stderr, contains('No instance configured'));
      });

      test('puts the configured instance first', () async {
        h.writeConfig(const CliConfig(instance: 'mozhi.example.org'));
        expect(await h.run(['instances', 'list', '--json']), 0);
        final json = h.json()! as List<Object?>;
        expect(json.first, {
          'url': 'https://mozhi.example.org',
          'configured': true,
        });
        expect(json, hasLength(MozhiInstance.publicInstances.length + 1));
      });

      test('marks a configured public instance', () async {
        when(() => h.console.stdoutHasTerminal).thenReturn(true);
        h.writeConfig(const CliConfig(instance: 'https://mozhi.aryak.me/'));
        expect(await h.run(['instances', 'list']), 0);
        expect(h.stdout, contains('https://mozhi.aryak.me *'));
        expect(h.stderr, contains('* configured instance'));
      });
    });

    group('ping', () {
      test('sorts by latency and reports failures', () async {
        when(() => h.console.stdoutHasTerminal).thenReturn(true);
        when(() => h.repository.pingInstance(any())).thenAnswer((invocation) {
          final instance = invocation.positionalArguments.first
              as MozhiInstance;
          return switch (instance.url) {
            'https://a.example' => Future.value(
              const Duration(milliseconds: 300),
            ),
            'https://b.example' => Future.value(
              const Duration(milliseconds: 100),
            ),
            'https://c.example' => Future.error(
              const MozhiApiException('down', statusCode: 502),
            ),
            'https://d.example' => Future.error(
              const MozhiApiException('Connection refused'),
            ),
            _ => Future.error(StateError('boom')),
          };
        });
        final code = await h.run([
          'instances',
          'ping',
          'a.example',
          'b.example',
          'c.example',
          'd.example',
          'e.example',
        ]);
        expect(code, ExitCode.success.code);
        final lines = h.stdout.split('\n');
        expect(lines[1], contains('https://b.example'));
        expect(lines[1], contains('100 ms'));
        expect(lines[2], contains('https://a.example'));
        expect(lines[3], contains('HTTP 502'));
        expect(lines[4], contains('Connection refused'));
        expect(lines[5], contains('boom'));
        expect(h.stderr, contains('2 of 5 reachable'));
        expect(h.stderr, contains('https://b.example'));
        verify(() => h.progress.cancel()).called(1);
        verify(() => h.repository.dispose()).called(1);
      });

      test('pings the public instances by default and prints JSON', () async {
        when(
          () => h.repository.pingInstance(any()),
        ).thenAnswer((_) async => const Duration(milliseconds: 42));
        expect(await h.run(['instances', 'ping', '--json']), 0);
        final json = h.json()! as List<Object?>;
        expect(json, hasLength(MozhiInstance.publicInstances.length));
        expect(json.first, {
          'url': 'https://mozhi.aryak.me',
          'label': 'mozhi.aryak.me (India)',
          'ok': true,
          'latencyMs': 42,
        });
      });

      test('times out slow instances and fails when none answer', () async {
        when(
          () => h.repository.pingInstance(any()),
        ).thenAnswer((_) => Completer<Duration>().future);
        final code = await h.run([
          'instances',
          'ping',
          '--timeout',
          '0.01',
          'https://slow.example',
        ]);
        expect(code, ExitCode.unavailable.code);
        expect(h.stdout, contains('timed out'));
        expect(h.stderr, contains('No instance is reachable.'));
      });

      test('rejects an invalid timeout', () async {
        expect(
          await h.run(['instances', 'ping', '--timeout', '0']),
          ExitCode.usage.code,
        );
      });
    });
  });
}
