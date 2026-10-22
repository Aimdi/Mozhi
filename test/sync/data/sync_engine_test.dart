import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mozhi/backup/data/backup_codec.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/sync/data/sync_engine.dart';
import 'package:mozhi/sync/data/webdav_client.dart';
import 'package:mozhi/sync/models/sync_config.dart';
import 'package:mozhi/sync/models/sync_status.dart';

import '../helpers/fake_webdav_server.dart';
import '../helpers/memory_section.dart';

const _filePath = '/dav/Mozhi/${SyncConfig.fileName}';
final SyncConfig _config = SyncConfig(
  server: Uri.parse('https://cloud.example.org/dav/'),
  username: 'alice',
);

/// One device: its sections and engine.
class _Device {
  new({String? name})
    : history = MemorySection('history'),
      presets = MemorySection('presets'),
      settings = MemorySection('settings') {
    registry = registryOf([settings, history, presets]);
    engine = SyncEngine(registry: registry, codec: testCodec);
    this.name = name ?? 'device';
  }

  final MemorySection history;
  final MemorySection presets;
  final MemorySection settings;
  late final BackupRegistry registry;
  late final SyncEngine engine;
  late final String name;
  SyncCursor? cursor;

  Future<SyncRun> sync(
    FakeWebDavServer server,
    BackupKey key, {
    SyncConfig? config,
    bool onlyIfChanged = false,
    BackupKey? newKey,
    bool Function()? cancelled,
  }) async {
    final run = await engine.run(
      dav: _dav(server),
      key: key,
      config: config ?? _config,
      cursor: cursor,
      onlyIfChanged: onlyIfChanged,
      newKey: newKey,
      cancelled: cancelled,
    );
    cursor = run.cursor;
    return run;
  }
}

WebDavClient _dav(FakeWebDavServer server) => WebDavClient(
  server: Uri.parse('https://cloud.example.org/dav/'),
  username: 'alice',
  password: 'app-password',
  httpClient: server.client,
  folderPath: 'Mozhi',
);

FakeWebDavServer _server({
  WebDavFlavor flavor = WebDavFlavor.nextcloud,
  bool sendsEtags = true,
}) => FakeWebDavServer(
  folders: {'/dav/', '/dav/Mozhi/'},
  flavor: flavor,
  sendsEtags: sendsEtags,
);

Matcher _fails(SyncFailure failure) =>
    throwsA(isA<SyncException>().having((e) => e.failure, 'failure', failure));

Future<BackupSnapshot> _remote(FakeWebDavServer server, BackupKey key) =>
    testCodec.decryptWithKey(server.files[_filePath]!, key);

void main() {
  late BackupKey key;

  setUpAll(() async {
    key = await testCodec.deriveKey('passphrase', salt: BackupCodec.newSalt());
  });

  test('the first sync creates the file (If-None-Match: *)', () async {
    final server = _server();
    final device = _Device()..history.set('a', 'hello', 1);
    final run = await device.sync(server, key);
    expect(run.result, SyncResult.sent);
    expect(server.methods, ['GET', 'PUT']);
    expect(server.requests.last.headers['If-None-Match'], '*');
    final remote = await _remote(server, key);
    expect(remote.sections.keys, {'history', 'presets'});
    expect(run.cursor!.etag, server.etagOf(_filePath));
    expect(device.history.exports, [false]);
  });

  test('an unchanged file costs one GET answered 304', () async {
    final server = _server();
    final device = _Device()..history.set('a', 'hello', 1);
    await device.sync(server, key);
    server.requests.clear();
    final run = await device.sync(server, key);
    expect(run.result, SyncResult.unchanged);
    expect(run.skipped, isFalse);
    expect(server.methods, ['GET']);
    expect(
      server.requests.single.headers['If-None-Match'],
      server.etagOf(_filePath),
    );
  });

  test(
    'a run after a change asks nothing when synced data is the same',
    () async {
      final server = _server();
      final device = _Device()..history.set('a', 'hello', 1);
      await device.sync(server, key);
      server.requests.clear();
      final cursor = device.cursor;
      final run = await device.sync(server, key, onlyIfChanged: true);
      expect(run.skipped, isTrue);
      expect(run.cursor, cursor);
      expect(server.requests, isEmpty);
      // A change in a section that isn't synced changes nothing either.
      device.settings.set('theme', 'dark', 2);
      expect(
        (await device.sync(server, key, onlyIfChanged: true)).skipped,
        isTrue,
      );
    },
  );

  test('a local change is sent with If-Match', () async {
    final server = _server();
    final device = _Device()..history.set('a', 'hello', 1);
    await device.sync(server, key);
    final etag = server.etagOf(_filePath);
    device.history.set('b', 'world', 2);
    server.requests.clear();
    final run = await device.sync(server, key, onlyIfChanged: true);
    expect(run.result, SyncResult.sent);
    expect(server.methods, ['GET', 'PUT']);
    expect(server.requests.first.headers['If-None-Match'], isNull);
    expect(server.requests.last.headers['If-Match'], etag);
    // Nothing to merge: the remote copy was this device's own.
    expect(device.history.restores, isEmpty);
  });

  test('two devices exchange and merge their data', () async {
    final server = _server();
    final phone = _Device()
      ..history.set('a', 'from phone', 1)
      ..history.set('shared', 'old', 1);
    final tablet = _Device()
      ..history.set('b', 'from tablet', 2)
      ..history.set('shared', 'new', 5)
      ..presets.set('p', 'preset', 3);

    expect((await phone.sync(server, key)).result, SyncResult.sent);
    final joined = await tablet.sync(server, key);
    expect(joined.result, SyncResult.exchanged);
    expect(joined.report!.restored, ['history', 'presets']);
    expect(tablet.history.values, {
      'a': 'from phone',
      'b': 'from tablet',
      'shared': 'new',
    });
    expect(tablet.history.restores, [BackupRestoreMode.merge]);

    final back = await phone.sync(server, key);
    expect(back.result, SyncResult.received);
    expect(phone.history.values, tablet.history.values);
    expect(phone.presets.values, {'p': 'preset'});

    // Both agree now: nothing more to do on either.
    server.requests.clear();
    expect((await tablet.sync(server, key)).result, SyncResult.unchanged);
    expect((await phone.sync(server, key)).result, SyncResult.unchanged);
    expect(server.methods, ['GET', 'GET']);
  });

  test('deletions (tombstones) travel', () async {
    final server = _server();
    final phone = _Device()..history.set('a', 'x', 1);
    final tablet = _Device();
    await phone.sync(server, key);
    await tablet.sync(server, key);
    tablet.history.delete('a', 2);
    await tablet.sync(server, key);
    await phone.sync(server, key);
    expect(phone.history.values, isEmpty);
  });

  test('a write in between (412) starts over and merges it', () async {
    final server = _server();
    final phone = _Device()..history.set('a', 'phone', 1);
    final tablet = _Device()..history.set('b', 'tablet', 2);
    await phone.sync(server, key);
    // What the phone writes while the tablet syncs: made on a copy.
    final copy = _server()..put(_filePath, server.files[_filePath]!);
    phone.history.set('c', 'phone again', 3);
    await phone.sync(copy, key);
    final racing = copy.files[_filePath]!;
    server.requests.clear();
    var raced = false;
    server.intercept = (request) {
      if (request.method != 'PUT' || raced) return null;
      raced = true;
      server.put(_filePath, racing);
      return http.Response('', 412);
    };
    final run = await tablet.sync(server, key);
    expect(run.result, SyncResult.exchanged);
    expect(server.methods, ['GET', 'PUT', 'GET', 'PUT']);
    expect(tablet.history.values, {
      'a': 'phone',
      'b': 'tablet',
      'c': 'phone again',
    });
    final remote = await _remote(server, key);
    final entries = (remote.sections['history']!.data! as Map)['entries'];
    expect(entries, hasLength(3));
  });

  test('gives up after maxAttempts conflicts', () async {
    final server = _server();
    final device = _Device()..history.set('a', 'x', 1);
    server.intercept = (request) =>
        request.method == 'PUT' ? http.Response('', 412) : null;
    await expectLater(device.sync(server, key), _fails(SyncFailure.conflict));
    expect(
      server.methods.where((m) => m == 'PUT').length,
      SyncEngine.maxAttempts,
    );
  });

  test('a file written with another key: passphrase changed', () async {
    final server = _server();
    final other = await testCodec.deriveKey(
      'other',
      salt: BackupCodec.newSalt(),
    );
    await (_Device()..history.set('a', 'x', 1)).sync(server, other);
    final device = _Device()..history.set('mine', 'y', 1);
    final before = server.files[_filePath];
    await expectLater(
      device.sync(server, key),
      _fails(SyncFailure.passphraseChanged),
    );
    expect(server.files[_filePath], before);
    expect(device.history.restores, isEmpty);
  });

  test('a file that does not open with the right salt: damaged', () async {
    final server = _server();
    await (_Device()..history.set('a', 'x', 1)).sync(server, key);
    final forged = BackupKey(key: Uint8List(32), salt: key.salt, kdf: key.kdf);
    await expectLater(
      _Device().sync(server, forged),
      _fails(SyncFailure.damaged),
    );
  });

  test('a file that is not a backup, or a newer format', () async {
    final server = _server()..put(_filePath, [1, 2, 3]);
    await expectLater(
      _Device().sync(server, key),
      _fails(SyncFailure.notSyncFile),
    );
    final valid = await testCodec.encryptWithKey(
      BackupSnapshot(
        createdAt: DateTime.utc(2026),
        appVersion: '1',
        sections: const {},
      ),
      key,
    );
    server.put(_filePath, [...valid.sublist(0, 8), 9, ...valid.sublist(9)]);
    await expectLater(
      _Device().sync(server, key),
      _fails(SyncFailure.newerVersion),
    );
  });

  test('a section from a newer version stops before merging', () async {
    final server = _server();
    final newer = _Device();
    final registry = registryOf([MemorySection('history', version: 2)]);
    await SyncEngine(
      registry: registry,
      codec: testCodec,
    ).run(dav: _dav(server), key: key, config: _config);
    final device = newer..history.set('a', 'x', 1);
    final before = server.files[_filePath];
    await expectLater(
      device.sync(server, key),
      _fails(SyncFailure.newerVersion),
    );
    expect(device.history.restores, isEmpty);
    expect(server.files[_filePath], before);
  });

  test('sections not synced here are written back unchanged', () async {
    final server = _server();
    final writer = SyncEngine(
      registry: registryOf([
        MemorySection('history'),
        MemorySection('presets')..set('p', 'kept', 1),
        MemorySection('future')..set('f', 'unknown here', 1),
      ]),
      codec: testCodec,
    );
    await writer.run(dav: _dav(server), key: key, config: _config);
    final device = _Device()
      ..history.set('h', 'mine', 2)
      ..presets.set('p', 'not synced here', 9);
    final run = await device.sync(
      server,
      key,
      config: _config.copyWith(excludedSections: {'settings', 'presets'}),
    );
    expect(run.result, SyncResult.sent);
    final remote = await _remote(server, key);
    expect(remote.sections.keys, containsAll(['history', 'presets', 'future']));
    final presets = remote.sections['presets']!.data! as Map;
    expect((presets['entries'] as List).single, containsPair('value', 'kept'));
    expect(device.presets.restores, isEmpty);
  });

  test('syncs the settings with their secrets only when chosen', () async {
    final server = _server();
    final device = _Device()..settings.set('theme', 'dark', 1);
    await device.sync(
      server,
      key,
      config: _config.copyWith(excludedSections: {}, includeSecrets: true),
    );
    expect(device.settings.exports, [true]);
    final remote = await _remote(server, key);
    expect(
      remote.sections['settings']!.data,
      containsPair('secret', 'sk-test'),
    );
  });

  test('reads the ETag with PROPFIND when GET hides it', () async {
    final server = _server(sendsEtags: false);
    await (_Device()..history.set('a', 'x', 1)).sync(server, key);
    final device = _Device()..history.set('b', 'y', 2);
    server.requests.clear();
    await device.sync(server, key);
    expect(server.methods, ['GET', 'PROPFIND', 'PUT']);
    expect(server.requests.last.headers['If-Match'], isNotNull);
  });

  test('writes without a condition when the server keeps no ETags', () async {
    final server = _server(sendsEtags: false, flavor: WebDavFlavor.rclone);
    await (_Device()..history.set('a', 'x', 1)).sync(server, key);
    server.intercept = (request) => request.method == 'PROPFIND'
        ? http.Response(
            '<D:multistatus xmlns:D="DAV:"> <D:response> '
            '<D:href>/f</D:href></D:response></D:multistatus>',
            207,
          )
        : null;
    final device = _Device()..history.set('b', 'y', 2);
    await device.sync(server, key);
    final put = server.requests.last;
    expect(put.method, 'PUT');
    expect(put.headers['If-Match'], isNull);
    expect(put.headers['If-None-Match'], isNull);
  });

  test('a new key rewrites the file even when nothing changed', () async {
    final server = _server();
    final device = _Device()..history.set('a', 'x', 1);
    await device.sync(server, key);
    final newKey = await testCodec.deriveKey(
      'new passphrase',
      salt: BackupCodec.newSalt(),
    );
    final run = await device.sync(server, key, newKey: newKey);
    expect(run.result, SyncResult.sent);
    expect(testCodec.isEncryptedWith(server.files[_filePath]!, newKey), isTrue);
    await expectLater(
      _Device().sync(server, key),
      _fails(SyncFailure.passphraseChanged),
    );
  });

  test('stops before merging or writing once cancelled', () async {
    final server = _server();
    await (_Device()..history.set('a', 'x', 1)).sync(server, key);
    final device = _Device()..history.set('b', 'y', 2);
    final before = server.files[_filePath];
    final run = await device.sync(server, key, cancelled: () => true);
    expect(run.skipped, isTrue);
    expect(device.history.restores, isEmpty);
    expect(server.files[_filePath], before);

    // Cancelled after the merge: nothing written.
    var asked = 0;
    final second = await (_Device()..history.set('z', 'z', 5)).sync(
      server,
      key,
      cancelled: () => ++asked > 1,
    );
    expect(asked, 2);
    expect(second.skipped, isTrue);
    expect(server.files[_filePath], before);
  });

  test('a file deleted on the server is created again', () async {
    final server = _server();
    final device = _Device()..history.set('a', 'x', 1);
    await device.sync(server, key);
    server.remove(_filePath);
    final run = await device.sync(server, key);
    expect(run.result, SyncResult.sent);
    expect(server.requests.last.headers['If-None-Match'], '*');
  });

  test(
    "this device's data failing is localData, and nothing is written",
    () async {
      final server = _server();
      await (_Device()..history.set('a', 'x', 1)).sync(server, key);
      final before = server.files[_filePath];
      final failing = _Device()
        ..history.set('b', 'y', 1)
        ..history.restoreError = Exception('disk');
      await expectLater(
        failing.sync(server, key),
        _fails(SyncFailure.localData),
      );
      expect(server.files[_filePath], before);
      final unreadable = _Device()..history.exportError = Exception('disk');
      await expectLater(
        unreadable.sync(server, key),
        _fails(SyncFailure.localData),
      );
    },
  );

  test('server failures are SyncExceptions', () async {
    final server = _server()..intercept = (request) => http.Response('', 401);
    await expectLater(
      _Device().sync(server, key),
      throwsA(
        isA<SyncException>()
            .having((e) => e.failure, 'failure', SyncFailure.authFailed)
            .having((e) => e.statusCode, 'statusCode', 401),
      ),
    );
    server.intercept = (request) =>
        request.method == 'PUT' ? http.Response('', 507) : null;
    await expectLater(
      _Device().sync(server, key),
      _fails(SyncFailure.insufficientStorage),
    );
  });

  test('works with every server flavour', () async {
    for (final flavor in WebDavFlavor.values) {
      final server = _server(flavor: flavor, sendsEtags: false);
      final phone = _Device()..history.set('a', 'x', 1);
      final tablet = _Device()..history.set('b', 'y', 1);
      await phone.sync(server, key);
      await tablet.sync(server, key);
      await phone.sync(server, key);
      expect(phone.history.values, {'a': 'x', 'b': 'y'}, reason: flavor.name);
    }
  });

  test('fingerprints do not depend on the order of map keys', () {
    final a = SyncEngine.fingerprint({
      'h': const BackupSectionData(
        version: 1,
        data: {
          'x': 1,
          'y': [
            {'b': 2, 'a': 1},
          ],
        },
      ),
    });
    final b = SyncEngine.fingerprint({
      'h': const BackupSectionData(
        version: 1,
        data: {
          'y': [
            {'a': 1, 'b': 2},
          ],
          'x': 1,
        },
      ),
    });
    expect(a, b);
    expect(a, hasLength(64));
    expect(
      SyncEngine.fingerprint({
        'h': const BackupSectionData(version: 2, data: {'x': 1}),
      }),
      isNot(a),
    );
  });
}
