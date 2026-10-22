import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/conversation/conversation.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

void main() {
  setUpAll(registerConversationFallbacks);

  late MockTranslationRepository repository;
  late MockSpeechService speech;
  late StreamController<String?> speaking;
  TranslationEngine? engine;

  setUp(() {
    repository = MockTranslationRepository();
    speech = MockSpeechService();
    speaking = stubSpeech(speech);
    engine = deepl;
    when(() => repository.translate(any(), any()))
        .thenAnswer((_) => Stream.value(resultOf('Hello')));
  });

  tearDown(() => speaking.close());

  ConversationCubit build({bool autoSpeak = false}) => ConversationCubit(
    repository: repository,
    speech: speech,
    engine: () => engine,
    languageA: english,
    languageB: spanish,
    autoSpeak: autoSpeak,
    clock: () => sentAt,
  );

  group('submitGuest', () {
    test('adds a guest turn for side A to read', () async {
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.submitGuest(' Bonjour ', language: french, guest: 2);

      final turn = cubit.state.turns.single;
      expect(turn.side, ConversationSide.b);
      expect(turn.original, 'Bonjour');
      expect(turn.source, french);
      expect(turn.target, english);
      expect(turn.guest, 2);
      expect(turn.translation, 'Hello');
      expect(turn.isComplete, isTrue);
      final request =
          verify(() => repository.translate(deepl, captureAny()))
                  .captured
                  .single
              as TranslationRequest;
      expect(request.source, french);
      expect(request.target, english);
    });

    test("translates side A's language for side B", () async {
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.submitGuest(
        'Hi',
        language: const Language(code: 'en-GB', name: 'English (UK)'),
        guest: 1,
      );

      expect(cubit.state.turns.single.target, spanish);
    });

    test('reads the translation aloud with auto-speak', () async {
      final cubit = build(autoSpeak: true);
      addTearDown(cubit.close);

      await cubit.submitGuest('Bonjour', language: french, guest: 1);
      await settle();

      verify(
        () => speech.toggle(
          id: cubit.speechIdOf(0),
          text: 'Hello',
          languageCode: 'en',
        ),
      ).called(1);
    });

    test('ignores blank text and a closed cubit', () async {
      final cubit = build();

      await cubit.submitGuest('  ', language: french, guest: 1);
      expect(cubit.state.turns, isEmpty);

      await cubit.close();
      await cubit.submitGuest('Bonjour', language: french, guest: 1);
      verifyNever(() => repository.translate(any(), any()));
    });

    test('fails without an engine', () async {
      engine = null;
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.submitGuest('Bonjour', language: french, guest: 1);

      expect(cubit.state.turns.single.isFailed, isTrue);
      expect(
        cubit.state.turns.single.error,
        isA<ConversationNoEngineException>(),
      );
    });

    test('keeps the guest when the turn changes', () {
      ConversationTurn byGuest(int? guest) => ConversationTurn(
        id: 0,
        side: ConversationSide.b,
        original: 'Bonjour',
        source: french,
        target: english,
        createdAt: sentAt,
        guest: guest,
      );

      expect(byGuest(3).copyWith(translation: 'Hello').guest, 3);
      expect(byGuest(3), byGuest(3));
      expect(byGuest(3), isNot(byGuest(2)));
      expect(byGuest(3), isNot(byGuest(null)));
    });
  });
}
