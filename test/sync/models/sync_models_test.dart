import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/sync/data/webdav_client.dart';
import 'package:mozhi/sync/models/sync_config.dart';
import 'package:mozhi/sync/models/sync_status.dart';

void main() {
  group('SyncConfig', () {
    final config = SyncConfig(
      server: Uri.parse('https://cloud.example.org/dav/'),
      username: 'alice',
    );

    test('defaults: the Mozhi folder, everything but the settings', () {
      expect(config.folder, 'Mozhi');
      expect(config.syncs('history'), isTrue);
      expect(config.syncs('settings'), isFalse);
      expect(config.syncedOf(['history', 'settings', 'practice']), {
        'history',
        'practice',
      });
      expect(config.syncsSecrets, isFalse);
      expect(
        config.folderUrl.toString(),
        'https://cloud.example.org/dav/Mozhi/',
      );
    });

    test('secrets only travel with the settings', () {
      expect(config.copyWith(includeSecrets: true).syncsSecrets, isFalse);
      expect(
        config
            .copyWith(includeSecrets: true, excludedSections: {})
            .syncsSecrets,
        isTrue,
      );
    });

    test('round-trips through JSON', () {
      final custom = config.copyWith(
        folder: 'Apps/Mozhi',
        excludedSections: {'presets', 'glossaries'},
        includeSecrets: true,
        wifiOnly: true,
      );
      expect(SyncConfig.tryParse(custom.toJson()), custom);
      expect(custom.toJson()['excludedSections'], ['glossaries', 'presets']);
      expect(
        SyncConfig.tryParse({'server': 'https://a.example', 'username': 'u'}),
        SyncConfig(server: Uri.parse('https://a.example'), username: 'u'),
      );
    });

    test('tryParse refuses what is not a config', () {
      expect(SyncConfig.tryParse(null), isNull);
      expect(SyncConfig.tryParse({'server': 'x'}), isNull);
      expect(
        SyncConfig.tryParse({'server': 'not a url', 'username': 'u'}),
        isNull,
      );
      expect(SyncConfig.tryParse({'server': ':::', 'username': 'u'}), isNull);
    });
  });

  group('SyncCursor', () {
    test('round-trips through JSON', () {
      const cursor = SyncCursor(fingerprint: 'abc', etag: '"e"');
      expect(SyncCursor.tryParse(cursor.toJson()), cursor);
      expect(
        SyncCursor.tryParse({'fingerprint': 'abc', 'etag': 1}),
        const SyncCursor(fingerprint: 'abc'),
      );
      expect(SyncCursor.tryParse({'etag': '"e"'}), isNull);
    });

    test("keeps the file's fingerprint when it differs from this device's", () {
      const cursor = SyncCursor(
        fingerprint: 'abc',
        etag: '"e"',
        remoteFingerprint: 'def',
      );
      expect(cursor.toJson()['remote'], 'def');
      expect(SyncCursor.tryParse(cursor.toJson()), cursor);
      expect(cursor.fileFingerprint, 'def');
      // Written by earlier versions: the file held this device's data.
      const earlier = SyncCursor(fingerprint: 'abc');
      expect(earlier.toJson().containsKey('remote'), isFalse);
      expect(earlier.fileFingerprint, 'abc');
      expect(SyncCursor.tryParse({'fingerprint': 'abc', 'remote': 1}), earlier);
    });
  });

  group('SyncStatus', () {
    final at = DateTime.utc(2026, 10, 22, 12);

    test('a success clears the failure, a failure keeps the success', () {
      final ok = const SyncStatus().succeeded(at, SyncResult.sent);
      final failed = ok.failed(at, SyncFailure.offline);
      expect(failed.lastSyncAt, at);
      expect(failed.lastResult, SyncResult.sent);
      expect(failed.lastFailure, SyncFailure.offline);
      expect(failed.lastFailureAt, at);
      final again = failed.succeeded(at, SyncResult.unchanged);
      expect(again.lastFailure, isNull);
      expect(again.lastFailureAt, isNull);
    });

    test('round-trips through JSON (in local time)', () {
      final status = const SyncStatus()
          .succeeded(at, SyncResult.received)
          .failed(at, SyncFailure.authFailed);
      final parsed = SyncStatus.fromJson(status.toJson());
      expect(parsed.lastSyncAt, at.toLocal());
      expect(parsed.lastSyncAt!.isUtc, isFalse);
      expect(parsed.lastResult, SyncResult.received);
      expect(parsed.lastFailure, SyncFailure.authFailed);
      expect(SyncStatus.fromJson('x'), const SyncStatus());
      expect(
        SyncStatus.fromJson(const {'lastResult': 'nope', 'lastSyncAt': 3}),
        const SyncStatus(),
      );
    });
  });

  group('SyncFailure', () {
    test('every WebDAV failure has a sync failure of the same name', () {
      for (final failure in WebDavFailure.values) {
        expect(SyncFailure.ofWebDav(failure).name, failure.name);
      }
    });

    test('some failures need the user', () {
      expect(SyncFailure.authFailed.needsUser, isTrue);
      expect(SyncFailure.passphraseChanged.needsUser, isTrue);
      expect(SyncFailure.newerVersion.needsUser, isTrue);
      expect(SyncFailure.offline.needsUser, isFalse);
      expect(SyncFailure.conflict.needsUser, isFalse);
    });

    test('SyncException from a WebDAV failure, without details', () {
      final error = SyncException.fromWebDav(
        const WebDavException(WebDavFailure.forbidden, statusCode: 403),
      );
      expect(error.failure, SyncFailure.forbidden);
      expect(error.statusCode, 403);
      expect(error.toString(), 'SyncException(forbidden, 403)');
      expect(
        const SyncException(SyncFailure.damaged).toString(),
        'SyncException(damaged)',
      );
    });
  });
}
