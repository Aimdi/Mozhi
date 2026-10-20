import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/platform/android_device.dart';
import 'package:mozhi/platform/privacy_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('androidSdkInt', () {
    final channel = privacyChannel();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<MethodCall> calls;

    void answer(Object? Function() reply) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return reply();
      });
    }

    setUp(() => calls = []);
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('reports what Android answers', () async {
      answer(() => 28);

      expect(await androidSdkInt(isAndroid: true), 28);
      expect(calls.single.method, 'sdkInt');
    });

    test('is null on platform errors', () async {
      answer(() => throw PlatformException(code: 'denied'));

      expect(await androidSdkInt(isAndroid: true), isNull);
    });

    test('is null without a platform side', () async {
      expect(await androidSdkInt(isAndroid: true), isNull);
    });

    test('is null without asking off Android', () async {
      answer(() => 28);

      // Tests run on a desktop host: the default is not Android.
      expect(runsOnAndroid, isFalse);
      expect(await androidSdkInt(), isNull);
      expect(calls, isEmpty);
    });
  });
}
