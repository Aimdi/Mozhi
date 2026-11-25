import 'dart:io';

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

    test('imports and exports glossaries in txt, tsv, csv and json', () async {
      final csvFile = File('${h.directory.path}/terms.csv')
        ..writeAsStringSync(
          'term,translation\n'
          '"cloud, hybrid","nuage, hybride"\n'
          'server,serveur\n',
        );
      expect(await h.run(['config', 'glossary', 'import', csvFile.path]), 0);
      expect(h.readConfig().glossary, {
        'cloud, hybrid': 'nuage, hybride',
        'server': 'serveur',
      });

      final txtFile = File('${h.directory.path}/more.txt')
        ..writeAsStringSync('# comment\ncache\tmémoire cache\n');
      expect(
        await h.run([
          'config',
          'glossary',
          'import',
          '--replace',
          txtFile.path,
        ]),
        0,
      );
      expect(h.readConfig().glossary, {'cache': 'mémoire cache'});

      final outCsv = '${h.directory.path}/out/glossary.csv';
      expect(
        await h.run([
          'config',
          'glossary',
          'export',
          '--format',
          'csv',
          '-o',
          outCsv,
        ]),
        0,
      );
      expect(
        File(outCsv).readAsStringSync(),
        'term,translation\ncache,mémoire cache\n',
      );

      h.written.clear();
      expect(
        await h.run(['config', 'glossary', 'export', '--format', 'tsv']),
        0,
      );
      expect(h.written.toString(), 'cache\tmémoire cache\n');
    });
  });
}
