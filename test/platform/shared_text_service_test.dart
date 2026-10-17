import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/platform/shared_text_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel(SharedTextService.methodChannelName);
  const events = EventChannel(SharedTextService.eventChannelName);
  const eventControl = MethodChannel(SharedTextService.eventChannelName);

  late SharedTextService service;

  setUp(() {
    service = SharedTextService();
  });

  tearDown(() {
    messenger
      ..setMockMethodCallHandler(methods, null)
      ..setMockMethodCallHandler(eventControl, null)
      ..setMockStreamHandler(events, null);
  });

  group(SharedText, () {
    test('defaults to a read-only share', () {
      const text = SharedText('hi');

      expect(text.readOnly, isTrue);
      expect(text.isProcessText, isFalse);
      expect(text.action, isNull);
      expect(text.isTranslateClipboard, isFalse);
    });

    test('recognises the translate-clipboard action', () {
      const text = SharedText('', action: 'translateClipboard');

      expect(SharedText.translateClipboardAction, 'translateClipboard');
      expect(text.isTranslateClipboard, isTrue);
      expect(const SharedText('', action: 'other').isTranslateClipboard, false);
    });

    test('recognises the translate-offline action', () {
      const text = SharedText(
        'hola',
        readOnly: false,
        isProcessText: true,
        action: 'translateOffline',
      );

      expect(SharedText.translateOfflineAction, 'translateOffline');
      expect(text.isTranslateOffline, isTrue);
      expect(text.isTranslateClipboard, isFalse);
      expect(const SharedText('hola').isTranslateOffline, isFalse);
      expect(
        const SharedText('', action: 'translateClipboard').isTranslateOffline,
        isFalse,
      );
    });

    test('supports value equality', () {
      expect(const SharedText('a'), equals(const SharedText('a')));
      expect(const SharedText('a').hashCode, const SharedText('a').hashCode);
      expect(
        const SharedText('a'),
        isNot(equals(const SharedText('a', readOnly: false))),
      );
      expect(
        const SharedText('a'),
        isNot(equals(const SharedText('a', isProcessText: true))),
      );
      expect(const SharedText('a'), isNot(equals(const SharedText('b'))));
      expect(
        const SharedText('a', action: 'x'),
        equals(const SharedText('a', action: 'x')),
      );
      expect(
        const SharedText('a', action: 'x').hashCode,
        const SharedText('a', action: 'x').hashCode,
      );
      expect(
        const SharedText('a'),
        isNot(equals(const SharedText('a', action: 'x'))),
      );
    });

    test('has a readable toString', () {
      expect(
        const SharedText('a', isProcessText: true).toString(),
        'SharedText(a, readOnly: true, isProcessText: true)',
      );
      expect(
        const SharedText('', action: 'translateClipboard').toString(),
        'SharedText(, readOnly: true, isProcessText: false, '
        'action: translateClipboard)',
      );
    });
  });

  group(SharedTextService, () {
    group('parse', () {
      test('reads the platform map', () {
        expect(
          SharedTextService.parse({
            'text': 'Hola',
            'readOnly': false,
            'processText': true,
          }),
          const SharedText('Hola', readOnly: false, isProcessText: true),
        );
      });

      test('defaults missing or invalid flags', () {
        expect(
          SharedTextService.parse({'text': 'Hola', 'readOnly': 'no'}),
          const SharedText('Hola'),
        );
        expect(
          SharedTextService.parse(<Object?, Object?>{
            'text': 'Hola',
            'processText': 1,
          }),
          const SharedText('Hola'),
        );
      });

      test('reads a translate-clipboard action without text', () {
        final text = SharedTextService.parse(<Object?, Object?>{
          'action': 'translateClipboard',
        });

        expect(text, const SharedText('', action: 'translateClipboard'));
        expect(text!.isTranslateClipboard, isTrue);
      });

      test('reads an action with text and flags', () {
        expect(
          SharedTextService.parse({
            'action': 'translateClipboard',
            'text': 'Hola',
            'readOnly': false,
          }),
          const SharedText(
            'Hola',
            readOnly: false,
            action: 'translateClipboard',
          ),
        );
      });

      test('reads a translate-offline selection', () {
        final text = SharedTextService.parse({
          'text': 'Hola',
          'readOnly': false,
          'processText': true,
          'action': 'translateOffline',
        });

        expect(
          text,
          const SharedText(
            'Hola',
            readOnly: false,
            isProcessText: true,
            action: 'translateOffline',
          ),
        );
        expect(text!.isTranslateOffline, isTrue);
      });

      test('drops blank text next to an action', () {
        expect(
          SharedTextService.parse({
            'action': 'translateClipboard',
            'text': '  ',
          }),
          const SharedText('', action: 'translateClipboard'),
        );
      });

      test('ignores invalid actions', () {
        expect(
          SharedTextService.parse({'text': 'Hola', 'action': 42}),
          const SharedText('Hola'),
        );
        expect(SharedTextService.parse({'action': ' '}), isNull);
        expect(SharedTextService.parse({'action': 42}), isNull);
        expect(SharedTextService.parse({'action': null}), isNull);
      });

      test('accepts a plain string', () {
        expect(SharedTextService.parse('Hola'), const SharedText('Hola'));
      });

      test('ignores payloads without usable text', () {
        expect(SharedTextService.parse(null), isNull);
        expect(SharedTextService.parse(''), isNull);
        expect(SharedTextService.parse('  \n'), isNull);
        expect(SharedTextService.parse({'text': ' '}), isNull);
        expect(SharedTextService.parse({'text': 42}), isNull);
        expect(SharedTextService.parse({'readOnly': false}), isNull);
        expect(SharedTextService.parse(42), isNull);
        expect(SharedTextService.parse(['Hola']), isNull);
      });
    });

    group('initialText', () {
      test('returns the parsed launch text', () async {
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(methods, (call) async {
          calls.add(call);
          return {'text': 'Bonjour', 'readOnly': false, 'processText': true};
        });

        expect(
          await service.initialText(),
          const SharedText('Bonjour', readOnly: false, isProcessText: true),
        );
        expect(calls.single.method, 'getInitialText');
      });

      test('returns a launch action', () async {
        messenger.setMockMethodCallHandler(
          methods,
          (call) async => {'action': 'translateClipboard'},
        );

        expect(
          await service.initialText(),
          const SharedText('', action: 'translateClipboard'),
        );
      });

      test('returns a translate-offline selection', () async {
        messenger.setMockMethodCallHandler(
          methods,
          (call) async => {
            'text': 'Bonjour',
            'readOnly': true,
            'processText': true,
            'action': 'translateOffline',
          },
        );

        final text = await service.initialText();
        expect(
          text,
          const SharedText(
            'Bonjour',
            isProcessText: true,
            action: SharedText.translateOfflineAction,
          ),
        );
        expect(text!.isTranslateOffline, isTrue);
      });

      test('returns null when nothing was shared', () async {
        messenger.setMockMethodCallHandler(methods, (call) async => null);

        expect(await service.initialText(), isNull);
      });

      test('returns null without a platform implementation', () async {
        expect(await service.initialText(), isNull);
      });

      test('returns null on platform errors', () async {
        messenger.setMockMethodCallHandler(
          methods,
          (call) async => throw PlatformException(code: 'boom'),
        );

        expect(await service.initialText(), isNull);
      });
    });

    group('returnResult', () {
      test('sends the text to the platform', () async {
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(methods, (call) async {
          calls.add(call);
          return null;
        });

        await service.returnResult('Hello');

        expect(calls.single.method, 'returnResult');
        expect(calls.single.arguments, 'Hello');
      });

      test('is a no-op without a platform implementation', () async {
        await expectLater(service.returnResult('Hello'), completes);
      });

      test('swallows platform errors', () async {
        messenger.setMockMethodCallHandler(
          methods,
          (call) async => throw PlatformException(code: 'no_request'),
        );

        await expectLater(service.returnResult('Hello'), completes);
      });
    });

    group('texts', () {
      test('emits parsed texts and skips unusable events', () async {
        messenger.setMockStreamHandler(
          events,
          MockStreamHandler.inline(
            onListen: (arguments, sink) {
              sink
                ..success({'text': 'one'})
                ..success({'text': ''})
                ..error(code: 'oops')
                ..success('two')
                ..success({
                  'text': 'three',
                  'readOnly': false,
                  'processText': true,
                })
                ..success({'action': 'translateClipboard'})
                ..success({'action': ''})
                ..success({
                  'text': 'four',
                  'readOnly': false,
                  'processText': true,
                  'action': 'translateOffline',
                })
                ..endOfStream();
            },
          ),
        );

        final received = <SharedText>[];
        final subscription = service.texts.listen(received.add);
        await pumpEventQueue();
        await subscription.cancel();

        expect(received, const [
          SharedText('one'),
          SharedText('two'),
          SharedText('three', readOnly: false, isProcessText: true),
          SharedText('', action: 'translateClipboard'),
          SharedText(
            'four',
            readOnly: false,
            isProcessText: true,
            action: 'translateOffline',
          ),
        ]);
        expect(received.last.isTranslateOffline, isTrue);
      });

      test('is a cached broadcast stream', () {
        expect(service.texts, same(service.texts));
        expect(service.texts.isBroadcast, isTrue);
      });

      test('cancels the platform stream when the last listener '
          'leaves', () async {
        var cancelled = false;
        messenger.setMockStreamHandler(
          events,
          MockStreamHandler.inline(
            onListen: (arguments, sink) {},
            onCancel: (arguments) => cancelled = true,
          ),
        );

        final subscription = service.texts.listen((_) {});
        await pumpEventQueue();
        await subscription.cancel();
        await pumpEventQueue();

        expect(cancelled, isTrue);
      });

      test('completes empty without a platform implementation', () async {
        await expectLater(service.texts, emitsDone);
      });

      test('completes empty when listening fails', () async {
        messenger.setMockMethodCallHandler(eventControl, (call) async {
          if (call.method == 'listen') {
            throw PlatformException(code: 'unavailable');
          }
          return null;
        });

        await expectLater(service.texts, emitsDone);
      });

      test('swallows errors while cancelling', () async {
        final calls = <String>[];
        messenger.setMockMethodCallHandler(eventControl, (call) async {
          calls.add(call.method);
          if (call.method == 'cancel') {
            throw PlatformException(code: 'unavailable');
          }
          return null;
        });

        final subscription = service.texts.listen((_) {});
        await pumpEventQueue();
        await subscription.cancel();
        await pumpEventQueue();

        expect(calls, ['listen', 'cancel']);
      });

      test('swallows a missing plugin while cancelling', () async {
        final calls = <String>[];
        messenger.setMockMethodCallHandler(eventControl, (call) async {
          calls.add(call.method);
          // Disappear before `cancel` arrives.
          messenger.setMockMethodCallHandler(eventControl, null);
          return null;
        });

        final subscription = service.texts.listen((_) {});
        await pumpEventQueue();
        await subscription.cancel();
        await pumpEventQueue();

        expect(calls, ['listen']);
      });

      test('uses an injected messenger', () async {
        final service = SharedTextService(messenger: messenger);
        messenger.setMockStreamHandler(
          events,
          MockStreamHandler.inline(
            onListen: (arguments, sink) => sink.success('injected'),
          ),
        );

        await expectLater(service.texts, emits(const SharedText('injected')));
      });
    });
  });
}
