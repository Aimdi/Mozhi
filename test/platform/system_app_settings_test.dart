import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/platform/system_app_settings.dart';

void main() {
  group(SystemAppSettings, () {
    late Future<bool> Function() previous;

    setUp(() => previous = SystemAppSettings.opener);

    tearDown(() {
      SystemAppSettings.opener = previous;
      SystemAppSettings.debugIsSupported = null;
    });

    test('is not offered off Android (tests run on a desktop)', () async {
      expect(SystemAppSettings.isSupported, isFalse);
      expect(await SystemAppSettings.open(), isFalse);
    });

    test('opens the page where supported', () async {
      var opened = 0;
      SystemAppSettings.debugIsSupported = true;
      SystemAppSettings.opener = () async {
        opened++;
        return true;
      };

      expect(await SystemAppSettings.open(), isTrue);
      expect(opened, 1);
    });

    test('a failure reads as not opened', () async {
      SystemAppSettings.debugIsSupported = true;
      SystemAppSettings.opener = () async => throw StateError('no activity');

      expect(await SystemAppSettings.open(), isFalse);
    });

    test('the default opener answers false off Android', () async {
      SystemAppSettings.debugIsSupported = true;

      expect(await SystemAppSettings.open(), isFalse);
    });
  });
}
