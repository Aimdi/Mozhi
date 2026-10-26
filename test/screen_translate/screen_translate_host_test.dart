import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/screen_translate/screen_translate_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(ScreenTranslateHost.channelName);
  late List<MethodCall> calls;
  late Object? Function(MethodCall call) answer;

  setUp(() {
    calls = [];
    answer = (_) => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return answer(call);
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  ScreenTranslateHost host([String route = ScreenTranslateHost.location]) =>
      ScreenTranslateHost(initialRoute: () => route);

  final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);

  group('isActive', () {
    test('only in the window started at its location', () {
      expect(host().isActive, isTrue);
      expect(host('${ScreenTranslateHost.location}?x=1').isActive, isTrue);
      expect(host('/').isActive, isFalse);
      expect(host('/quick-translate').isActive, isFalse);
    });

    test('not in the main window of the tests', () {
      expect(ScreenTranslateHost().isActive, isFalse);
      expect(ScreenTranslateHost.instance.isActive, isFalse);
    });
  });

  group('capture', () {
    test('answers the screenshot, asked once', () async {
      answer = (_) => {
        'status': 'ok',
        'bytes': png,
        'width': 1080,
        'height': 2400,
        'blank': false,
      };
      final window = host();
      final first = await window.capture();
      final second = await window.capture();

      expect(first, isA<ScreenCaptured>());
      final captured = first as ScreenCaptured;
      expect(captured.bytes, png);
      expect(captured.width, 1080);
      expect(captured.height, 2400);
      expect(captured.blank, isFalse);
      expect(captured.toString(), contains('1080x2400'));
      expect(identical(first, second), isTrue);
      expect(calls.map((c) => c.method), ['screenshot']);
    });

    test('reports a black frame', () async {
      answer = (_) => {
        'status': 'ok',
        'bytes': png,
        'width': 10,
        'height': 20,
        'blank': true,
      };
      final captured = await host().capture() as ScreenCaptured;
      expect(captured.blank, isTrue);
      expect(captured.toString(), contains('blank'));
    });

    test('reports a declined consent', () async {
      answer = (_) => {'status': 'declined'};
      expect(await host().capture(), isA<ScreenCaptureDeclined>());
    });

    test('reports failures with their reason', () async {
      answer = (_) => {'status': 'failed', 'reason': 'projection'};
      final failure = await host().capture();
      expect(failure, const ScreenCaptureFailed('projection'));
      expect(
        failure.hashCode,
        const ScreenCaptureFailed('projection').hashCode,
      );
      expect(failure.toString(), 'ScreenCaptureFailed(projection)');
    });

    test('a platform error is a failure', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'boom');
          });
      expect(await host().capture(), const ScreenCaptureFailed('boom'));
    });

    test('without the platform side it fails', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      expect(await host().capture(), const ScreenCaptureFailed('unavailable'));
    });

    test('outside the window nothing is asked', () async {
      expect(await host('/').capture(), const ScreenCaptureFailed('inactive'));
      expect(calls, isEmpty);
    });
  });

  group('parseScreenCapture', () {
    test('turns anything unexpected into a failure', () {
      expect(parseScreenCapture(null), const ScreenCaptureFailed('none'));
      expect(
        parseScreenCapture({'status': 'what'}),
        const ScreenCaptureFailed('invalid'),
      );
      expect(
        parseScreenCapture({'status': 'failed'}),
        const ScreenCaptureFailed('unknown'),
      );
      for (final bad in <Map<String, Object?>>[
        {'status': 'ok', 'bytes': png, 'width': 1},
        {'status': 'ok', 'bytes': png, 'width': 0, 'height': 1},
        {'status': 'ok', 'bytes': png, 'width': 1, 'height': -1},
        {'status': 'ok', 'bytes': Uint8List(0), 'width': 1, 'height': 1},
        {'status': 'ok', 'bytes': 'png', 'width': 1, 'height': 1},
      ]) {
        expect(
          parseScreenCapture(bad),
          const ScreenCaptureFailed('invalid'),
          reason: '$bad',
        );
      }
    });
  });

  group('leaving the window', () {
    test('close, open the text or a location in the app', () async {
      final window = host();
      await window.close();
      await window.openTextInApp('Hola');
      expect(calls.map((c) => c.method), ['close', 'openInApp']);
      expect(calls.last.arguments, {'text': 'Hola'});
    });

    test('opens a location', () async {
      await host().openLocationInApp('/settings/offline');
      expect(calls.single.arguments, {'location': '/settings/offline'});
    });

    test('leaves once, and never with empty text', () async {
      final window = host();
      await window.openTextInApp('  ');
      expect(calls, isEmpty);
      await window.openLocationInApp('/settings');
      await window.openTextInApp('Hola');
      expect(calls, hasLength(1));
    });

    test('ignores platform errors and a missing platform side', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'closing');
          });
      await host().close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await host().close();
    });

    test('outside the window nothing is sent', () async {
      final window = host('/');
      await window.close();
      await window.openTextInApp('Hola');
      expect(calls, isEmpty);
    });
  });

  group('screenTranslateWindowRedirect', () {
    test('keeps the window location', () {
      final window = host();
      expect(
        screenTranslateWindowRedirect(
          Uri.parse(ScreenTranslateHost.location),
          window,
        ),
        isNull,
      );
      expect(calls, isEmpty);
    });

    test('opens other app locations in the main window', () async {
      final window = host();
      expect(
        screenTranslateWindowRedirect(
          Uri.parse('/settings/offline?x=1'),
          window,
        ),
        ScreenTranslateHost.location,
      );
      await pumpEventQueue();
      expect(calls.single.arguments, {'location': '/settings/offline?x=1'});
    });

    test('ignores the start location and odd paths', () async {
      final window = host();
      for (final location in ['/', '', '//host/x']) {
        expect(
          screenTranslateWindowRedirect(Uri.parse(location), window),
          ScreenTranslateHost.location,
        );
      }
      await pumpEventQueue();
      expect(calls, isEmpty);
    });
  });
}
