import 'package:mason_logger/mason_logger.dart';
import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:test/test.dart';

import '../../helpers.dart';

void main() {
  setUpAll(registerFallbacks);

  group('config glossary', () {
    late Harness h;

    setUp(() => h = Harness());
    tearDown(() => h.dispose());

    test(
      'list shows hint when empty, then table and --json after add',
      () async {
        expect(await h.run(['config', 'glossary', 'list']), 0);
        expect(h.stdout, contains('No saved glossary entries'));

        h.out.clear();
        expect(
          await h.run([
            'config',
            'glossary',
            'add',
            'cloud=nuage',
            'server=serveur',
          ]),
          0,
        );
        expect(h.readConfig().glossary, {
          'cloud': 'nuage',
          'server': 'serveur',
        });

        // Two-arg pair form also works.
        expect(
          await h.run(['config', 'glossary', 'add', 'cache', 'mémoire cache']),
          0,
        );
        expect(h.readConfig().glossary['cache'], 'mémoire cache');

        h.out.clear();
        expect(await h.run(['config', 'glossary', 'ls']), 0);
        expect(h.stdout, contains('cloud'));
        expect(h.stdout, contains('nuage'));

        h.out.clear();
        expect(await h.run(['config', 'glossary', 'list', '--json']), 0);
        expect(h.json(), {
          'cloud': 'nuage',
          'server': 'serveur',
          'cache': 'mémoire cache',
        });

        h.out.clear();
        expect(await h.run(['config', 'show']), 0);
        expect(h.stdout, contains('GLOSSARY TERM'));
        expect(h.stdout, contains('nuage'));
      },
    );

    test(
      'remove deletes terms case-insensitively and supports --all',
      () async {
        h.writeConfig(
          const CliConfig(glossary: {'Cloud': 'nuage', 'server': 'serveur'}),
        );
        expect(await h.run(['config', 'glossary', 'rm', 'cloud']), 0);
        expect(h.readConfig().glossary, {'server': 'serveur'});

        expect(
          await h.run(['config', 'glossary', 'remove', 'missing']),
          ExitCode.usage.code,
        );
        expect(h.stderr, contains('not saved'));

        expect(await h.run(['config', 'glossary', 'remove', '--all']), 0);
        expect(h.readConfig().glossary, isEmpty);
      },
    );
  });
}
