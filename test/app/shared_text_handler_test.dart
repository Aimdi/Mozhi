import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/shared_text_handler.dart';
import 'package:mozhi/platform/shared_text_service.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

class _MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit {}

class _MockSharedTextService extends Mock implements SharedTextService {}

const _ready = TranslateState(enginesStatus: EnginesStatus.ready);

TranslateState _translated(String input, String output) => TranslateState(
  enginesStatus: EnginesStatus.ready,
  input: input,
  status: TranslateStatus.success,
  result: TranslationResult(engineId: 'e', engineName: 'E', text: output),
);

void main() {
  group('SharedTextHandler', () {
    late _MockTranslateCubit cubit;
    late _MockSharedTextService service;
    late StreamController<SharedText> texts;
    late StreamController<TranslateState> states;
    late int shown;
    late int replaceOffers;
    late SharedTextHandler handler;

    setUp(() {
      cubit = _MockTranslateCubit();
      service = _MockSharedTextService();
      texts = StreamController<SharedText>.broadcast();
      states = StreamController<TranslateState>.broadcast();
      shown = 0;
      replaceOffers = 0;
      whenListen(cubit, states.stream, initialState: _ready);
      when(() => cubit.isClosed).thenReturn(false);
      when(() => service.texts).thenAnswer((_) => texts.stream);
      when(() => service.initialText()).thenAnswer((_) async => null);
      when(() => service.returnResult(any())).thenAnswer((_) async {});
      handler = SharedTextHandler(
        service: service,
        translateCubit: cubit,
        onShowTranslate: () => shown++,
        onReplaceAvailable: () => replaceOffers++,
      );
    });

    tearDown(() async {
      await handler.dispose();
      await texts.close();
      await states.close();
    });

    test('translates the launch text', () async {
      when(() => service.initialText())
          .thenAnswer((_) async => const SharedText('hello'));

      await handler.start();

      expect(shown, 1);
      verify(() => cubit.setInputAndTranslate('hello')).called(1);
      expect(replaceOffers, 0);
    });

    test('translates texts shared while running', () async {
      await handler.start();
      expect(shown, 0);

      texts.add(const SharedText('later'));
      await pumpEventQueue();

      expect(shown, 1);
      verify(() => cubit.setInputAndTranslate('later')).called(1);
    });

    test('ignores blank texts', () async {
      await handler.start();
      await handler.handle(const SharedText('  '));

      expect(shown, 0);
      verifyNever(() => cubit.setInputAndTranslate(any()));
    });

    test('survives platforms without support', () async {
      when(() => service.initialText()).thenThrow(Exception('no plugin'));

      await expectLater(handler.start(), completes);
      expect(shown, 0);
    });

    test(
      'offers the replacement once a writable selection is translated',
      () async {
        await handler.handle(
          const SharedText('hola', readOnly: false, isProcessText: true),
        );
        expect(replaceOffers, 0);

        states
          ..add(_ready.copyWith(status: TranslateStatus.translating))
          ..add(_translated('hola', 'hello'));
        await pumpEventQueue();
        expect(replaceOffers, 1);

        // Only once.
        states.add(_translated('hola', 'hi'));
        await pumpEventQueue();
        expect(replaceOffers, 1);
      },
    );

    test(
      'offers the replacement immediately when already translated',
      () async {
        when(() => cubit.state).thenReturn(_translated('hola', 'hello'));

        await handler.handle(
          const SharedText('hola', readOnly: false, isProcessText: true),
        );

        expect(replaceOffers, 1);
      },
    );

    test('does not offer a replacement when the translation fails', () async {
      await handler.handle(
        const SharedText('hola', readOnly: false, isProcessText: true),
      );
      states.add(_ready.copyWith(status: TranslateStatus.failure));
      await pumpEventQueue();

      expect(replaceOffers, 0);
    });

    test('does not offer a replacement for read-only or shared text', () async {
      await handler.handle(const SharedText('a', isProcessText: true));
      await handler.handle(const SharedText('b', readOnly: false));
      states.add(_translated('b', 'B'));
      await pumpEventQueue();

      expect(replaceOffers, 0);
      expect(shown, 2);
    });

    test('replaceSelection returns the current output', () async {
      when(() => cubit.state).thenReturn(_translated('hola', 'hello'));

      await handler.replaceSelection();

      verify(() => service.returnResult('hello')).called(1);
    });

    test('replaceSelection ignores an empty output', () async {
      await handler.replaceSelection();

      verifyNever(() => service.returnResult(any()));
    });

    test('stops after dispose', () async {
      await handler.start();
      await handler.dispose();

      texts.add(const SharedText('late'));
      await handler.handle(const SharedText('later'));
      await pumpEventQueue();

      expect(shown, 0);
    });
  });
}
