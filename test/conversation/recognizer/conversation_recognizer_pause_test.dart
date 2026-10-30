import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/conversation/conversation.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:translation_repository/translation_repository.dart';

class _MockSpeechInputService extends Mock implements SpeechInputService;

const _english = Language(code: 'en', name: 'English');

void main() {
  late _MockSpeechInputService service;
  late StreamController<SpeechInputState> states;
  late StreamController<SpeechInputResult> results;

  setUp(() {
    service = _MockSpeechInputService();
    states = StreamController.broadcast();
    results = StreamController.broadcast();
    when(() => service.states).thenAnswer((_) => states.stream);
    when(() => service.results).thenAnswer((_) => results.stream);
    when(() => service.state).thenReturn(const SpeechInputIdle());
    when(() => service.preferOnDevice).thenReturn(ValueNotifier(false));
    when(() => service.isOfflineSupported).thenReturn(true);
    when(service.cancel).thenAnswer((_) async {});
    when(
      () => service.listen(
        any(),
        owner: any(named: 'owner'),
        detectLanguage: any(named: 'detectLanguage'),
        offlinePause: any(named: 'offlinePause'),
      ),
    ).thenAnswer((_) async => true);
  });

  tearDown(() async {
    await states.close();
    await results.close();
  });

  test(
    'passes the pause that ends an utterance on as the offline pause',
    () async {
      final recognizer = SpeechInputConversationRecognizer(service);
      const pause = Duration(milliseconds: 800);
      recognizer
          .listen(_english, detectLanguage: true, pause: pause)
          .listen((_) {});
      await Future<void>.delayed(Duration.zero);
      verify(
        () => service.listen(
          'en',
          owner: any(named: 'owner'),
          detectLanguage: true,
          offlinePause: pause,
        ),
      ).called(1);
      await recognizer.dispose();
    },
  );

  test('passes none without one', () async {
    final recognizer = SpeechInputConversationRecognizer(service);
    recognizer.listen(_english).listen((_) {});
    await Future<void>.delayed(Duration.zero);
    // No offline pause: the service's own.
    verify(() => service.listen('en', owner: any(named: 'owner'))).called(1);
    await recognizer.dispose();
  });
}
