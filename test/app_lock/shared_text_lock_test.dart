import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/shared_text_handler.dart';
import 'package:mozhi/platform/shared_text_service.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';

class _MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit;

class _MockSharedTextService extends Mock implements SharedTextService;

const _ready = TranslateState(enginesStatus: EnginesStatus.ready);

/// Text from other apps waits for the app lock (`untilUnlocked`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockTranslateCubit cubit;
  late _MockSharedTextService service;
  late StreamController<SharedText> texts;
  late Completer<void> unlocked;
  late int shown;
  late int clipboardReads;
  late List<QuickTranslateRequest> quick;
  late SharedTextHandler handler;

  setUp(() {
    cubit = _MockTranslateCubit();
    service = _MockSharedTextService();
    texts = StreamController<SharedText>.broadcast();
    unlocked = Completer();
    shown = 0;
    clipboardReads = 0;
    quick = [];
    when(() => cubit.state).thenReturn(_ready);
    when(() => cubit.isClosed).thenReturn(false);
    when(() => service.texts).thenAnswer((_) => texts.stream);
    when(() => service.initialText()).thenAnswer((_) async => null);
    handler = SharedTextHandler(
      service: service,
      translateCubit: cubit,
      onShowTranslate: () => shown++,
      onQuickTranslate: quick.add,
      readClipboard: () async {
        clipboardReads++;
        return 'from the clipboard';
      },
      untilUnlocked: () => unlocked.future,
    );
  });

  tearDown(() async {
    await handler.dispose();
    await texts.close();
  });

  void verifyNothingYet() {
    expect(shown, 0);
    expect(quick, isEmpty);
    expect(clipboardReads, 0);
    verifyNever(() => cubit.setExternalInput(any()));
    verifyNever(() => cubit.setInputAndTranslate(any()));
  }

  test('shared text waits for the unlock, then opens once', () async {
    await handler.start();
    texts.add(const SharedText('bonjour'));
    await pumpEventQueue();
    verifyNothingYet();

    unlocked.complete();
    await pumpEventQueue();

    expect(shown, 1);
    verify(() => cubit.setExternalInput('bonjour')).called(1);
  });

  test('the launch text waits too', () async {
    when(() => service.initialText())
        .thenAnswer((_) async => const SharedText('hola'));

    unawaited(handler.start());
    await pumpEventQueue();
    verifyNothingYet();

    unlocked.complete();
    await pumpEventQueue();

    verify(() => cubit.setExternalInput('hola')).called(1);
  });

  test('the clipboard is read only once unlocked', () async {
    await handler.start();
    texts.add(
      const SharedText('', action: SharedText.translateClipboardAction),
    );
    await pumpEventQueue();
    verifyNothingYet();

    unlocked.complete();
    await pumpEventQueue();

    expect(clipboardReads, 1);
    verify(() => cubit.setExternalInput('from the clipboard')).called(1);
  });

  test('a selection waits before quick translate opens', () async {
    await handler.start();
    texts.add(const SharedText('ciao', isProcessText: true));
    await pumpEventQueue();
    verifyNothingYet();

    unlocked.complete();
    await pumpEventQueue();

    expect(quick.single.text, 'ciao');
  });

  test('texts that arrived while locked follow in order', () async {
    await handler.start();
    texts
      ..add(const SharedText('one'))
      ..add(const SharedText('two'));
    await pumpEventQueue();
    verifyNothingYet();

    unlocked.complete();
    await pumpEventQueue();

    verifyInOrder([
      () => cubit.setExternalInput('one'),
      () => cubit.setExternalInput('two'),
    ]);
  });

  test('nothing happens when disposed while locked', () async {
    await handler.start();
    texts.add(const SharedText('bonjour'));
    await pumpEventQueue();

    await handler.dispose();
    unlocked.complete();
    await pumpEventQueue();

    verifyNothingYet();
  });
}
