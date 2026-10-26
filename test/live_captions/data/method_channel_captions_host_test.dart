import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/live_captions/data/captions_host.dart';
import 'package:mozhi/live_captions/data/method_channel_captions_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('test/live_captions');
  const audioChannel = EventChannel('test/live_captions/audio');
  const eventsChannel = EventChannel('test/live_captions/events');

  late List<MethodCall> calls;
  late Object? Function(MethodCall call) answer;

  setUp(() {
    calls = [];
    answer = (_) => null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answer(call);
    });
  });

  tearDown(() {
    messenger
      ..setMockMethodCallHandler(channel, null)
      ..setMockStreamHandler(audioChannel, null)
      ..setMockStreamHandler(eventsChannel, null);
  });

  MethodChannelCaptionsHost build({int? sdkInt = 34, bool isAndroid = true}) =>
      MethodChannelCaptionsHost(
        sdkInt: sdkInt,
        channel: channel,
        audioChannel: audioChannel,
        eventsChannel: eventsChannel,
        isAndroid: isAndroid,
      );

  group('isSupported', () {
    test('from Android 10 on', () {
      expect(build().isSupported, isTrue);
      expect(build(sdkInt: 29).isSupported, isTrue);
      expect(build(sdkInt: 28).isSupported, isFalse);
      expect(build(sdkInt: null).isSupported, isFalse);
      expect(build(isAndroid: false).isSupported, isFalse);
    });

    test('off Android by default (a test host)', () {
      expect(MethodChannelCaptionsHost(sdkInt: 34).isSupported, isFalse);
    });

    test('unsupported, nothing is called', () async {
      final host = build(sdkInt: 28);
      expect(
        await host.start(),
        const CaptureFailed(CaptureFailure.unsupported),
      );
      await host.show(const CaptionLine(translation: 'Hi'));
      await host.stop();
      expect(calls, isEmpty);
      expect(await host.audio.isEmpty, isTrue);
      expect(await host.events.isEmpty, isTrue);
    });
  });

  group('start', () {
    test('started, with or without the caption bar', () async {
      answer = (_) => {'status': 'started', 'captionBar': true};
      expect(await build().start(), const CaptureStarted());
      answer = (_) => {'status': 'started', 'captionBar': false};
      expect(await build().start(), const CaptureStarted(captionBar: false));
      expect(calls.map((call) => call.method), ['start', 'start']);
    });

    test('declined', () async {
      answer = (_) => {'status': 'declined'};
      expect(await build().start(), const CaptureDeclined());
    });

    test('failed, with the reason', () async {
      for (final reason in CaptureFailure.values) {
        answer = (_) => {'status': 'failed', 'reason': reason.name};
        expect(await build().start(), CaptureFailed(reason));
      }
      answer = (_) => {'status': 'failed', 'reason': 'noWindow'};
      expect(
        await build().start(),
        const CaptureFailed(CaptureFailure.unknown),
      );
      answer = (_) => null;
      expect(
        await build().start(),
        const CaptureFailed(CaptureFailure.unknown),
      );
    });

    test(
      'a platform error is a failure, a missing plugin unsupported',
      () async {
        answer = (_) => throw PlatformException(code: 'boom');
        expect(
          await build().start(),
          const CaptureFailed(CaptureFailure.unknown),
        );
        messenger.setMockMethodCallHandler(channel, null);
        expect(
          await build().start(),
          const CaptureFailed(CaptureFailure.unsupported),
        );
      },
    );
  });

  test('show and stop call the platform and never throw', () async {
    final host = build();
    await host.show(
      const CaptionLine(original: 'Hola', translation: 'Hello', isFinal: false),
    );
    await host.stop();
    expect(calls.first.method, 'show');
    expect(calls.first.arguments, {
      'translation': 'Hello',
      'original': 'Hola',
      'final': false,
    });
    expect(calls.last.method, 'stop');
    answer = (_) => throw PlatformException(code: 'boom');
    await host.show(const CaptionLine.notice('Listening…'));
    await host.stop();
    messenger.setMockMethodCallHandler(channel, null);
    await host.show(const CaptionLine.notice('Listening…'));
    await host.stop();
  });

  test('audio arrives as float blocks; other blocks are dropped', () async {
    messenger.setMockStreamHandler(
      audioChannel,
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          events
            ..success(Float32List.fromList([0.5, -0.5]))
            ..success([0.25, 1, 'x'])
            ..success(Float32List(0))
            ..success('nonsense')
            ..endOfStream();
        },
      ),
    );
    final blocks = await build().audio.toList();
    expect(blocks, [
      Float32List.fromList([0.5, -0.5]),
      Float32List.fromList([0.25, 1]),
    ]);
  });

  test('events are parsed; unknown ones are dropped', () async {
    messenger.setMockStreamHandler(
      eventsChannel,
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          [
            'stopTapped',
            'openTapped',
            'ended',
            'locked',
            'unlocked',
            'other',
            42,
          ].forEach(events.success);
          events.endOfStream();
        },
      ),
    );
    expect(await build().events.toList(), [
      CaptionBarEvent.stopTapped,
      CaptionBarEvent.openTapped,
      CaptionBarEvent.captureEnded,
      CaptionBarEvent.deviceLocked,
      CaptionBarEvent.deviceUnlocked,
    ]);
  });

  group('UnsupportedCaptionsHost', () {
    test('captures nothing', () async {
      const host = UnsupportedCaptionsHost();
      expect(host.isSupported, isFalse);
      expect(
        await host.start(),
        const CaptureFailed(CaptureFailure.unsupported),
      );
      await host.show(const CaptionLine());
      await host.stop();
      expect(await host.audio.isEmpty, isTrue);
      expect(await host.events.isEmpty, isTrue);
    });
  });

  group('platformCaptionsHost', () {
    const privacy = MethodChannel('test/privacy');

    tearDown(() => messenger.setMockMethodCallHandler(privacy, null));

    void sdk(int? value) => messenger.setMockMethodCallHandler(
      privacy,
      (call) async => call.method == 'sdkInt' ? value : null,
    );

    test('is the channel host on Android 10 and later', () async {
      sdk(29);
      final host = await platformCaptionsHost(
        privacyChannel: privacy,
        isAndroid: true,
      );
      expect(host, isA<MethodChannelCaptionsHost>());
      expect(host.isSupported, isTrue);
    });

    test('is unsupported before Android 10 and off Android', () async {
      sdk(28);
      expect(
        await platformCaptionsHost(privacyChannel: privacy, isAndroid: true),
        isA<UnsupportedCaptionsHost>(),
      );
      sdk(null);
      expect(
        await platformCaptionsHost(privacyChannel: privacy, isAndroid: true),
        isA<UnsupportedCaptionsHost>(),
      );
      expect(
        await platformCaptionsHost(privacyChannel: privacy),
        isA<UnsupportedCaptionsHost>(),
      );
    });
  });

  group('models', () {
    test('compare by value', () {
      expect(const CaptureStarted(), const CaptureStarted());
      expect(const CaptureDeclined(), const CaptureDeclined());
      expect(const CaptureDeclined().props, isEmpty);
      expect(
        const CaptionLine.notice('x'),
        const CaptionLine(translation: 'x'),
      );
      expect(CaptureFailure.parse(null), CaptureFailure.unknown);
      expect(CaptionBarEvent.parse(null), isNull);
    });
  });
}
