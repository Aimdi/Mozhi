import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/shared_text_handler.dart';
import 'package:mozhi/platform/shared_text_service.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';

class _MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit;

class _MockSharedTextService extends Mock implements SharedTextService;

const _ready = TranslateState(enginesStatus: EnginesStatus.ready);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SharedTextHandler', () {
    late _MockTranslateCubit cubit;
    late _MockSharedTextService service;
    late StreamController<SharedText> texts;
    late int shown;
    late List<QuickTranslateRequest> quick;
    late String? clipboard;
    late SharedTextHandler handler;

    void verifyExternal(String text) =>
        verify(() => cubit.setExternalInput(text)).called(1);

    void verifyNoInput() {
      verifyNever(() => cubit.setExternalInput(any()));
      verifyNever(() => cubit.setInputAndTranslate(any()));
    }

    setUp(() {
      cubit = _MockTranslateCubit();
      service = _MockSharedTextService();
      texts = StreamController<SharedText>.broadcast();
      shown = 0;
      quick = [];
      clipboard = null;
      when(() => cubit.state).thenReturn(_ready);
      when(() => cubit.isClosed).thenReturn(false);
      when(() => service.texts).thenAnswer((_) => texts.stream);
      when(() => service.initialText()).thenAnswer((_) async => null);
      when(() => service.returnResult(any())).thenAnswer((_) async {});
      handler = SharedTextHandler(
        service: service,
        translateCubit: cubit,
        onShowTranslate: () => shown++,
        onQuickTranslate: quick.add,
        readClipboard: () async => clipboard,
      );
    });

    tearDown(() async {
      await handler.dispose();
      await texts.close();
    });

    test('opens the launch text as external input', () async {
      when(() => service.initialText())
          .thenAnswer((_) async => const SharedText('hello'));

      await handler.start();

      expect(shown, 1);
      verifyExternal('hello');
      verifyNever(() => cubit.setInputAndTranslate(any()));
      expect(quick, isEmpty);
    });

    test('opens texts shared while running', () async {
      await handler.start();
      expect(shown, 0);

      texts.add(const SharedText('later'));
      await pumpEventQueue();

      expect(shown, 1);
      verifyExternal('later');
    });

    test('ignores errors of the platform stream', () async {
      await handler.start();

      texts
        ..addError(Exception('bad payload'))
        ..add(const SharedText('next'));
      await pumpEventQueue();

      verifyExternal('next');
    });

    test('ignores blank texts', () async {
      await handler.start();
      await handler.handle(const SharedText('  '));
      await handler.handle(
        const SharedText(' ', isProcessText: true, readOnly: false),
      );

      expect(shown, 0);
      expect(quick, isEmpty);
      verifyNoInput();
    });

    test('survives platforms without support', () async {
      when(() => service.initialText()).thenThrow(Exception('no plugin'));

      await expectLater(handler.start(), completes);
      expect(shown, 0);
    });

    group('PROCESS_TEXT', () {
      test('shows a writable selection in quick translate', () async {
        await handler.handle(
          const SharedText('hola', readOnly: false, isProcessText: true),
        );

        expect(shown, 0);
        verifyNoInput();
        expect(quick, hasLength(1));
        final request = quick.single;
        expect(request.text, 'hola');
        expect(request.canReplace, isTrue);

        request.onReplace!('hello');
        await pumpEventQueue();
        verify(() => service.returnResult('hello')).called(1);
      });

      test('offers no replacement for a read-only selection', () async {
        await handler.handle(const SharedText('hola', isProcessText: true));

        final request = quick.single;
        expect(request.canReplace, isFalse);
        expect(request.onReplace, isNull);
      });

      test('"Open in app" opens the translate tab', () async {
        await handler.handle(const SharedText('hola', isProcessText: true));

        quick.single.onOpenInApp();
        await pumpEventQueue();

        expect(shown, 1);
        verifyExternal('hola');
      });

      test('opens in the app without a quick translate UI', () async {
        handler = SharedTextHandler(
          service: service,
          translateCubit: cubit,
          onShowTranslate: () => shown++,
        );

        await handler.handle(
          const SharedText('hola', readOnly: false, isProcessText: true),
        );

        expect(shown, 1);
        verifyExternal('hola');
      });
    });

    group('replaceSelection', () {
      test('returns the translation to the calling app', () async {
        await handler.replaceSelection('hello');

        verify(() => service.returnResult('hello')).called(1);
      });

      test('ignores a blank translation', () async {
        await handler.replaceSelection('  ');

        verifyNever(() => service.returnResult(any()));
      });
    });

    group('translate clipboard', () {
      const action = SharedText(
        '',
        action: SharedText.translateClipboardAction,
      );

      test('opens the clipboard text as external input', () async {
        clipboard = 'from the clipboard';

        await handler.handle(action);

        expect(shown, 1);
        verifyExternal('from the clipboard');
        expect(quick, isEmpty);
      });

      test('only shows the translate tab for an empty clipboard', () async {
        clipboard = '  ';

        await handler.handle(action);

        expect(shown, 1);
        verifyNoInput();
      });

      test('survives a failing clipboard', () async {
        handler = SharedTextHandler(
          service: service,
          translateCubit: cubit,
          onShowTranslate: () => shown++,
          readClipboard: () async => throw PlatformException(code: 'x'),
        );

        await handler.handle(action);

        expect(shown, 1);
        verifyNoInput();
      });

      test('does nothing once disposed', () async {
        final read = Completer<String?>();
        handler = SharedTextHandler(
          service: service,
          translateCubit: cubit,
          onShowTranslate: () => shown++,
          readClipboard: () => read.future,
        );

        final done = handler.handle(action);
        await handler.dispose();
        read.complete('late');
        await done;

        expect(shown, 0);
        verifyNoInput();
      });
    });

    test('stops after dispose', () async {
      await handler.start();
      await handler.dispose();

      texts.add(const SharedText('late'));
      await handler.handle(const SharedText('later'));
      await handler.openInApp('latest');
      await pumpEventQueue();

      expect(shown, 0);
      verifyNoInput();
    });
  });

  group('readClipboardText', () {
    late Object? data;

    setUp(() {
      data = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method != 'Clipboard.getData') return null;
            if (data is Exception) throw data! as Exception;
            return data;
          });
    });

    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    test('reads the plain text', () async {
      data = <String, Object?>{'text': 'copied'};

      expect(await readClipboardText(), 'copied');
    });

    test('is null for an empty clipboard', () async {
      expect(await readClipboardText(), isNull);
    });

    test('is null when the platform fails', () async {
      data = PlatformException(code: 'denied');

      expect(await readClipboardText(), isNull);
    });
  });

  test('QuickTranslateRequest.canReplace follows onReplace', () {
    final readOnly = QuickTranslateRequest(text: 'a', onOpenInApp: () {});
    final writable = QuickTranslateRequest(
      text: 'a',
      onOpenInApp: () {},
      onReplace: (_) {},
    );

    expect(readOnly.canReplace, isFalse);
    expect(writable.canReplace, isTrue);
  });
}
