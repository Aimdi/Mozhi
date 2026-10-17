import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/platform/android_device.dart';
import 'package:mozhi/platform/privacy_channel.dart';
import 'package:mozhi/platform/secure_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group(SecureScreen, () {
    final channel = privacyChannel();
    late List<MethodCall> calls;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() {
      calls = [];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
    });

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('sets and clears FLAG_SECURE on Android', () async {
      final screen = SecureScreen(isSupported: true);

      await screen.setEnabled(enabled: true);
      await screen.setEnabled(enabled: false);

      expect(calls.map((c) => (c.method, c.arguments)), [
        ('setSecureScreen', true),
        ('setSecureScreen', false),
      ]);
    });

    test('does nothing where unsupported', () async {
      await SecureScreen(isSupported: false).setEnabled(enabled: true);

      expect(calls, isEmpty);
    });

    test('is supported on Android devices only', () async {
      // Tests run on a desktop host, even with the Android target platform.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final screen = SecureScreen();
      debugDefaultTargetPlatformOverride = null;

      expect(runsOnAndroid, isFalse);
      expect(screen.isSupported, isFalse);
      await screen.setEnabled(enabled: true);
      expect(calls, isEmpty);
    });

    test('ignores platform errors and a missing platform side', () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => throw PlatformException(code: 'denied'),
      );
      await SecureScreen(isSupported: true).setEnabled(enabled: true);

      messenger.setMockMethodCallHandler(channel, null);
      await SecureScreen(isSupported: true).setEnabled(enabled: true);
    });

    test('uses the privacy channel', () {
      expect(privacyChannel().name, 'io.github.aimdi.mozhi/privacy');
      expect(SecureScreen.instance, isA<SecureScreen>());
    });
  });
}
