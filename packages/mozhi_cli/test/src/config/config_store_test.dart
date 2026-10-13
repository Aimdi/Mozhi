import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:mozhi_cli/src/config/config_store.dart';
import 'package:mozhi_cli/src/errors.dart';
import 'package:test/test.dart';

import '../../helpers.dart';

void main() {
  group('ConfigStore.defaultPath', () {
    String path(Map<String, String> env, {bool isWindows = false}) =>
        ConfigStore.defaultPath(env, isWindows: isWindows);

    test('prefers MOZHI_CONFIG', () {
      expect(
        path({'MOZHI_CONFIG': '/x/c.json', 'XDG_CONFIG_HOME': '/xdg'}),
        '/x/c.json',
      );
    });

    test('uses XDG_CONFIG_HOME when absolute', () {
      expect(path({'XDG_CONFIG_HOME': '/xdg/'}), '/xdg/mozhi/config.json');
      expect(
        path({'XDG_CONFIG_HOME': 'relative', 'HOME': '/home/u'}),
        '/home/u/.config/mozhi/config.json',
      );
    });

    test('uses APPDATA on Windows', () {
      expect(
        path({'APPDATA': r'C:\Users\u\AppData\Roaming'}, isWindows: true),
        r'C:\Users\u\AppData\Roaming\mozhi\config.json',
      );
      expect(
        path({'USERPROFILE': r'C:\Users\u'}, isWindows: true),
        r'C:\Users\u\mozhi\config.json',
      );
    });

    test('fails without a home directory', () {
      expect(
        () => path({}),
        throwsA(
          isA<CliException>().having(
            (e) => e.exitCode,
            'exitCode',
            ExitCode.config,
          ),
        ),
      );
    });
  });

  group('ConfigStore', () {
    late Directory directory;
    late String path;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('mozhi_store_');
      path = '${directory.path}/conf/config.json';
    });

    tearDown(() => directory.deleteSync(recursive: true));

    test('loads an empty config when the file is missing or empty', () {
      final store = ConfigStore(path: path);
      expect(store.exists, isFalse);
      expect(store.isExposed, isFalse);
      expect(store.load().toJson(), isEmpty);
      File(path)
        ..createSync(recursive: true)
        ..writeAsStringSync('  ');
      expect(store.load().toJson(), isEmpty);
    });

    test('round-trips with owner-only permissions', () {
      final store = ConfigStore(path: path)
        ..save(
          const CliConfig(
            target: 'de',
            providers: [ProviderEntry(claudeProvider)],
          ),
        );
      expect(File(path).statSync().mode & 0x1ff, 0x180);
      expect(store.isExposed, isFalse);
      expect(store.load().providers.single.config.apiKey, 'sk-stored');
      expect(directory.listSync(recursive: true).map((e) => e.path), [
        '${directory.path}/conf',
        path,
      ]);
      Process.runSync('chmod', ['640', path]);
      expect(store.isExposed, isTrue);
    });

    test('does not chmod on Windows', () {
      final calls = <String>[];
      ConfigStore(
        path: path,
        posix: false,
        chmod: (path, mode) => calls.add(mode),
      ).save(const CliConfig());
      expect(calls, isEmpty);
      expect(ConfigStore(path: path, posix: false).isExposed, isFalse);
    });

    test('rejects malformed files', () {
      final file = File(path)..createSync(recursive: true);
      for (final contents in ['{', '[1]']) {
        file.writeAsStringSync(contents);
        expect(
          () => ConfigStore(path: path).load(),
          throwsA(
            isA<CliException>().having(
              (e) => e.message,
              'message',
              contains('is not valid'),
            ),
          ),
        );
      }
    });

    test('reports unreadable files', () {
      Directory(path).createSync(recursive: true);
      expect(
        () => ConfigStore(path: path).load(),
        throwsA(isA<CliException>()),
      );
    });

    test('cleans up when writing fails', () {
      final store = ConfigStore(
        path: path,
        chmod: (path, mode) {
          if (mode == '600') {
            throw FileSystemException('chmod failed', path);
          }
        },
      );
      expect(
        () => store.save(const CliConfig()),
        throwsA(
          isA<CliException>().having(
            (e) => e.message,
            'message',
            contains('chmod failed'),
          ),
        ),
      );
      expect(Directory('${directory.path}/conf').listSync(), isEmpty);
    });

    test('reports directories that cannot be created', () {
      // A path whose parent is a file makes chmod (and the write) fail.
      File('${directory.path}/file').writeAsStringSync('');
      expect(
        () =>
            ConfigStore(path: '${directory.path}/file/sub/config.json')
                .save(const CliConfig()),
        throwsA(isA<CliException>()),
      );
    });
  });
}
