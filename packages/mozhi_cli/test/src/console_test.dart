import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:mozhi_cli/src/cli_context.dart';
import 'package:mozhi_cli/src/console.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group('Console', () {
    test('reports the terminal capabilities of the process', () {
      final console = Console(environment: {'NO_COLOR': '1'});
      expect(console.environment, {'NO_COLOR': '1'});
      expect(console.isWindows, Platform.isWindows);
      expect(console.stdinHasTerminal, stdin.hasTerminal);
      expect(console.stdoutHasTerminal, stdout.hasTerminal);
      expect(console.supportsAnsiEscapes, isFalse);
      expect(console.terminalColumns, greaterThan(0));
      expect(console.terminalLines, greaterThan(0));
    });

    test('uses the process environment by default', () {
      expect(Console().environment, Platform.environment);
    });
  });

  test('CliContext creates the default repository and store', () {
    final repository = CliContext.defaultRepository();
    expect(repository, isA<TranslationRepository>());
    repository.dispose();
    final store = CliContext(logger: Logger())
        .configStoreFactory('/tmp/x.json');
    expect(store.path, '/tmp/x.json');
    expect(store.posix, !Platform.isWindows);
  });
}
