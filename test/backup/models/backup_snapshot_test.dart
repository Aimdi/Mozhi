import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/backup/models/backup_snapshot.dart';

void main() {
  final snapshot = BackupSnapshot(
    createdAt: DateTime.utc(2026, 10, 22, 13),
    appVersion: '1.4.0+12',
    sections: const {
      'history': BackupSectionData(
        version: 1,
        data: {
          'entries': [
            {'id': '1'},
          ],
        },
      ),
      'settings': BackupSectionData(version: 2, data: null),
    },
  );

  group('BackupSnapshot', () {
    test('writes the documented JSON', () {
      expect(snapshot.toJson(), {
        'format': 'mozhi-backup',
        'formatVersion': 1,
        'createdAt': '2026-10-22T13:00:00.000Z',
        'appVersion': '1.4.0+12',
        'sections': {
          'history': {
            'version': 1,
            'data': {
              'entries': [
                {'id': '1'},
              ],
            },
          },
          'settings': {'version': 2, 'data': null},
        },
      });
    });

    test('reads what it writes, through JSON', () {
      final json =
          jsonDecode(jsonEncode(snapshot.toJson())) as Map<String, Object?>;

      expect(BackupSnapshot.fromJson(json), snapshot);
    });

    test('writes createdAt in UTC', () {
      final local = BackupSnapshot(
        createdAt: DateTime.utc(2026).toLocal(),
        appVersion: '1',
        sections: const {},
      );

      expect(local.toJson()['createdAt'], '2026-01-01T00:00:00.000Z');
    });

    group('fromJson refuses', () {
      Map<String, Object?> json([Map<String, Object?> changes = const {}]) => {
        ...snapshot.toJson(),
        ...changes,
      };

      test('another format', () {
        expect(
          () => BackupSnapshot.fromJson(json({'format': 'other'})),
          throwsFormatException,
        );
      });

      test('an invalid formatVersion', () {
        for (final version in [null, 0, '1']) {
          expect(
            () => BackupSnapshot.fromJson(json({'formatVersion': version})),
            throwsFormatException,
          );
        }
      });

      test('a newer formatVersion, saying so', () {
        expect(
          () => BackupSnapshot.fromJson(json({'formatVersion': 2})),
          throwsA(
            isA<BackupSnapshotVersionException>().having(
              (e) => e.version,
              'version',
              2,
            ),
          ),
        );
      });

      test('an invalid createdAt', () {
        for (final createdAt in [null, 'yesterday', 12]) {
          expect(
            () => BackupSnapshot.fromJson(json({'createdAt': createdAt})),
            throwsFormatException,
          );
        }
      });

      test('an invalid appVersion', () {
        expect(
          () => BackupSnapshot.fromJson(json({'appVersion': 1})),
          throwsFormatException,
        );
      });

      test('invalid sections', () {
        for (final sections in [
          null,
          <Object?>[],
          {'history': 1},
          {
            'history': {'data': 1},
          },
          {
            'history': {'version': 0},
          },
        ]) {
          expect(
            () => BackupSnapshot.fromJson(json({'sections': sections})),
            throwsFormatException,
            reason: '$sections',
          );
        }
      });
    });
  });

  group('BackupSectionData', () {
    test('round-trips', () {
      const data = BackupSectionData(version: 3, data: [1, 'a', true]);

      expect(BackupSectionData.fromJson(data.toJson()), data);
    });
  });
}
