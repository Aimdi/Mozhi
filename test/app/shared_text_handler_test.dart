import 'dart:async';
import 'dart:ui';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/router.dart';
import 'package:mozhi/app/shared_text_handler.dart';
import 'package:mozhi/core/privacy/egress/egress.dart';
import 'package:mozhi/platform/shared_text_service.dart';
import 'package:mozhi/quick_translate/quick_translate_host.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';

class _MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit;

class _MockSharedTextService extends Mock implements SharedTextService;

class _MockQuickTranslateHost extends Mock implements QuickTranslateHost;

const _ready = TranslateState(enginesStatus: EnginesStatus.ready);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SharedTextHandler', () {
    late _MockTranslateCubit cubit;
    late _MockSharedTextService service;
    late StreamController<SharedText> texts;
    late int shown;
    late List<QuickTranslateRequest> quick;
    late List<QuickImproveRequest> improve;
    late List<String> proofread;
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
      improve = [];
      proofread = [];
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
        onQuickImprove: improve.add,
        onShowProofread: proofread.add,
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
        expect(request.offlineOnly, isFalse);
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

    group('Translate offline', () {
      const offline = SharedText(
        'hola',
        readOnly: false,
        isProcessText: true,
        action: SharedText.translateOfflineAction,
      );

      test('shows the selection in quick translate, offline only', () async {
        await handler.handle(offline);

        expect(shown, 0);
        verifyNoInput();
        final request = quick.single;
        expect(request.text, 'hola');
        expect(request.offlineOnly, isTrue);
        expect(request.canReplace, isTrue);

        request.onReplace!('hello');
        await pumpEventQueue();
        verify(() => service.returnResult('hello')).called(1);
      });

      test('a read-only selection cannot be replaced', () async {
        await handler.handle(
          const SharedText(
            'hola',
            isProcessText: true,
            action: SharedText.translateOfflineAction,
          ),
        );

        final request = quick.single;
        expect(request.offlineOnly, isTrue);
        expect(request.canReplace, isFalse);
      });

      test('arrives on the event channel too', () async {
        await handler.start();

        texts.add(offline);
        await pumpEventQueue();

        expect(quick.single.offlineOnly, isTrue);
        verifyNoInput();
      });

      test('also without the PROCESS_TEXT flag', () async {
        await handler.handle(
          const SharedText('hola', action: SharedText.translateOfflineAction),
        );

        expect(quick.single.offlineOnly, isTrue);
        verifyNoInput();
      });

      test('"Open in app" opens the translate tab', () async {
        await handler.handle(offline);

        quick.single.onOpenInApp();
        await pumpEventQueue();

        expect(shown, 1);
        verifyExternal('hola');
      });

      test('never hands the text to the translate tab without the quick '
          'translate UI', () async {
        handler = SharedTextHandler(
          service: service,
          translateCubit: cubit,
          onShowTranslate: () => shown++,
        );

        await handler.handle(offline);

        expect(shown, 1);
        verifyNoInput();
      });

      test('ignores a blank selection', () async {
        await handler.handle(
          const SharedText(
            '  ',
            isProcessText: true,
            action: SharedText.translateOfflineAction,
          ),
        );

        expect(shown, 0);
        expect(quick, isEmpty);
      });
    });

    group('Improve with Mozhi', () {
      const selection = SharedText(
        'I has a cat',
        readOnly: false,
        isProcessText: true,
        action: SharedText.improveAction,
      );

      test('shows the selection in quick improve', () async {
        await handler.handle(selection);

        expect(shown, 0);
        verifyNoInput();
        expect(quick, isEmpty);
        expect(proofread, isEmpty);
        final request = improve.single;
        expect(request.text, 'I has a cat');
        expect(request.canReplace, isTrue);

        request.onReplace!('I have a cat');
        await pumpEventQueue();
        verify(() => service.returnResult('I have a cat')).called(1);
      });

      test('a read-only selection cannot be replaced', () async {
        await handler.handle(
          const SharedText(
            'I has a cat',
            isProcessText: true,
            action: SharedText.improveAction,
          ),
        );

        final request = improve.single;
        expect(request.canReplace, isFalse);
        expect(request.onReplace, isNull);
      });

      test('arrives on the event channel too', () async {
        await handler.start();

        texts.add(selection);
        await pumpEventQueue();

        expect(improve.single.text, 'I has a cat');
        expect(quick, isEmpty);
        verifyNoInput();
      });

      test('also without the PROCESS_TEXT flag', () async {
        await handler.handle(
          const SharedText('I has a cat', action: SharedText.improveAction),
        );

        expect(improve, hasLength(1));
        expect(quick, isEmpty);
      });

      test('"Open in Proofread" opens the Proofread tab', () async {
        await handler.handle(selection);

        improve.single.onOpenInProofread();
        await pumpEventQueue();

        expect(proofread, ['I has a cat']);
        expect(shown, 0);
        verifyNoInput();
      });

      test('opens the Proofread tab without the quick improve UI', () async {
        handler = SharedTextHandler(
          service: service,
          translateCubit: cubit,
          onShowTranslate: () => shown++,
          onQuickTranslate: quick.add,
          onShowProofread: proofread.add,
        );

        await handler.handle(selection);

        expect(proofread, ['I has a cat']);
        expect(quick, isEmpty);
        expect(shown, 0);
        verifyNoInput();
      });

      test('cuts long text for the Proofread tab', () async {
        final long = 'a' * (TranslateCubit.maxExternalInputLength - 1);
        // An emoji (a surrogate pair) across the limit is left out whole.
        await handler.openInProofread('$long😀 and more');

        expect(proofread.single, long);
      });

      test('does nothing for the Proofread tab once disposed', () async {
        await handler.dispose();
        await handler.openInProofread('I has a cat');
        expect(proofread, isEmpty);
      });

      test('ignores a blank selection', () async {
        await handler.handle(
          const SharedText(
            '  ',
            isProcessText: true,
            action: SharedText.improveAction,
          ),
        );

        expect(improve, isEmpty);
        expect(proofread, isEmpty);
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

  group('in the quick translate window', () {
    late _MockTranslateCubit cubit;
    late _MockSharedTextService service;
    late _MockQuickTranslateHost window;
    late List<QuickTranslateRequest> quick;
    late int shown;
    late EgressLedger ledger;

    setUp(() {
      cubit = _MockTranslateCubit();
      service = _MockSharedTextService();
      window = _MockQuickTranslateHost();
      quick = [];
      shown = 0;
      ledger = EgressLedger();
      when(() => cubit.state).thenReturn(_ready);
      when(() => service.texts).thenAnswer((_) => const Stream.empty());
      when(() => service.initialText()).thenAnswer((_) async => null);
      when(() => window.isActive).thenReturn(true);
      when(window.close).thenAnswer((_) async {});
      when(() => window.openTextInApp(any())).thenAnswer((_) async {});
      when(() => window.openLocationInApp(any())).thenAnswer((_) async {});
    });

    tearDown(
      () => IsolateNameServer.removePortNameMapping(EgressRelay.portName),
    );

    SharedTextHandler create({bool withQuick = true}) => SharedTextHandler(
      service: service,
      translateCubit: cubit,
      onShowTranslate: () => shown++,
      onQuickTranslate: withQuick ? quick.add : null,
      quickHost: window,
      ledger: ledger,
    );

    test(
      'shows the selection; "Open in app" goes to the main window',
      () async {
        when(() => service.initialText()).thenAnswer(
          (_) async =>
              const SharedText('hola', readOnly: false, isProcessText: true),
        );
        final handler = create();
        addTearDown(handler.dispose);

        await handler.start();
        quick.single.onOpenInApp();

        verify(() => window.openTextInApp('hola')).called(1);
        verifyNever(() => cubit.setExternalInput(any()));
        expect(shown, 0);
        expect(quick.single.canReplace, isTrue);
        verifyNever(window.close);
      },
    );

    test('any text shows quick translate there', () async {
      when(() => service.initialText())
          .thenAnswer((_) async => const SharedText('plain'));
      final handler = create();
      addTearDown(handler.dispose);

      await handler.start();

      expect(quick.single.text, 'plain');
    });

    test('shows an improve selection; "Open in Proofread" goes to the main '
        'window', () async {
      when(() => service.initialText()).thenAnswer(
        (_) async => const SharedText(
          'I has a cat',
          readOnly: false,
          isProcessText: true,
          action: SharedText.improveAction,
        ),
      );
      final improve = <QuickImproveRequest>[];
      final handler = SharedTextHandler(
        service: service,
        translateCubit: cubit,
        onShowTranslate: () => shown++,
        onQuickTranslate: quick.add,
        onQuickImprove: improve.add,
        quickHost: window,
        ledger: ledger,
      );
      addTearDown(handler.dispose);

      await handler.start();
      expect(quick, isEmpty);
      expect(improve.single.canReplace, isTrue);
      improve.single.onOpenInProofread();
      await pumpEventQueue();

      verify(
        () => window.openLocationInApp(
          AppRoutes.proofreadText(text: 'I has a cat'),
        ),
      ).called(1);
      verifyNever(() => window.openTextInApp(any()));
      verifyNever(window.close);
      expect(shown, 0);
    });

    test('an improve selection without the quick improve UI opens in the '
        "main window's Proofread tab", () async {
      final handler = create();
      addTearDown(handler.dispose);

      await handler.handle(
        const SharedText(
          'I has a cat',
          isProcessText: true,
          action: SharedText.improveAction,
        ),
      );

      verify(
        () => window.openLocationInApp(
          AppRoutes.proofreadText(text: 'I has a cat'),
        ),
      ).called(1);
      expect(quick, isEmpty);
    });

    test('closes the window without a selection', () async {
      final handler = create();
      addTearDown(handler.dispose);

      await handler.start();

      verify(window.close).called(1);
      expect(quick, isEmpty);
    });

    test('closes the window for a blank selection', () async {
      final handler = create();
      addTearDown(handler.dispose);
      await handler.handle(const SharedText(' ', isProcessText: true));
      verify(window.close).called(1);
    });

    test('closes the window when there is no quick translate UI', () async {
      final handler = create(withQuick: false);
      addTearDown(handler.dispose);
      await handler.handle(const SharedText('hola', isProcessText: true));
      verify(window.close).called(1);
      expect(shown, 0);
    });

    test('hands its network activity to the main window', () async {
      final main = EgressLedger();
      final stop = EgressRelay.receive(main);
      addTearDown(stop);
      final handler = create();
      await handler.start();

      final entry = ledger.begin(
        method: 'POST',
        scheme: 'https',
        destination: const EgressDestination(
          kind: EgressDestinationKind.cloudProvider,
          host: 'api.openai.com',
          name: 'OpenAI',
        ),
        purpose: EgressPurpose.aiModel,
      );
      ledger.update(entry.copyWith(outcome: EgressOutcome.succeeded));
      await pumpEventQueue();
      expect(main.entries, hasLength(1));

      await handler.dispose();
      final later = ledger.begin(
        method: 'GET',
        scheme: 'https',
        destination: entry.destination,
        purpose: EgressPurpose.catalog,
      );
      ledger.update(later.copyWith(outcome: EgressOutcome.succeeded));
      await pumpEventQueue();
      expect(main.entries, hasLength(1));
    });

    test('the main window receives the activity of the others', () async {
      when(() => window.isActive).thenReturn(false);
      final handler = create();
      await handler.start();

      expect(
        IsolateNameServer.lookupPortByName(EgressRelay.portName),
        isNotNull,
      );
      final entry = EgressEntry(
        id: 0,
        startedAt: DateTime(2026),
        method: 'GET',
        scheme: 'https',
        destination: const EgressDestination(
          kind: EgressDestinationKind.publicServer,
          host: 'mozhi.example',
        ),
        purpose: EgressPurpose.catalog,
        outcome: EgressOutcome.succeeded,
      );
      IsolateNameServer.lookupPortByName(EgressRelay.portName)!
          .send(entry.toMap());
      await pumpEventQueue();
      expect(ledger.entries.single.destination.host, 'mozhi.example');

      await handler.dispose();
      expect(IsolateNameServer.lookupPortByName(EgressRelay.portName), isNull);
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

  test('QuickImproveRequest.canReplace follows onReplace', () {
    expect(
      QuickImproveRequest(text: 'a', onOpenInProofread: () {}).canReplace,
      isFalse,
    );
    expect(
      QuickImproveRequest(
        text: 'a',
        onOpenInProofread: () {},
        onReplace: (_) {},
      ).canReplace,
      isTrue,
    );
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
    expect(readOnly.offlineOnly, isFalse);
    expect(
      QuickTranslateRequest(
        text: 'a',
        onOpenInApp: () {},
        offlineOnly: true,
      ).offlineOnly,
      isTrue,
    );
  });
}
