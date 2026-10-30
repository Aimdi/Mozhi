import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mozhi/backup/data/backup_codec.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/core/network/network_session.dart';
import 'package:mozhi/core/privacy/egress/egress.dart';
import 'package:mozhi/sync/data/sync_service.dart';
import 'package:mozhi/sync/data/sync_store.dart';
import 'package:mozhi/sync/data/webdav_client.dart';
import 'package:mozhi/sync/models/sync_config.dart';
import 'package:mozhi/sync/models/sync_status.dart';
import 'package:translation_repository/translation_repository.dart'
    show PrivacyMode;

import '../helpers/fake_webdav_server.dart';
import '../helpers/memory_section.dart';

const _filePath = '/dav/Mozhi/${SyncConfig.fileName}';
final Uri _serverUrl = Uri.parse('https://cloud.example.org/dav/');

SyncConnection _connect({String password = 'app-password', Uri? server}) =>
    SyncConnection(
      server: server ?? _serverUrl,
      username: 'alice',
      password: password,
    );

SyncConfig get _config => SyncConfig(server: _serverUrl, username: 'alice');

/// A device: its data, stores and sync service.
class _Device {
  new(
    this.server, {
    MemoryStore? prefs,
    MemoryStore? secrets,
    this.debounce = const Duration(milliseconds: 5),
    this.codec = testCodec,
  }) : prefs = prefs ?? MemoryStore(),
       secrets = secrets ?? MemoryStore() {
    service = _service();
  }

  final FakeWebDavServer server;
  final MemoryStore prefs;
  final MemoryStore secrets;
  final Duration debounce;
  final BackupCodec codec;
  final history = MemorySection('history');
  PrivacyMode mode = PrivacyMode.offlineFirst;
  bool metered = false;
  late SyncService service;

  SyncService _service() => SyncService(
    registry: registryOf([history]),
    prefs: prefs,
    secrets: secrets,
    codec: codec,
    httpClient: () => server.client,
    privacyMode: () => mode,
    isMetered: () async => metered,
    clock: () => DateTime.utc(2026, 10, 22, 12),
    debounce: debounce,
  );

  /// A new service over the same stores (the app started again).
  SyncService restart() => service = _service();

  Future<void> setUp([String passphrase = 'correct horse']) async {
    final probe = await service.probe(_connect());
    await service.setUp(
      connection: _connect(),
      passphrase: passphrase,
      config: _config,
      probed: probe,
    );
  }
}

/// How keys were derived before passphrases were normalised (NFC): from
/// the passphrase exactly as typed.
class _AsTypedCodec extends BackupCodec {
  const new() : super(kdf: testKdf, useIsolate: false);

  @override
  Future<BackupKey> deriveKey(
    String passphrase, {
    required Uint8List salt,
    BackupKdf? parameters,
    bool asTyped = false,
  }) => super.deriveKey(
    passphrase,
    salt: salt,
    parameters: parameters,
    asTyped: true,
  );
}

Matcher _fails(SyncFailure failure) =>
    throwsA(isA<SyncException>().having((e) => e.failure, 'failure', failure));

FakeWebDavServer _server({Set<String>? folders}) =>
    FakeWebDavServer(folders: folders ?? {'/dav/'});

void main() {
  group('probe', () {
    test('finds the place for a new folder', () async {
      final device = _Device(_server());
      final probe = await device.service.probe(_connect());
      expect(probe.folderExists, isFalse);
      expect(probe.hasSyncFile, isFalse);
      expect(probe.server, _serverUrl);
      // Nothing was created.
      expect(device.server.folders, {'/dav/'});
    });

    test('finds a sync file of another device', () async {
      final server = _server(folders: {'/dav/', '/dav/Mozhi/'})
        ..put(_filePath, [1, 2]);
      final probe = await _Device(server).service.probe(_connect());
      expect(probe.folderExists, isTrue);
      expect(probe.hasSyncFile, isTrue);
    });

    test('fails for a wrong password, a missing server or a file', () async {
      final device = _Device(_server());
      await expectLater(
        device.service.probe(_connect(password: 'wrong')),
        _fails(SyncFailure.authFailed),
      );
      await expectLater(
        _Device(_server(folders: {'/other/'})).service.probe(_connect()),
        _fails(SyncFailure.notFound),
      );
      final file = _server()..put('/dav/Mozhi/', [1]);
      await expectLater(
        _Device(file).service.probe(_connect()),
        _fails(SyncFailure.notAFolder),
      );
    });

    test("finds Nextcloud's WebDAV address below the server's", () async {
      final server = FakeWebDavServer(folders: {'/remote.php/dav/files/alice/'})
        ..intercept = (request) =>
            request.url.path == '/' ? http.Response('<html>', 200) : null;
      final probe = await _Device(server).service
          .probe(_connect(server: Uri.parse('https://cloud.example.org')));
      expect(
        probe.server.toString(),
        'https://cloud.example.org/remote.php/dav/files/alice/',
      );
    });

    test('also tries the Nextcloud address after a refusal', () async {
      final server = FakeWebDavServer(folders: {'/remote.php/dav/files/alice/'})
        ..intercept = (request) =>
            request.url.path == '/' ? http.Response('', 401) : null;
      final probe = await _Device(server).service
          .probe(_connect(server: Uri.parse('https://cloud.example.org/')));
      expect(probe.server.path, '/remote.php/dav/files/alice/');
    });

    test('reports the first answer when the guess fails too', () async {
      final server = FakeWebDavServer(folders: {})
        ..intercept = (request) => http.Response('<html>', 200);
      await expectLater(
        _Device(server).service
            .probe(_connect(server: Uri.parse('https://example.org'))),
        _fails(SyncFailure.notWebDav),
      );
      // Not retried when the server could not be reached.
      server.intercept = (request) => throw http.ClientException('down');
      server.requests.clear();
      await expectLater(
        _Device(server).service
            .probe(_connect(server: Uri.parse('https://example.org'))),
        _fails(SyncFailure.offline),
      );
      expect(server.requests, hasLength(1));
      // Not without a user name to complete the address with.
      server.intercept = (request) => http.Response('<html>', 200);
      server.requests.clear();
      await expectLater(
        _Device(server).service.probe(
          SyncConnection(
            server: Uri.parse('https://example.org'),
            username: '',
            password: 'p',
          ),
        ),
        _fails(SyncFailure.notWebDav),
      );
      expect(server.requests, hasLength(1));
    });

    test('is refused in Offline only', () async {
      final device = _Device(_server())..mode = PrivacyMode.offlineOnly;
      await expectLater(
        device.service.probe(_connect()),
        _fails(SyncFailure.offlineOnly),
      );
      expect(device.server.requests, isEmpty);
    });
  });

  group('setUp', () {
    test('creates the folder and the file, and keeps the key', () async {
      final device = _Device(_server());
      device.history.set('a', 'x', 1);
      await device.setUp();
      final state = device.service.state;
      expect(state.isSetUp, isTrue);
      expect(state.unlocked, isTrue);
      expect(state.running, isFalse);
      expect(state.status.lastResult, SyncResult.sent);
      expect(device.server.folders, contains('/dav/Mozhi/'));
      expect(device.server.files, contains(_filePath));
      expect(device.secrets.values[SyncStore.passwordKey], 'app-password');
      final storedKey = BackupKey.fromJson(
        jsonDecode(device.secrets.values[SyncStore.keyKey]!)
            as Map<String, Object?>,
      );
      expect(
        testCodec.isEncryptedWith(device.server.files[_filePath]!, storedKey),
        isTrue,
      );
      // Never the passphrase.
      expect([
        ...device.secrets.values.values,
        ...device.prefs.values.values,
      ], everyElement(isNot(contains('correct horse'))));
      expect(device.prefs.values, contains(SyncStore.configKey));
    });

    test('a second device joins with the same passphrase', () async {
      final server = _server();
      final phone = _Device(server)..history.set('a', 'phone', 1);
      await phone.setUp();
      final tablet = _Device(server)..history.set('b', 'tablet', 2);
      await tablet.setUp();
      expect(tablet.history.values, {'a': 'phone', 'b': 'tablet'});
      expect(tablet.service.state.status.lastResult, SyncResult.exchanged);
      expect(await phone.service.syncNow(), isNull);
      expect(phone.history.values, tablet.history.values);
    });

    test('a wrong passphrase stores nothing and changes nothing', () async {
      final server = _server();
      await (_Device(server)..history.set('a', 'x', 1)).setUp();
      final before = server.files[_filePath];
      final tablet = _Device(server)..history.set('b', 'y', 1);
      await expectLater(
        tablet.setUp('wrong'),
        _fails(SyncFailure.wrongPassphrase),
      );
      expect(tablet.service.state.isSetUp, isFalse);
      expect(tablet.service.state.running, isFalse);
      expect(tablet.secrets.values, isEmpty);
      expect(tablet.prefs.values, isEmpty);
      expect(tablet.history.restores, isEmpty);
      expect(server.files[_filePath], before);
    });

    group('a file made with a passphrase as typed, before NFC', () {
      // "Việt" with combining marks, as some keyboards type it.
      const decomposed = 'Vie\u0323\u0302t horse';
      const composed = 'Vi\u1EC7t horse';

      /// Whether the sync file opens with the key of the passphrase in NFC
      /// (not the one exactly as typed).
      Future<bool> nfcKeyed(FakeWebDavServer server) async {
        final bytes = server.files[_filePath]!;
        final unlocked = await testCodec.unlockKeyOf(bytes, decomposed);
        await testCodec.decryptWithKey(bytes, unlocked.key);
        return !unlocked.asTyped;
      }

      test('is joined, then written again once with the NFC key', () async {
        final server = _server();
        final old = _Device(server, codec: const _AsTypedCodec())
          ..history.set('a', 'old', 1);
        await old.setUp(decomposed);
        expect(await nfcKeyed(server), isFalse);

        final tablet = _Device(server)..history.set('b', 'new', 2);
        await tablet.setUp(decomposed);

        expect(tablet.history.values, {'a': 'old', 'b': 'new'});
        expect(tablet.service.state.status.lastFailure, isNull);
        expect(await nfcKeyed(server), isTrue);
        // The tablet keeps the NFC key: it syncs on, also after a restart,
        // and the passphrase opens the file however it is typed.
        expect(await tablet.service.syncNow(), isNull);
        tablet.restart();
        expect(await tablet.service.syncNow(), isNull);
        await _Device(server).setUp(composed);
      });

      test('another device of this version asks for the passphrase once, '
          'and it opens with the NFC key', () async {
        final server = _server();
        final old = _Device(server, codec: const _AsTypedCodec())
          ..history.set('a', 'old', 1);
        await old.setUp(decomposed);
        // The old device updated to this version: it still has the key of
        // the passphrase as typed.
        final phone = _Device(server, prefs: old.prefs, secrets: old.secrets)
          ..history.set('a', 'old', 1);
        final tablet = _Device(server)..history.set('b', 'new', 2);
        await tablet.setUp(decomposed);

        expect(await phone.service.syncNow(), SyncFailure.passphraseChanged);
        await phone.service.unlock(passphrase: decomposed);
        expect(phone.history.values, {'a': 'old', 'b': 'new'});
        expect(await phone.service.syncNow(), isNull);
        expect(await nfcKeyed(server), isTrue);
      });

      test('is still joined when writing it again fails, and written again '
          'when the passphrase is entered next', () async {
        final server = _server();
        final old = _Device(server, codec: const _AsTypedCodec())
          ..history.set('a', 'old', 1);
        await old.setUp(decomposed);
        final tablet = _Device(server)..history.set('b', 'new', 2);
        var puts = 0;
        server.intercept = (request) {
          // The join's write goes through; the one with the new key fails.
          if (request.method == 'PUT' && ++puts == 2) {
            return http.Response('', 503);
          }
          return null;
        };
        await tablet.setUp(decomposed);
        expect(tablet.history.values, {'a': 'old', 'b': 'new'});
        expect(tablet.service.state.isSetUp, isTrue);
        expect(await nfcKeyed(server), isFalse);
        // With the key that opens the file, every device syncs on.
        expect(await tablet.service.syncNow(), isNull);
        expect(await old.service.syncNow(), isNull);

        server.intercept = null;
        await tablet.service.unlock(passphrase: decomposed);
        expect(await nfcKeyed(server), isTrue);
        expect(await tablet.service.syncNow(), isNull);
      });

      test('a passphrase typed in NFC needs nothing written again', () async {
        final server = _server();
        await (_Device(
          server,
          codec: const _AsTypedCodec(),
        )..history.set('a', 'old', 1)).setUp(composed);
        final tablet = _Device(server);
        await tablet.setUp(composed);
        final before = server.files[_filePath];
        expect(await tablet.service.syncNow(), isNull);
        expect(server.files[_filePath], same(before));
      });

      test('new files are made with the NFC passphrase', () async {
        final fresh = _server();
        await _Device(fresh).setUp(decomposed);
        await _Device(fresh).setUp(composed);
        expect(await nfcKeyed(fresh), isTrue);
      });
    });

    test('joins a file another device created in the meantime', () async {
      final server = _server();
      final tablet = _Device(server)..history.set('b', 'y', 1);
      final probe = await tablet.service.probe(_connect());
      expect(probe.hasSyncFile, isFalse);
      await (_Device(server)..history.set('a', 'x', 1)).setUp();
      await tablet.service.setUp(
        connection: _connect(),
        passphrase: 'correct horse',
        config: _config,
        probed: probe,
      );
      expect(tablet.history.values, {'a': 'x', 'b': 'y'});
    });

    test('without a probe, and without its own data', () async {
      final device = _Device(_server());
      await device.service.setUp(
        connection: _connect(),
        passphrase: 'p',
        config: _config,
      );
      expect(device.service.state.unlocked, isTrue);
    });

    test('is refused in Offline only', () async {
      final device = _Device(_server())..mode = PrivacyMode.offlineOnly;
      await expectLater(device.setUp(), _fails(SyncFailure.offlineOnly));
    });

    test('a status that cannot be stored is kept in memory', () async {
      final prefs = _FlakyStore()..failing.add(SyncStore.stateKey);
      final device = _Device(_server(), prefs: prefs);
      await device.setUp();
      expect(device.service.state.status.lastResult, SyncResult.sent);
      expect(await device.service.syncNow(), isNull);
      prefs.failing.add(SyncStore.configKey);
      await device.service.updateOptions(_config.copyWith(wifiOnly: true));
      expect(device.service.state.config!.wifiOnly, isTrue);
      await device.service.dispose();
    });

    test('fails when the secrets cannot be stored', () async {
      final device = _Device(_server(), secrets: _FailingStore());
      await expectLater(device.setUp(), _fails(SyncFailure.localData));
      expect(device.service.state.running, isFalse);
    });
  });

  group('when it runs', () {
    test('load reads the stored setup', () async {
      final device = _Device(_server());
      await device.service.load();
      expect(device.service.state.loaded, isTrue);
      expect(device.service.state.isSetUp, isFalse);
      await device.setUp();
      final again = device.restart();
      await again.load();
      expect(again.state.isSetUp, isTrue);
      expect(again.state.unlocked, isTrue);
      expect(again.state.status.lastResult, SyncResult.sent);
    });

    test('start syncs at app start', () async {
      final server = _server();
      final phone = _Device(server);
      await phone.setUp();
      final tablet = _Device(server)..history.set('b', 'y', 1);
      await tablet.setUp();
      final restarted = phone.restart();
      await restarted.start();
      expect(phone.history.values, {'b': 'y'});
      expect(restarted.state.status.lastResult, SyncResult.received);
    });

    test('nothing runs by itself in Offline only or on a metered network '
        'with Wi-Fi only', () async {
      final device = _Device(_server());
      await device.setUp();
      await device.service.updateOptions(_config.copyWith(wifiOnly: true));
      device.server.requests.clear();
      device
        ..metered = true
        ..restart();
      await device.service.start();
      device
        ..metered = false
        ..mode = PrivacyMode.offlineOnly
        ..restart();
      await device.service.start();
      expect(device.server.requests, isEmpty);
      expect(await device.service.syncNow(), SyncFailure.offlineOnly);
      // Sync now runs over a metered network.
      device
        ..mode = PrivacyMode.online
        ..metered = true;
      expect(await device.service.syncNow(), isNull);
      expect(device.server.requests, isNotEmpty);
    });

    test(
      'a change syncs after the debounce, only when synced data changed',
      () async {
        final device = _Device(_server());
        await device.setUp();
        device.server.requests.clear();
        device.service.notifyChanged();
        expect(device.service.hasPendingChange, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(device.service.hasPendingChange, isFalse);
        expect(device.server.requests, isEmpty);
        device.history.set('a', 'x', 2);
        device.service
          ..notifyChanged()
          ..notifyChanged();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(device.server.methods, ['GET', 'PUT']);
      },
    );

    test(
      'after a failure only the user can fix, changes wait for them',
      () async {
        final device = _Device(_server());
        await device.setUp();
        device.server.intercept = (_) => http.Response('', 401);
        expect(await device.service.syncNow(), SyncFailure.authFailed);
        device.history.set('a', 'x', 2);
        device.server.requests.clear();
        device.service.notifyChanged();
        await device.service.flush();
        expect(device.server.requests, isEmpty);
        // A start still tries once.
        await device.restart().start();
        expect(device.server.requests, hasLength(1));
      },
    );

    test('flush runs a pending change now', () async {
      final device = _Device(_server(), debounce: const Duration(hours: 1));
      await device.setUp();
      device.history.set('a', 'x', 2);
      device.server.requests.clear();
      await device.service.flush();
      expect(device.server.requests, isEmpty);
      device.service.notifyChanged();
      await device.service.flush();
      expect(device.server.methods, ['GET', 'PUT']);
      expect(device.service.hasPendingChange, isFalse);
    });

    test('notifyChanged does nothing before setup', () {
      final device = _Device(_server())..service.notifyChanged();
      expect(device.service.hasPendingChange, isFalse);
    });

    test('syncNow before setup does nothing', () async {
      expect(await _Device(_server()).service.syncNow(), isNull);
    });

    test('failures are recorded and kept', () async {
      final device = _Device(_server());
      await device.setUp();
      device.server.intercept = (_) => http.Response('', 503);
      expect(await device.service.syncNow(), SyncFailure.server);
      final status = device.service.state.status;
      expect(status.lastFailure, SyncFailure.server);
      expect(status.lastResult, SyncResult.sent);
      final again = device.restart();
      await again.load();
      expect(again.state.status.lastFailure, SyncFailure.server);
      device.server.intercept = null;
      expect(await again.syncNow(), isNull);
      expect(again.state.status.lastFailure, isNull);
    });

    test('a failing section is recorded as localData', () async {
      final device = _Device(_server());
      await device.setUp();
      device.history.exportError = Exception('disk');
      expect(await device.service.syncNow(), SyncFailure.localData);
    });

    test('emits states while it runs', () async {
      final device = _Device(_server());
      await device.setUp();
      final states = <bool>[];
      final subscription = device.service.states.listen(
        (state) => states.add(state.running),
      );
      await device.service.syncNow();
      await Future<void>.delayed(Duration.zero);
      expect(states.first, isTrue);
      expect(states.last, isFalse);
      await subscription.cancel();
    });
  });

  group('unlock', () {
    test('the web app forgot the password and the key', () async {
      final server = _server();
      final device = _Device(server);
      await device.setUp();
      device.secrets.values.clear();
      final tab = device.restart();
      await tab.load();
      expect(tab.state.isSetUp, isTrue);
      expect(tab.state.unlocked, isFalse);
      expect(await tab.syncNow(), SyncFailure.needsUnlock);
      server.requests.clear();
      await tab.start();
      expect(server.requests, isEmpty);
      await expectLater(
        tab.unlock(passphrase: 'correct horse'),
        _fails(SyncFailure.needsUnlock),
      );
      await tab.unlock(password: 'app-password', passphrase: 'correct horse');
      expect(tab.state.unlocked, isTrue);
      expect(device.secrets.values, contains(SyncStore.keyKey));
    });

    test('a new password alone', () async {
      final device = _Device(_server());
      await device.setUp();
      device.server.intercept = (request) =>
          request.headers['Authorization']!.contains(
            base64Encode(utf8.encode('alice:app-password')),
          )
          ? http.Response('', 401)
          : null;
      expect(await device.service.syncNow(), SyncFailure.authFailed);
      // The server now wants the new one.
      device.server.intercept = null;
      await expectLater(
        device.service.unlock(password: 'other'),
        _fails(SyncFailure.authFailed),
      );
      expect(device.service.state.status.lastFailure, SyncFailure.authFailed);
      await device.service.unlock(password: 'app-password');
      expect(device.service.state.status.lastFailure, isNull);
    });

    test('a passphrase changed on another device', () async {
      final server = _server();
      final phone = _Device(server)..history.set('a', 'x', 1);
      await phone.setUp();
      final tablet = _Device(server);
      await tablet.setUp();
      await phone.service.changePassphrase('new passphrase');
      expect(await tablet.service.syncNow(), SyncFailure.passphraseChanged);
      await expectLater(
        tablet.service.unlock(passphrase: 'correct horse'),
        _fails(SyncFailure.wrongPassphrase),
      );
      await tablet.service.unlock(passphrase: 'new passphrase');
      expect(await tablet.service.syncNow(), isNull);
      expect(tablet.service.state.status.lastFailure, isNull);
    });

    test('does nothing without setup, and not in Offline only', () async {
      final device = _Device(_server());
      await device.service.unlock(password: 'x');
      expect(device.server.requests, isEmpty);
      await device.setUp();
      device.mode = PrivacyMode.offlineOnly;
      await expectLater(
        device.service.unlock(password: 'x'),
        _fails(SyncFailure.offlineOnly),
      );
    });
  });

  group('changePassphrase', () {
    test('needs an unlocked setup, and not Offline only', () async {
      final device = _Device(_server());
      await expectLater(
        device.service.changePassphrase('x'),
        _fails(SyncFailure.needsUnlock),
      );
      await device.setUp();
      device.mode = PrivacyMode.offlineOnly;
      await expectLater(
        device.service.changePassphrase('x'),
        _fails(SyncFailure.offlineOnly),
      );
    });

    test('keeps the old key when the server refuses', () async {
      final device = _Device(_server());
      await device.setUp();
      final key = device.secrets.values[SyncStore.keyKey];
      device.server.intercept = (request) =>
          request.method == 'PUT' ? http.Response('', 507) : null;
      await expectLater(
        device.service.changePassphrase('x'),
        _fails(SyncFailure.insufficientStorage),
      );
      expect(device.secrets.values[SyncStore.keyKey], key);
    });
  });

  group('updateOptions', () {
    test('keeps the account and changes what is synced', () async {
      final device = _Device(_server());
      await device.service.updateOptions(_config);
      expect(device.service.state.isSetUp, isFalse);
      await device.setUp();
      await device.service.updateOptions(
        SyncConfig(
          server: Uri.parse('https://ignored.example/'),
          username: 'ignored',
          excludedSections: const {},
          includeSecrets: true,
          wifiOnly: true,
        ),
      );
      final config = device.service.state.config!;
      expect(config.server, _serverUrl);
      expect(config.username, 'alice');
      expect(config.excludedSections, isEmpty);
      expect(config.syncsSecrets, isTrue);
      expect(config.wifiOnly, isTrue);
      expect(device.service.hasPendingChange, isTrue);
      final again = device.restart();
      await again.load();
      expect(again.state.config, config);
    });
  });

  group('turnOff and forget', () {
    test('turnOff forgets everything here and keeps the file', () async {
      final device = _Device(_server());
      await device.setUp();
      await device.service.turnOff();
      expect(device.service.state.isSetUp, isFalse);
      expect(device.secrets.values, isEmpty);
      expect(device.prefs.values, isEmpty);
      expect(device.server.files, contains(_filePath));
    });

    test('turnOff can delete the file first', () async {
      final device = _Device(_server());
      await device.setUp();
      await device.service.turnOff(deleteRemote: true);
      expect(device.server.files, isEmpty);
      expect(device.service.state.isSetUp, isFalse);
    });

    test('a failed delete forgets nothing', () async {
      final device = _Device(_server());
      await device.setUp();
      device.server.intercept = (_) => http.Response('', 403);
      await expectLater(
        device.service.turnOff(deleteRemote: true),
        _fails(SyncFailure.forbidden),
      );
      expect(device.service.state.isSetUp, isTrue);
      device.mode = PrivacyMode.offlineOnly;
      await expectLater(
        device.service.turnOff(deleteRemote: true),
        _fails(SyncFailure.offlineOnly),
      );
      await device.service.forget();
      await expectLater(
        device.service.turnOff(deleteRemote: true),
        _fails(SyncFailure.needsUnlock),
      );
    });

    test('forget stops a pending sync and a running one', () async {
      final device = _Device(_server(), debounce: const Duration(hours: 1));
      await (_Device(device.server)..history.set('b', 'y', 1)).setUp();
      await device.setUp();
      device.service.notifyChanged();
      device.history.set('a', 'x', 2);
      device.server.requests.clear();
      final restores = device.history.restores.length;
      final answer = Completer<void>();
      device.server.intercept = (request) async {
        if (request.method == 'GET') await answer.future;
        return null;
      };
      final running = device.service.syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(device.service.state.running, isTrue);
      final forgetting = device.service.forget();
      answer.complete();
      await forgetting;
      expect(await running, isNull);
      expect(device.service.hasPendingChange, isFalse);
      expect(device.service.state.isSetUp, isFalse);
      expect(device.service.state.running, isFalse);
      expect(device.prefs.values, isEmpty);
      expect(device.server.methods, ['GET']);
      expect(device.history.restores, hasLength(restores));
    });

    test('dispose stops the timer and the stream', () async {
      final device = _Device(_server());
      await device.setUp();
      device.service.notifyChanged();
      await device.service.dispose();
      expect(device.service.hasPendingChange, isFalse);
      device.service.notifyChanged();
      expect(device.service.hasPendingChange, isFalse);
    });
  });

  test('connections and probes', () {
    expect(_connect().toString(), 'SyncConnection(alice)');
    expect(_connect(), _connect());
    expect(_connect(password: 'x'), isNot(_connect()));
    final probe = SyncProbe(
      server: _serverUrl,
      folderExists: true,
      file: const WebDavMissing(),
    );
    expect(
      probe,
      SyncProbe(
        server: _serverUrl,
        folderExists: true,
        file: const WebDavMissing(),
      ),
    );
    expect(probe.hasSyncFile, isFalse);
  });

  test('a file in the folder that is not from Mozhi', () async {
    final server = _server(folders: {'/dav/', '/dav/Mozhi/'})
      ..put(_filePath, utf8.encode('hello'));
    final device = _Device(server);
    await expectLater(device.setUp(), _fails(SyncFailure.notSyncFile));
  });

  test('uses the session client (sync in the network activity, and the '
      "proxy's longer timeout)", () async {
    final server = _server();
    final previous = NetworkSession.current;
    addTearDown(() => NetworkSession.current = previous);
    for (final proxy in [null, '127.0.0.1:8118']) {
      final session = NetworkSession(proxy: proxy, httpClient: server.client);
      NetworkSession.current = session;
      final service = SyncService(
        registry: registryOf([]),
        prefs: MemoryStore(),
        secrets: MemoryStore(),
        codec: testCodec,
      );
      await service.probe(_connect());
      expect(
        session.ledger.entries.map((e) => e.purpose),
        everyElement(EgressPurpose.sync),
      );
      expect(session.ledger.entries, isNotEmpty);
    }
  });

  test('requests go through the session client by default', () {
    expect(
      SyncService(
        registry: registryOf([]),
        prefs: MemoryStore(),
        secrets: MemoryStore(),
      ).state,
      const SyncState(),
    );
    expect(WebDavClient.defaultTimeout, const Duration(seconds: 60));
  });
}

/// Preferences that refuse to store the keys in [failing].
class _FlakyStore extends MemoryStore {
  final failing = <String>{};

  @override
  Future<void> write(String key, String value) async {
    if (failing.contains(key)) throw Exception('disk full');
    await super.write(key, value);
  }
}

/// Secure storage that refuses to store anything.
class _FailingStore extends MemoryStore {
  @override
  Future<void> write(String key, String value) async =>
      throw Exception('keystore');
}
