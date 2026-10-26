import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/screen_translate/data/screen_translate_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(
    MethodChannelScreenTranslateControls.channelName,
  );
  late List<MethodCall> calls;
  late Object? Function(MethodCall call) answer;

  void mock(Future<Object?>? Function(MethodCall call)? handler) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);

  setUp(() {
    calls = [];
    answer = (_) => null;
    mock((call) async {
      calls.add(call);
      return answer(call);
    });
  });

  tearDown(() => mock(null));

  final controls = MethodChannelScreenTranslateControls(isAndroid: true);

  group('on Android', () {
    test('is supported', () {
      expect(controls.isSupported, isTrue);
    });

    test('reads the status', () async {
      answer = (_) => {
        'bubbleRunning': true,
        'canDrawOverlays': true,
        'notificationsAllowed': false,
        'canAddTile': true,
      };
      final status = await controls.status();
      expect(
        status,
        const ScreenTranslateSupport(
          bubbleRunning: true,
          canDrawOverlays: true,
          notificationsAllowed: false,
          canAddTile: true,
        ),
      );
      expect(status.hashCode, isNot(const ScreenTranslateSupport().hashCode));
      expect(status.toString(), contains('bubble: true'));
      expect(calls.single.method, 'status');
    });

    test('an empty status is all off', () async {
      expect(await controls.status(), const ScreenTranslateSupport());
      answer = (_) => <String, Object?>{};
      expect(await controls.status(), const ScreenTranslateSupport());
    });

    test('asks for the permissions and toggles the bubble', () async {
      answer = (call) => call.method != 'requestNotificationPermission';
      expect(await controls.requestOverlayPermission(), isTrue);
      expect(await controls.requestNotificationPermission(), isFalse);
      expect(await controls.startBubble(), isTrue);
      await controls.stopBubble();
      expect(calls.map((c) => c.method), [
        'requestOverlayPermission',
        'requestNotificationPermission',
        'startBubble',
        'stopBubble',
      ]);
    });

    test('a missing answer is no', () async {
      expect(await controls.startBubble(), isFalse);
    });

    test('offers the tile', () async {
      for (final (value, result) in [
        ('added', TileRequestResult.added),
        ('alreadyAdded', TileRequestResult.alreadyAdded),
        ('notAdded', TileRequestResult.notAdded),
        ('unsupported', TileRequestResult.unsupported),
        ('failed', TileRequestResult.failed),
        ('what', TileRequestResult.failed),
      ]) {
        answer = (_) => value;
        expect(await controls.requestAddTile(), result, reason: value);
      }
    });

    test('platform errors count as no', () async {
      mock((call) async => throw PlatformException(code: 'boom'));
      expect(await controls.status(), const ScreenTranslateSupport());
      expect(await controls.requestOverlayPermission(), isFalse);
      expect(await controls.requestAddTile(), TileRequestResult.failed);
      await controls.stopBubble();
    });

    test('without the platform side everything is off', () async {
      mock(null);
      expect(await controls.status(), const ScreenTranslateSupport());
      expect(await controls.startBubble(), isFalse);
      expect(await controls.requestAddTile(), TileRequestResult.unsupported);
      await controls.stopBubble();
    });
  });

  group('elsewhere', () {
    final desktop = MethodChannelScreenTranslateControls(isAndroid: false);

    test('is unsupported and calls nothing', () async {
      expect(desktop.isSupported, isFalse);
      expect(await desktop.status(), const ScreenTranslateSupport());
      expect(await desktop.requestOverlayPermission(), isFalse);
      expect(await desktop.requestNotificationPermission(), isFalse);
      expect(await desktop.startBubble(), isFalse);
      await desktop.stopBubble();
      expect(await desktop.requestAddTile(), TileRequestResult.unsupported);
      expect(calls, isEmpty);
    });

    test('the app instance follows the host (not Android in tests)', () {
      expect(
        MethodChannelScreenTranslateControls.instance.isSupported,
        isFalse,
      );
      expect(MethodChannelScreenTranslateControls().isSupported, isFalse);
    });
  });
}
