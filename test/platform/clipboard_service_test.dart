import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/platform/clipboard_service.dart';
import 'package:mozhi/platform/privacy_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group(ClipboardService, () {
    final channel = privacyChannel();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<MethodCall> calls;
    late List<String?> fallback;

    Future<void> setData(ClipboardData data) async => fallback.add(data.text);

    void answer(Object? Function(MethodCall call) handler) =>
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return handler(call);
        });

    setUp(() {
      calls = [];
      fallback = [];
    });

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('marks the copy sensitive on Android 13+', () async {
      answer((_) => true);
      final service = ClipboardService(isAndroid: true, setData: setData);
      expect(service.systemShowsCopyConfirmation, isFalse);

      await service.copyText('secret');

      expect(calls.single.method, 'copySensitiveText');
      expect(calls.single.arguments, 'secret');
      expect(fallback, isEmpty);
      expect(service.systemShowsCopyConfirmation, isTrue);
    });

    test('falls back on older Android, and remembers it', () async {
      answer((_) => false);
      final service = ClipboardService(isAndroid: true, setData: setData);

      await service.copyText('one');
      await service.copyText('two');

      expect(calls, hasLength(1));
      expect(fallback, ['one', 'two']);
      expect(service.systemShowsCopyConfirmation, isFalse);
    });

    test('falls back without the platform side', () async {
      final service = ClipboardService(isAndroid: true, setData: setData);

      await service.copyText('one');

      expect(fallback, ['one']);
      expect(service.systemShowsCopyConfirmation, isFalse);
    });

    test('falls back on a platform error and tries again later', () async {
      answer((_) => throw PlatformException(code: 'busy'));
      final service = ClipboardService(isAndroid: true, setData: setData);

      await service.copyText('one');
      answer((_) => true);
      await service.copyText('two');

      expect(fallback, ['one']);
      expect(calls, hasLength(2));
      expect(service.systemShowsCopyConfirmation, isTrue);
    });

    test('treats a null answer as unsupported', () async {
      answer((_) => null);
      final service = ClipboardService(isAndroid: true, setData: setData);

      await service.copyText('one');

      expect(fallback, ['one']);
    });

    test('uses the Flutter clipboard elsewhere', () async {
      answer((_) => true);
      final service = ClipboardService(isAndroid: false, setData: setData);

      await service.copyText('one');

      expect(calls, isEmpty);
      expect(fallback, ['one']);
      expect(service.systemShowsCopyConfirmation, isFalse);
    });

    test('the top-level helpers use the shared instance', () async {
      final previous = ClipboardService.instance;
      addTearDown(() => ClipboardService.instance = previous);
      answer((_) => true);
      ClipboardService.instance = ClipboardService(
        isAndroid: true,
        setData: setData,
      );

      await copyText('shared');

      expect(calls.single.arguments, 'shared');
      expect(systemShowsCopyConfirmation, isTrue);
    });

    test('defaults to the system clipboard', () async {
      final copied = <Object?>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add(call.arguments);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );

      answer((_) => true);

      // Not an Android device (tests run on a desktop host): no channel.
      await ClipboardService().copyText('plain');

      expect(copied, [
        {'text': 'plain'},
      ]);
      expect(calls, isEmpty);
    });
  });
}
