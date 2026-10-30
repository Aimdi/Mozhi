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
        expect(h.stdout, contains('https://mozhi.adminforge.de'));
        expect(h.stdout, contains('https://mozhi.aryak.me'));
        expect(h.stdout, isNot(contains('nerdvpn')));
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
        when(
          () => h.repository.pingInstance(any(), engine: any(named: 'engine')),
        ).thenAnswer((invocation) {
          final instance =
              invocation.positionalArguments.first as MozhiInstance;
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
            'https://f.example' => Future.error(
              const InstanceDoesNotTranslateException(
                'boom',
                engine: 'google',
                statusCode: 500,
              ),
            ),
            'https://g.example' => Future.error(
              const InstanceDoesNotTranslateException(
                'google returned no translation',
                engine: 'google',
              ),
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
          'f.example',
          'g.example',
        ]);
        expect(code, ExitCode.success.code);
        final lines = h.stdout.split('\n');
        expect(lines[1], contains('https://b.example'));
        expect(lines[1], contains('100 ms'));
        expect(lines[2], contains('https://a.example'));
        expect(lines[3], contains('HTTP 502'));
        expect(lines[4], contains('Connection refused'));
        expect(lines[5], contains('boom'));
        expect(lines[6], contains("doesn't translate (HTTP 500)"));
        expect(lines[7], contains("doesn't translate"));
        expect(lines[7], isNot(contains('HTTP')));
        expect(h.stderr, contains('2 of 7 translate with google'));
        expect(h.stderr, contains('https://b.example'));
        verify(() => h.repository.pingInstance(any())).called(7);
        verify(() => h.progress.cancel()).called(1);
        verify(() => h.repository.dispose()).called(1);
      });

      test('pings the public instances by default and prints JSON', () async {
        when(
          () => h.repository.pingInstance(any(), engine: any(named: 'engine')),
        ).thenAnswer((_) async => const Duration(milliseconds: 42));
        expect(await h.run(['instances', 'ping', '--json']), 0);
        final json = h.json()! as List<Object?>;
        expect(json, hasLength(MozhiInstance.publicInstances.length));
        expect(json.first, {
          'url': 'https://mozhi.adminforge.de',
          'label': 'adminforge.de (Germany)',
          'ok': true,
          'latencyMs': 42,
        });
      });

      test('tests the given Mozhi engine', () async {
        when(
          () => h.repository.pingInstance(any(), engine: any(named: 'engine')),
        ).thenAnswer((_) async => const Duration(milliseconds: 42));
        expect(
          await h.run([
            'instances',
            'ping',
            '--engine',
            'mozhi:duckduckgo',
            'a.example',
          ]),
          0,
        );
        verify(() => h.repository.pingInstance(any(), engine: 'duckduckgo'))
            .called(1);
      });

      test('tests the configured Mozhi engine', () async {
        h.writeConfig(const CliConfig(engine: 'deepl'));
        when(
          () => h.repository.pingInstance(any(), engine: any(named: 'engine')),
        ).thenAnswer((_) async => const Duration(milliseconds: 42));
        expect(await h.run(['instances', 'ping', 'a.example']), 0);
        verify(() => h.repository.pingInstance(any(), engine: 'deepl'))
            .called(1);
      });

      test('tests Google when an AI engine is configured', () async {
        h.writeConfig(const CliConfig(engine: 'ai'));
        when(
          () => h.repository.pingInstance(any(), engine: any(named: 'engine')),
        ).thenAnswer((_) async => const Duration(milliseconds: 42));
        expect(await h.run(['instances', 'ping', 'a.example']), 0);
        verify(() => h.repository.pingInstance(any())).called(1);
      });

      test('rejects an AI engine', () async {
        expect(
          await h.run(['instances', 'ping', '--engine', 'ai', 'a.example']),
          ExitCode.usage.code,
        );
        verifyNever(
          () => h.repository.pingInstance(any(), engine: any(named: 'engine')),
        );
      });

      test('times out slow instances and fails when none answer', () async {
        when(
          () => h.repository.pingInstance(any(), engine: any(named: 'engine')),
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
        expect(h.stderr, contains('No instance translates with google.'));
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
