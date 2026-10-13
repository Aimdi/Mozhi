import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi_cli/src/command_runner.dart';
import 'package:mozhi_cli/src/version.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  setUpAll(registerFallbacks);

  group('MozhiCliCommandRunner', () {
    late Harness h;

    setUp(() => h = Harness());
    tearDown(() => h.dispose());

    test('can be instantiated without arguments', () {
      expect(MozhiCliCommandRunner(), isNotNull);
      expect(MozhiCliCommandRunner().enableAutoInstall, isFalse);
    });

    test('prints the version', () async {
      expect(await h.runner.run(['--version']), ExitCode.success.code);
      expect(h.out, [packageVersion]);
    });

    test('prints usage with examples', () async {
      expect(await h.runner.run(['--help']), ExitCode.success.code);
      expect(h.stdout, contains('Usage: mozhi <command> [arguments]'));
      expect(h.stdout, contains('translate'));
      expect(h.stdout, contains('Examples:'));
      expect(h.stdout, contains('Exit codes:'));
    });

    test('runs the completion command', () async {
      expect(await h.runner.run(['completion']), ExitCode.success.code);
    });

    test('reports unknown commands with exit code 64', () async {
      expect(await h.runner.run(['nope']), ExitCode.usage.code);
      expect(h.stderr, contains('Could not find a command named "nope"'));
      expect(h.stdout, contains('Usage:'));
    });

    test('reports unknown options with exit code 64', () async {
      expect(
        await h.run(['translate', '--bogus', 'x']),
        ExitCode.usage.code,
      );
      expect(h.stderr, contains('bogus'));
    });

    test('reports a missing subcommand', () async {
      expect(await h.run(['config']), ExitCode.usage.code);
      expect(h.stderr, contains('Missing subcommand'));
    });

    test('logs details and hides API keys with --verbose', () async {
      when(() => h.logger.prompt(any(), hidden: true)).thenReturn('');
      final code = await h.run([
        '--verbose',
        'config',
        'providers',
        'add',
        '-p',
        'openai',
        '--api-key',
        'sk-secret',
      ]);
      expect(code, 0);
      expect(h.level, Level.verbose);
      expect(h.details.join('\n'), contains('api-key: ********'));
      expect(h.details.join('\n'), isNot(contains('sk-secret')));
    });

    test('maps unexpected errors to exit code 70', () async {
      when(() => h.repository.getEngines()).thenThrow(Exception('kaput'));
      expect(await h.run(['--verbose', 'engines']), ExitCode.software.code);
      expect(h.stderr, contains('Unexpected error: Exception: kaput'));
      expect(h.details.last, contains('engines_command.dart'));
    });
  });
}
